#!/usr/bin/env python3
"""Read back an Android candidate draft and require it to stay unpublished."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


release = module('android_github_release', 'android-github-release.py')


def downloaded_asset(asset):
    asset_id = asset.get('id')
    if not release.is_id(asset_id):
        raise ValueError('Android draft asset ID is invalid')
    with tempfile.TemporaryDirectory(prefix='aegis-android-draft-') as temp:
        path = Path(temp) / 'asset'
        with path.open('xb') as output:
            result = subprocess.run([
                'gh', 'api', '-H', 'Accept: application/octet-stream',
                f'repos/{release.REPOSITORY}/releases/assets/{asset_id}',
            ], stdout=output, stderr=subprocess.PIPE, timeout=120)
        if result.returncode:
            raise ValueError('Android draft asset could not be downloaded')
        return path.stat().st_size, release.sha256(path)


def verify(proof, remote, read_asset=downloaded_asset):
    if (not isinstance(proof, dict) or proof.get('draft') is not True
            or not isinstance(proof.get('tag'), str) or not release.is_sha(proof.get('sha'))):
        raise ValueError('Android draft proof is incomplete')
    if remote.get('id') != proof.get('releaseId') or remote.get('tag_name') != proof['tag'] or remote.get('draft') is not True:
        raise ValueError('Android candidate draft changed before verification')
    if remote.get('prerelease') is not True or remote.get('make_latest') not in {None, False, 'false'}:
        raise ValueError('Android candidate draft is not staying off Latest')
    expected = proof.get('assets')
    if not isinstance(expected, dict) or not expected or not all(release.is_sha(digest, 64) for digest in expected.values()):
        raise ValueError('Android draft proof does not bind sealed asset hashes')
    release._verify_release_assets({'assets': expected}, remote, complete=True)
    for asset in remote['assets']:
        size, digest = read_asset(asset)
        if size != asset.get('size') or digest != expected[asset['name']]:
            raise ValueError('Downloaded Android draft asset differs from the sealed manifest: ' + asset['name'])
    return {'tag': proof['tag'], 'releaseId': proof['releaseId'], 'draft': True, 'sha': proof['sha'], 'assets': expected}


def main():
    if sys.argv[1:] != ['--delivery']:
        raise SystemExit('Usage: android-draft-verify.py --delivery')
    proofs = list(Path('.artifacts/release/android').glob('*/github-draft.json'))
    if len(proofs) != 1:
        raise SystemExit('Android draft proof is missing or ambiguous')
    proof = json.loads(proofs[0].read_text())
    release.require_candidate_tag_source(proof['tag'], proof['sha'])
    remote = release._api('releases/' + str(proof['releaseId']))
    verified_metadata = {}

    def capture_download(asset):
        result = downloaded_asset(asset)
        verified_metadata[asset['id']] = result
        return result

    result = verify(proof, remote, capture_download)
    fresh = release._api('releases/' + str(proof['releaseId']))
    # Relative counters such as download_count can change during a read.
    verify(proof, fresh, lambda asset: verified_metadata.get(asset.get('id'), (None, None)))
    release.require_candidate_tag_source(proof['tag'], proof['sha'])
    path = proofs[0].with_name(f"android-draft-download-{proof['releaseId']}.json")
    with path.open('x') as output:
        json.dump(result, output, indent=2, sort_keys=True)
        output.write('\n')
    print(json.dumps(result))


if __name__ == '__main__':
    try:
        main()
    except (KeyError, OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(str(error)) from error

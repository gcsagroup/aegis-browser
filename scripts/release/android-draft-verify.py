#!/usr/bin/env python3
"""Read back an Android candidate draft and require it to stay unpublished."""
import importlib.util
import json
from pathlib import Path
import sys


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


release = module('android_github_release', 'android-github-release.py')


def verify(proof, remote):
    if not isinstance(proof, dict) or proof.get('draft') is not True or not isinstance(proof.get('tag'), str):
        raise ValueError('Android draft proof is incomplete')
    if remote.get('id') != proof.get('releaseId') or remote.get('tag_name') != proof['tag'] or remote.get('draft') is not True:
        raise ValueError('Android candidate draft changed before verification')
    if remote.get('prerelease') is not True or remote.get('make_latest') not in {None, False, 'false'}:
        raise ValueError('Android candidate draft is not staying off Latest')
    return {'tag': proof['tag'], 'releaseId': proof['releaseId'], 'draft': True}


def main():
    if sys.argv[1:] != ['--delivery']:
        raise SystemExit('Usage: android-draft-verify.py --delivery')
    proofs = list(Path('.artifacts/release/android').glob('*/github-draft.json'))
    if len(proofs) != 1:
        raise SystemExit('Android draft proof is missing or ambiguous')
    proof = json.loads(proofs[0].read_text())
    remote = release._api('releases/' + str(proof['releaseId']))
    print(json.dumps(verify(proof, remote)))


if __name__ == '__main__':
    try:
        main()
    except (KeyError, OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(str(error)) from error

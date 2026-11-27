#!/usr/bin/env python3
"""Play reads and explicit draft or track updates. No implicit production rollout."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import tempfile
import urllib.request

spec = importlib.util.spec_from_file_location('android_delivery_receipt', Path(__file__).with_name('android-delivery-receipt.py'))
receipt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(receipt)

APPLICATION_ID = 'com.gcsa.aegis'
SCOPE = 'https://www.googleapis.com/auth/androidpublisher'
TOKEN_URL = 'https://oauth2.googleapis.com/token'
API = 'https://androidpublisher.googleapis.com'
TRACKS = {'internal', 'beta', 'production'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True)


def draft_intent(version, build, profile, manifest_sha256, track):
    receipt.require_version_code(version, build)
    require(profile in receipt.PROFILES and track in {'internal', 'beta'}
            and re.fullmatch(r'[0-9a-f]{64}', manifest_sha256) is not None,
            'Invalid Play draft upload identity')
    return {'operation': 'play-upload', 'platform': 'android', 'applicationId': APPLICATION_ID,
            'version': version, 'build': build, 'profile': profile, 'format': 'aab',
            'manifestSha256': manifest_sha256, 'parameters': {'releaseStatus': 'draft', 'track': track}}


def download_ids(row):
    found = []
    universal = row.get('generatedUniversalApk')
    if isinstance(universal, dict) and isinstance(universal.get('downloadId'), str) and universal['downloadId']:
        found.append(universal['downloadId'])
    for key in ('generatedSplitApks', 'generatedAssetPackSlices', 'generatedStandaloneApks',
                'generatedRecoveryModules', 'unprotectedGeneratedSplitApks', 'unprotectedGeneratedStandaloneApks'):
        items = row.get(key, [])
        require(isinstance(items, list), 'Play generated APK list is invalid')
        for item in items:
            require(isinstance(item, dict), 'Play generated APK row is invalid')
            download = item.get('downloadId')
            if isinstance(download, str) and download:
                found.append(download)
    return found


def interpret_generated_apks(document, version_code):
    require(isinstance(document, dict) and (not document or isinstance(document.get('generatedApks'), list)),
            'Play generated APK response is invalid')
    groups = document.get('generatedApks', [])
    require(all(isinstance(group, dict) for group in groups), 'Play signing-key group is invalid')
    ids = [download for group in groups for download in download_ids(group)]
    base = {'packageName': APPLICATION_ID, 'versionCode': version_code, 'expired': False}
    if not ids:
        return {**base, 'processingState': 'PROCESSING', 'uploadState': 'PROCESSING'}
    identity = canonical({'downloadIds': sorted(set(ids)), 'packageName': APPLICATION_ID, 'versionCode': version_code})
    return {**base, 'processingState': 'VALID', 'uploadState': 'COMPLETE',
            'buildIdentitySha256': hashlib.sha256(identity.encode()).hexdigest()}


def _json_response(status, payload):
    raw = json.dumps(payload).encode()
    return status, {}, raw


class Play:
    """Transport returns (status, headers, body bytes). Redirects are refused by the caller."""

    def __init__(self, transport, token):
        require(isinstance(token, str) and token and '\n' not in token and '\r' not in token, 'Play token is invalid')
        self.transport, self.token = transport, token

    def _request(self, method, url, body=None, headers=None, ok=(200,)):
        response = self.transport(method, url, body, {'Authorization': 'Bearer ' + self.token, **(headers or {})})
        require(isinstance(response, tuple) and len(response) == 3, 'Play transport response is invalid')
        status, _headers, payload = response
        require(status not in {301, 302, 303, 307, 308}, 'Play refused to follow a redirect')
        require(status in ok, 'Play request failed')
        return status, payload

    def _write(self, authorize, method, url, body, headers=None):
        authorize()
        return self._request(method, url, body, headers)

    def status(self, version_code):
        require(type(version_code) is int and 1 <= version_code <= receipt.MAX_CODE, 'Invalid Play versionCode')
        status, payload = self._request(
            'GET', API + f'/androidpublisher/v3/applications/{APPLICATION_ID}/generatedApks/{version_code}', ok=(200, 404))
        if status == 404:
            return {'packageName': APPLICATION_ID, 'versionCode': version_code, 'expired': False,
                    'processingState': 'NOT_FOUND', 'uploadState': 'NOT_FOUND'}
        return interpret_generated_apks(json.loads(payload.decode()), version_code)

    def _test_track_state(self, edits, edit_id, track, version_code, *, pending_codes=None,
                          allow_recorded_draft=False, ignore_pending=False):
        status, payload = self._request('GET', f'{edits}/{edit_id}/tracks/{track}', ok=(200, 404))
        if status == 404:
            return [], []
        document = json.loads(payload.decode())
        require(isinstance(document, dict) and document.get('track') == track
                and isinstance(document.get('releases', []), list), 'Invalid Play track state')
        releases = []
        codes = set()
        pending = set(pending_codes or ())
        target_codes = {str(version_code)}
        has_pending = False
        for release in document.get('releases', []):
            require(isinstance(release, dict) and isinstance(release.get('versionCodes'), list)
                    and release['versionCodes'] and all(isinstance(code, str) and receipt.CODE.fullmatch(code)
                                                        and int(code) <= receipt.MAX_CODE
                                                        for code in release['versionCodes']),
                    'Invalid Play test track version codes')
            state = release.get('status')
            require(state in {'draft', 'completed', 'inProgress', 'halted'}, 'Invalid Play test release status')
            release_codes = set(release['versionCodes'])
            if state != 'completed':
                if ignore_pending:
                    continue
                matches_upload = target_codes <= pending and release_codes in (target_codes, pending)
                require(matches_upload and not has_pending and (state != 'draft' or allow_recorded_draft),
                        'Play test track has another pending rollout; reconcile it before writing')
                has_pending = True
            releases.append(release)
            codes.update(release_codes)
        require(not has_pending or codes == pending,
                'Play test track changed since the recorded upload; reconcile before writing')
        return releases, sorted(codes, key=int)

    def check_test_track(self, version_code, track, *, authorize_write):
        require(track in {'internal', 'beta'}, 'Only test tracks can be checked for test delivery')
        require(type(version_code) is int and 1 <= version_code <= receipt.MAX_CODE, 'Invalid Play versionCode')
        edits = API + f'/androidpublisher/v3/applications/{APPLICATION_ID}/edits'
        _status, payload = self._write(authorize_write, 'POST', edits, b'{}', {'Content-Type': 'application/json'})
        edit_id = json.loads(payload.decode()).get('id')
        require(isinstance(edit_id, str) and re.fullmatch(r'[A-Za-z0-9_-]{1,100}', edit_id), 'Play edit identity is invalid')
        _, codes = self._test_track_state(edits, edit_id, track, version_code)
        print(canonical({"track": track, "existingVersionCodes": codes}))
        return codes

    def upload_draft(self, aab, version_code, track, *, authorize_write):
        require(track in {'internal', 'beta'}, 'Play draft upload cannot target production')
        remote = self.status(version_code)
        require(remote['processingState'] == 'NOT_FOUND', 'Play already has this versionCode')
        edits = API + f'/androidpublisher/v3/applications/{APPLICATION_ID}/edits'
        _status, payload = self._write(authorize_write, 'POST', edits, b'{}', {'Content-Type': 'application/json'})
        edit = json.loads(payload.decode())
        edit_id = edit.get('id')
        require(isinstance(edit_id, str) and re.fullmatch(r'[A-Za-z0-9_-]{1,100}', edit_id), 'Play edit identity is invalid')
        completed_releases, retained_codes = self._test_track_state(edits, edit_id, track, version_code)
        other_track = 'beta' if track == 'internal' else 'internal'
        _, other_codes = self._test_track_state(edits, edit_id, other_track, version_code, ignore_pending=True)
        track_codes = {track: retained_codes, other_track: other_codes}
        upload = API + f'/upload/androidpublisher/v3/applications/{APPLICATION_ID}/edits/{edit_id}/bundles?uploadType=media'
        _status, payload = self._write(authorize_write, 'POST', upload, Path(aab).read_bytes(),
                                       {'Content-Type': 'application/octet-stream'})
        bundle = json.loads(payload.decode())
        require(bundle.get('versionCode') == version_code, 'Play stored a different versionCode')
        release = {'status': 'draft', 'versionCodes': [str(version_code)]}
        body = canonical({'releases': [*completed_releases, release], 'track': track}).encode()
        self._write(authorize_write, 'PUT', f'{edits}/{edit_id}/tracks/{track}', body, {'Content-Type': 'application/json'})
        self._write(authorize_write, 'POST', f'{edits}/{edit_id}:commit', b'')
        return {'editId': edit_id, 'packageName': APPLICATION_ID, 'releaseStatus': 'draft',
                'status': 'uploaded_draft', 'track': track, 'versionCode': version_code,
                'retainedVersionCodes': sorted(set(retained_codes + [str(version_code)]), key=int),
                'trackVersionCodes': track_codes}

    def update_track(self, version_code, track, status, user_fraction='', *, authorize_write,
                     pending_codes=None, expected_existing=None, upload_track=None):
        require(track in TRACKS and status in {'inProgress', 'completed'}, 'Unsupported Play track update')
        require(self.status(version_code)['processingState'] == 'VALID', 'Play has not finished this versionCode')
        require(status != 'completed' or user_fraction == '',
                'A completed rollout cannot specify a user fraction')
        require(status != 'inProgress' or (track != 'production' and user_fraction),
                'A partial rollout needs a non-production track and a user fraction')
        target_code = str(version_code)
        release = {'status': status, 'versionCodes': [target_code]}
        if user_fraction:
            require(re.fullmatch(r'0\.(?:[0-9]{0,3}[1-9])', user_fraction), 'Invalid Play user fraction')
            release['userFraction'] = float(user_fraction)
        completed = []
        edits = API + f'/androidpublisher/v3/applications/{APPLICATION_ID}/edits'
        _status, payload = self._write(authorize_write, 'POST', edits, b'{}', {'Content-Type': 'application/json'})
        edit_id = json.loads(payload.decode()).get('id')
        require(isinstance(edit_id, str) and re.fullmatch(r'[A-Za-z0-9_-]{1,100}', edit_id), 'Play edit identity is invalid')
        if track != 'production':
            existing_releases, retained_codes = self._test_track_state(
                edits, edit_id, track, version_code, pending_codes=pending_codes,
                allow_recorded_draft=track == upload_track,
            )
            if expected_existing is not None:
                require(pending_codes is not None and set(retained_codes) in (set(expected_existing), set(pending_codes)),
                        'Play test track changed since the recorded upload; reconcile before writing')
            if status == 'completed':
                release['versionCodes'] = sorted(set(retained_codes + [target_code]), key=int)
            else:
                staged = next((existing for existing in existing_releases
                               if existing['status'] in {'inProgress', 'halted'}), {})
                release = {**staged, **release}
                completed = [existing for existing in existing_releases if existing['status'] == 'completed']
                completed_codes = {code for existing in completed for code in existing['versionCodes']}
                require(target_code not in completed_codes, 'Play version is already completed on this track')
                legacy_codes = set(retained_codes) - completed_codes - {target_code}
                if legacy_codes:
                    require(legacy_codes <= set(expected_existing or ()),
                            'Play test track changed since the recorded upload; reconcile before writing')
                    completed.append({'status': 'completed', 'versionCodes': sorted(legacy_codes, key=int)})
        body = canonical({'releases': [*completed, release], 'track': track}).encode()
        self._write(authorize_write, 'PUT', f'{edits}/{edit_id}/tracks/{track}', body, {'Content-Type': 'application/json'})
        self._write(authorize_write, 'POST', f'{edits}/{edit_id}:commit', b'')
        return {'editId': edit_id, 'status': status, 'track': track, 'versionCode': version_code}


def sign_assertion(key, now, signer):
    require(isinstance(key, dict) and isinstance(key.get('client_email'), str) and isinstance(key.get('private_key'), str),
            'Play service account is incomplete')
    require(key['client_email'].endswith('.gserviceaccount.com') and 'PRIVATE KEY' in key['private_key'],
            'Play service account is incomplete')
    header = {'alg': 'RS256', 'typ': 'JWT'}
    claims = {'iss': key['client_email'], 'scope': SCOPE, 'aud': TOKEN_URL, 'iat': now, 'exp': now + 3600}
    unsigned = '.'.join(_b64(json.dumps(item, separators=(',', ':')).encode()) for item in (header, claims))
    return unsigned + '.' + signer(unsigned, key['private_key'])


def _b64(value):
    import base64
    return base64.urlsafe_b64encode(value).rstrip(b'=').decode()


def openssl_signer(unsigned, private_key):
    with tempfile.TemporaryDirectory(prefix='aegis-play-') as temp:
        key_path = Path(temp) / 'play.pem'
        key_path.write_text(private_key)
        key_path.chmod(0o600)
        import subprocess
        result = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', str(key_path)],
                                input=unsigned.encode(), capture_output=True, timeout=30)
    require(result.returncode == 0 and result.stdout, 'Play assertion could not be signed')
    return _b64(result.stdout)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        return None


def urllib_transport(method, url, body, headers):
    request = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=120) as response:
            return response.status, dict(response.headers), response.read()
    except urllib.error.HTTPError as error:
        return error.code, dict(error.headers), error.read()


def access_token(key, transport, now, signer=openssl_signer):
    assertion = sign_assertion(key, now, signer)
    body = f'grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion={assertion}'.encode()
    status, _headers, payload = transport('POST', TOKEN_URL, body, {'Content-Type': 'application/x-www-form-urlencoded'})
    require(status == 200, 'Play token request failed')
    token = json.loads(payload.decode()).get('access_token')
    require(isinstance(token, str) and token, 'Play token response is invalid')
    return token

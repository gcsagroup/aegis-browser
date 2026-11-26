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

    def upload_draft(self, aab, version_code, track, *, authorize_write):
        require(track in {'internal', 'beta'}, 'Play draft upload cannot target production')
        remote = self.status(version_code)
        require(remote['processingState'] == 'NOT_FOUND', 'Play already has this versionCode')
        edits = API + f'/androidpublisher/v3/applications/{APPLICATION_ID}/edits'
        _status, payload = self._write(authorize_write, 'POST', edits, b'{}', {'Content-Type': 'application/json'})
        edit = json.loads(payload.decode())
        edit_id = edit.get('id')
        require(isinstance(edit_id, str) and re.fullmatch(r'[A-Za-z0-9_-]{1,100}', edit_id), 'Play edit identity is invalid')
        upload = API + f'/upload/androidpublisher/v3/applications/{APPLICATION_ID}/edits/{edit_id}/bundles?uploadType=media'
        _status, payload = self._write(authorize_write, 'POST', upload, Path(aab).read_bytes(),
                                       {'Content-Type': 'application/octet-stream'})
        bundle = json.loads(payload.decode())
        require(bundle.get('versionCode') == version_code, 'Play stored a different versionCode')
        release = {'status': 'draft', 'versionCodes': [str(version_code)]}
        body = canonical({'releases': [release], 'track': track}).encode()
        self._write(authorize_write, 'PUT', f'{edits}/{edit_id}/tracks/{track}', body, {'Content-Type': 'application/json'})
        self._write(authorize_write, 'POST', f'{edits}/{edit_id}:commit', b'')
        return {'editId': edit_id, 'packageName': APPLICATION_ID, 'releaseStatus': 'draft',
                'status': 'uploaded_draft', 'track': track, 'versionCode': version_code}

    def update_track(self, version_code, track, status, user_fraction='', *, authorize_write):
        require(track in TRACKS and status in {'inProgress', 'completed'}, 'Unsupported Play track update')
        require(self.status(version_code)['processingState'] == 'VALID', 'Play has not finished this versionCode')
        require(status != 'completed' or (track == 'production' and user_fraction == ''),
                'Only an explicit production submission can complete a rollout')
        require(status != 'inProgress' or (track != 'production' and user_fraction),
                'A partial rollout needs a non-production track and a user fraction')
        if user_fraction:
            require(re.fullmatch(r'0\.(?:[0-9]{0,3}[1-9])', user_fraction), 'Invalid Play user fraction')
            body = ('{"releases":[{"status":"%s","userFraction":%s,"versionCodes":["%s"]}],"track":"%s"}'
                    % (status, user_fraction, version_code, track)).encode()
        else:
            body = canonical({'releases': [{'status': status, 'versionCodes': [str(version_code)]}], 'track': track}).encode()
        edits = API + f'/androidpublisher/v3/applications/{APPLICATION_ID}/edits'
        _status, payload = self._write(authorize_write, 'POST', edits, b'{}', {'Content-Type': 'application/json'})
        edit_id = json.loads(payload.decode()).get('id')
        require(isinstance(edit_id, str) and re.fullmatch(r'[A-Za-z0-9_-]{1,100}', edit_id), 'Play edit identity is invalid')
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

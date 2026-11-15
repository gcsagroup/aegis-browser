"""Credential-free, mirrored verifier for an operator-merged development grant."""
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import re

CENTRAL = 'gcsagroup/apple-signing'
CENTRAL_ID = 1364015229
GRANT_PATH = '.github/signing/products/aegis/develop-activation.json'
POLICY_PATH = '.github/signing/products/aegis/develop-operator-policy.json'
MODE = 'operator-merged-activation-pr-v1'


def require(condition, message='Invalid operator activation authority'):
    if not condition:
        raise ValueError(message)


def timestamp(value):
    require(isinstance(value, str) and value.endswith('Z'), 'Operator timestamps must be UTC')
    return datetime.fromisoformat(value[:-1] + '+00:00')


def utc(value):
    return value.isoformat().replace('+00:00', 'Z')


def content(api, path, commit, protocol):
    require(protocol.hex_value(commit, 40))
    value = api('repos/' + CENTRAL + '/contents/' + path + '?ref=' + commit)
    require(value['path'] == path and value['type'] == 'file' and value['encoding'] == 'base64')
    require(type(value['size']) is int and 0 < value['size'] <= 1024 * 1024)
    raw = base64.b64decode(''.join(value['content'].split()), validate=True)
    require(len(raw) == value['size'] and hashlib.sha1(b'blob ' + str(len(raw)).encode() + b'\0' + raw).hexdigest() == value['sha'])
    return value['sha'], protocol.parse(raw)


def validate_window(proof, approval, protocol, now=None, *, historical=False):
    require(proof['mode'] == MODE and proof['independentHumanApproval'] is False
            and proof['environmentBypassObserved'] is None)
    require(proof['grant_sha256'] == protocol.digest(approval), 'Original grant differs')
    issued, expiry, merged = map(timestamp, (approval['issued_at'], approval['expires_at'], proof['merged_at']))
    require(0 < (expiry - issued).total_seconds() <= 24 * 60 * 60, 'Operator grant exceeds 24 hours')
    start, end = max(issued, merged), min(expiry, merged + timedelta(hours=24))
    require(start < end and proof['not_before'] == utc(start) and proof['expires_at'] == utc(end))
    if not historical:
        require(start <= (now or datetime.now(timezone.utc)) < end, 'Operator authorization is outside its window')


def authenticate(api, approval, registry_commit, protocol, *, historical_proof=None, now=None):
    """Live admission ends with a local clock check; historical readback uses frozen proof."""
    base = 'repos/' + CENTRAL
    executor = approval['executor_commit']
    require(protocol.hex_value(registry_commit, 40) and protocol.hex_value(executor, 40))
    repo = api(base)
    require(repo['id'] == CENTRAL_ID and repo['full_name'] == CENTRAL and repo['private'] is True)
    policy_blob, policy = content(api, POLICY_PATH, executor, protocol)
    require(set(policy) == {'schema', 'mode', 'status', 'operator', 'maximum_authorization_seconds', 'independentHumanApproval'}
            and policy['schema'] == 'aegis-develop-operator-policy-v1' and policy['mode'] == MODE
            and policy['status'] == 'configured' and policy['maximum_authorization_seconds'] == 86400
            and policy['independentHumanApproval'] is False, 'Operator policy is not configured')
    operator = policy['operator']
    require(set(operator) == {'id', 'login', 'type'} and protocol.positive(operator['id'])
            and operator['id'] != protocol.QUINN.actor_id and operator['type'] == 'User'
            and isinstance(operator['login'], str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9-]{0,38}', operator['login']))
    if historical_proof is None:
        associated = api(base + '/commits/' + registry_commit + '/pulls?per_page=100')
        require(isinstance(associated, list) and len(associated) < 100)
        matches = [pr for pr in associated if pr.get('merged_at') and pr.get('merge_commit_sha') == registry_commit]
        require(len(matches) == 1, 'One operator-merged activation PR required')
        number = matches[0]['number']
    else:
        number = historical_proof['pr_number']
    require(protocol.positive(number))
    pr = api(base + '/pulls/' + str(number))
    require(pr['number'] == number and protocol.positive(pr['id']) and pr['merged'] is True
            and pr['state'] == 'closed' and pr['draft'] is False and pr['merge_commit_sha'] == registry_commit
            and pr['base']['ref'] == 'main' and pr['base']['sha'] == executor
            and pr['base']['repo']['id'] == pr['head']['repo']['id'] == CENTRAL_ID)
    require(pr['merged_by']['id'] == operator['id'] and pr['merged_by']['type'] == 'User', 'Wrong activation operator')
    head = pr['head']['sha'] if historical_proof is None else historical_proof['pr_head']
    require(protocol.hex_value(head, 40))
    merged = api(base + '/git/commits/' + registry_commit)
    reviewed = api(base + '/git/commits/' + head)
    require(merged['sha'] == registry_commit and [row['sha'] for row in merged['parents']] == [executor],
            'Activation must be one squash commit on the reviewed executor')
    require(reviewed['sha'] == head and reviewed['tree']['sha'] == merged['tree']['sha'], 'Activation HEAD tree differs')
    comparison = api(base + '/compare/' + executor + '...' + registry_commit)
    require(comparison['base_commit']['sha'] == comparison['merge_base_commit']['sha'] == executor
            and comparison['status'] == 'ahead' and comparison['ahead_by'] == comparison['total_commits'] == 1
            and comparison['behind_by'] == 0 and len(comparison['files']) == 1)
    changed = comparison['files'][0]
    require(changed['filename'] == GRANT_PATH and changed['status'] == 'modified'
            and 'previous_filename' not in changed, 'Activation PR may only change its grant')
    tree = api(base + '/git/trees/' + merged['tree']['sha'] + '?recursive=1')
    require(tree['sha'] == merged['tree']['sha'] and tree['truncated'] is False)
    grant_files = [row for row in tree['tree'] if row['path'] == GRANT_PATH]
    require(len(grant_files) == 1 and grant_files[0]['mode'] == '100644' and grant_files[0]['type'] == 'blob')
    grant_blob, registry = content(api, GRANT_PATH, registry_commit, protocol)
    require(grant_blob == grant_files[0]['sha']
            and registry == {'schema': protocol.QUINN.registry_schema, 'scope': protocol.QUINN.scope,
                             'status': 'active', 'authorizations': [approval]}, 'Frozen activation bytes differ')
    issued, expiry, merged_at = map(timestamp, (approval['issued_at'], approval['expires_at'], pr['merged_at']))
    proof = {'mode': MODE, 'repository_id': CENTRAL_ID, 'pr_id': pr['id'], 'pr_number': number,
             'pr_head': head, 'registry_commit': registry_commit, 'executor_commit': executor,
             'registry_blob': grant_blob, 'operator_policy_blob': policy_blob,
             'operator': operator, 'merged_at': pr['merged_at'], 'grant_sha256': protocol.digest(approval),
             'not_before': utc(max(issued, merged_at)), 'expires_at': utc(min(expiry, merged_at + timedelta(hours=24))),
             'independentHumanApproval': False, 'environmentBypassObserved': None}
    if historical_proof is None:
        permission = api(base + '/collaborators/' + operator['login'] + '/permission')
        require(permission['permission'] == 'admin' and {key: permission['user'][key] for key in operator} == operator,
                'Activation operator no longer has administrator permission')
        require(api(base + '/git/ref/heads/main')['object']['sha'] == registry_commit, 'Activation was superseded')
    else:
        require(proof == historical_proof, 'Original operator proof differs')
    validate_window(proof, approval, protocol, now, historical=historical_proof is not None)
    return proof

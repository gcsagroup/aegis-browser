"""Versioned, credential-free Aegis archive exchange. Also shipped by Aegis."""
import hashlib
import io
import stat
import zipfile
import json
import re
from pathlib import Path
from typing import NamedTuple, Optional

SCHEMA = 'aegis-central-archive-v1'
SOURCE = {'name': 'gcsagroup/aegis-browser', 'id': 1348409663}
APP_ID = '6827988433'
TARGETS = ('com.gcsa.aegis', 'com.gcsa.aegis.safari', 'com.gcsa.aegis.share')


class Policy(NamedTuple):
    scope: str
    schema: str
    source_name: str
    source_id: int
    branch: str
    workflow: str
    producer_workflow: str
    registry_schema: str
    environment_prefix: str
    actor_id: Optional[int]


PROD = Policy('production', SCHEMA, SOURCE['name'], SOURCE['id'], 'main',
              '.github/workflows/aegis-ios-export.yml', '.github/workflows/ios-central-archive.yml',
              'aegis-central-export-activation-v1', 'aegis-ios', None)
QUINN = Policy('quinn-develop-poc', 'aegis-central-archive-v2', 'quinn521/aegis-browser',
               1363949860, 'develop', '.github/workflows/aegis-ios-develop-export.yml',
               '.github/workflows/ios-central-develop-archive.yml',
               'aegis-central-export-activation-v2', 'aegis-ios-develop', 287940781)
STATUS_AUTHORITY = 'a34c412158ff95a689dd810ae624119b3f2b279b'
MAX_DEVELOP_AUTHORIZATION_SECONDS = 24 * 60 * 60


def policy(scope):
    matches = [value for value in (PROD, QUINN) if value.scope == scope]
    require(len(matches) == 1, 'Unknown central execution scope')
    return matches[0]


def source_identity(expected):
    require(expected in (PROD, QUINN))
    return {'name': expected.source_name, 'id': expected.source_id}


def require(condition, message='Invalid central archive contract'):
    if not condition:
        raise ValueError(message)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True,
                      allow_nan=False).encode()


def unique(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'Duplicate JSON key')
        result[key] = value
    return result


def parse(raw):
    require(len(raw) <= 1024 * 1024, 'Metadata exceeds bound')
    return json.loads(raw, object_pairs_hook=unique,
                      parse_constant=lambda _: require(False))


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def file_digest(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def hex_value(value, length):
    return isinstance(value, str) and re.fullmatch('[0-9a-f]{' + str(length) + '}', value) is not None


def positive(value):
    return type(value) is int and value > 0


def allocation(request):
    # The provider, profile, schema, source and attempt do not create a new budget.
    return digest({'application': APP_ID, 'platform': 'IOS',
                   'version': request['version'], 'build': request['build']})


def validate(request, expected=PROD):
    require(expected in (PROD, QUINN))
    fields = {
        'schema', 'product', 'source', 'producer', 'version', 'build', 'profile',
        'team', 'application', 'archive_sha256', 'archive_size', 'destination'}
    if expected == QUINN:
        fields.add('scope')
    require(type(request) is dict and set(request) == fields)
    require(request['schema'] == expected.schema and request['product'] == 'aegis'
            and request['application'] == APP_ID and request['destination'] == 'export-only')
    if expected == QUINN:
        require(request['scope'] == QUINN.scope, 'Development exception is Quinn-only')
    # First activation is deliberately one Alpha allocation, independently approved.
    require(request['profile'] == 'alpha')
    require(isinstance(request['version'], str)
            and re.fullmatch(r'(?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8})', request['version']))
    require(isinstance(request['build'], str) and re.fullmatch(r'[1-9][0-9]{0,9}', request['build']))
    require(isinstance(request['team'], str) and re.fullmatch(r'[A-Z0-9]{10}', request['team']))
    source = request['source']
    source_fields = {'repository', 'sha', 'tree'} | ({'ref'} if expected == QUINN else set())
    require(type(source) is dict and set(source) == source_fields
            and source['repository'] == source_identity(expected) and hex_value(source['sha'], 40)
            and hex_value(source['tree'], 40))
    if expected == QUINN:
        require(source['ref'] == 'refs/heads/develop', 'Development exception requires develop')
    producer = request['producer']
    require(type(producer) is dict and set(producer) == {
        'repository', 'repository_id', 'run_id', 'attempt', 'commit', 'workflow'})
    require(isinstance(producer['repository'], str)
            and re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', producer['repository'])
            and all(positive(producer[k]) for k in ('repository_id', 'run_id', 'attempt'))
            and producer['attempt'] == 1 and hex_value(producer['commit'], 40)
            and producer['workflow'] == expected.producer_workflow)
    require(hex_value(request['archive_sha256'], 64)
            and positive(request['archive_size']) and request['archive_size'] <= 2 * 1024**3)
    return request


def extract_archive(raw, directory, *, envelope=False):
    require(not directory.exists())
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        rows = archive.infolist()
        require(0 < len(rows) <= 100000 and len({r.filename for r in rows}) == len(rows)
                  and sum(r.file_size for r in rows) <= 4 * 1024**3)
        paths = set()
        for row in rows:
            name = row.filename.rstrip('/')
            path = Path(name)
            require(name and not path.is_absolute() and '\\' not in name
                      and all(part not in {'', '.', '..'} for part in name.split('/'))
                      and not row.flag_bits & 1
                      and stat.S_IFMT(row.external_attr >> 16) in (0, stat.S_IFREG, stat.S_IFDIR))
            key = name.casefold()
            require(key not in paths, 'Archive path collision')
            paths.add(key)
        if envelope:
            require({r.filename for r in rows} == {'request.json', 'archive.zip'})
        directory.mkdir(parents=True, mode=0o700)
        for row in rows:
            target = directory / row.filename
            if row.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with target.open('xb') as output:
                    output.write(archive.read(row))
                # Preserve executable bits for Mach-O binaries and archive tools.
                target.chmod(0o700 if row.external_attr >> 16 & 0o111 else 0o600)

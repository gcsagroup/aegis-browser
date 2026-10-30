"""Copyable identity pins; never a substitute for producer or operator verification."""
import re

OPERATION_LABELS = {
    'package': '仅打包 / Package',
    'draft': '私有草稿 / Draft',
    'upload': '上传 TestFlight / Upload',
    'wait': '等待处理 / Wait',
    'status': '查询状态 / Status',
    'metadata': '更新测试说明 / Metadata',
    'compliance': '加密合规 / Compliance',
    'distribute-internal': '内测分发 / Distribute internal',
    'distribute-external': '外测分发 / Distribute external',
}
PRODUCT_LABELS = {
    'auto': '自动 / Auto',
    'alpha': 'Alpha · 仅内测 / Internal only',
    'beta': 'Beta · 内外测 / Internal and external',
    'release': 'Release · 通用 / Universal',
}


def canonical(value, labels):
    if value in labels:
        return value
    for command, label in labels.items():
        if value == label:
            return command
    raise ValueError('Unknown operation or target product')


def decode(value):
    if not isinstance(value, str) or len(value) > 256:
        raise ValueError('Invalid delivery receipt')
    fields = value.split(':')
    if len(fields) != 8 or fields[0] != 'aegis-ios-v1':
        raise ValueError('Copy the complete delivery receipt from the last successful run summary')
    _, profile, version, build, package_run, state_run, attempt, digest = fields
    if (profile not in {'alpha', 'beta', 'release'} or
            re.fullmatch(r'[0-9]{1,10}\.[0-9]{1,10}(?:\.[0-9]{1,10})?', version) is None or
            re.fullmatch(r'[1-9][0-9]{0,9}', build) is None or
            any(re.fullmatch(r'[1-9][0-9]{0,15}', item) is None for item in [package_run, state_run, attempt]) or
            re.fullmatch(r'[0-9a-f]{64}', digest) is None):
        raise ValueError('Invalid delivery receipt identity')
    return dict(profile=profile, version=version, build=build, package_run_id=package_run,
                upload_run_id='' if state_run == package_run else state_run,
                source_attempt=attempt, manifest_sha256=digest)


def encode(profile, version, build, package_run, state_run, attempt, digest):
    value = ':'.join(map(str, ['aegis-ios-v1', profile, version, build, package_run, state_run, attempt, digest]))
    decode(value)
    return value

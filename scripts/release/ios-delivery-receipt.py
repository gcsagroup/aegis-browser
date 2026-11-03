"""Copyable identity pins; never a substitute for producer or operator verification."""
import re

# Historical labels also appear in run titles used by replay checks.
OPERATION_LABELS = {
    'package': ('Package', '仅打包 / Package'),
    'package-upload': ('Package and upload', '打包并上传 TF / Package and upload'),
    'draft': ('Draft', '私有草稿 / Draft'),
    'upload': ('Upload', '上传 TestFlight / Upload'),
    'wait': ('Wait', '等待处理 / Wait'),
    'status': ('Status', '查询状态 / Status'),
    'metadata': ('Metadata', '更新测试说明 / Metadata'),
    'compliance': ('Compliance', '加密合规 / Compliance'),
    'distribute-internal': ('Distribute internal', '内测分发 / Distribute internal'),
    'distribute-external': ('Distribute external', '外测分发 / Distribute external'),
}
PRODUCT_LABELS = {
    'auto': ('Auto', '自动 / Auto'),
    'alpha': ('Alpha', 'Alpha · 仅内测 / Internal only'),
    'beta': ('Beta', 'Beta · 内外测 / Internal and external'),
    'release': ('Release', 'Release · 通用 / Universal'),
}


def canonical(value, labels):
    if value in labels:
        return value
    for command, accepted_labels in labels.items():
        if value in accepted_labels:
            return command
    raise ValueError('Unknown operation or target product')


def decode(value):
    if not isinstance(value, str) or len(value) > 256:
        raise ValueError('Invalid delivery receipt')
    fields = value.split(':')
    same_run_uploaded = len(fields) == 9 and fields[0] == 'aegis-ios-v2' and fields[-1] == 'uploaded'
    if same_run_uploaded:
        fields = fields[:-1]
    if len(fields) != 8 or (fields[0] != 'aegis-ios-v1' and not same_run_uploaded):
        raise ValueError('Copy the complete delivery receipt from the last successful run summary')
    _, profile, version, build, package_run, state_run, attempt, digest = fields
    if (profile not in {'alpha', 'beta', 'release'} or
            re.fullmatch(r'[0-9]{1,10}\.[0-9]{1,10}(?:\.[0-9]{1,10})?', version) is None or
            re.fullmatch(r'[1-9][0-9]{0,9}', build) is None or
            any(re.fullmatch(r'[1-9][0-9]{0,15}', item) is None for item in [package_run, state_run, attempt]) or
            re.fullmatch(r'[0-9a-f]{64}', digest) is None):
        raise ValueError('Invalid delivery receipt identity')
    if same_run_uploaded and package_run != state_run:
        raise ValueError('Invalid same-run uploaded receipt')
    return dict(profile=profile, version=version, build=build, package_run_id=package_run,
                upload_run_id='' if state_run == package_run and not same_run_uploaded else state_run,
                source_attempt=attempt, manifest_sha256=digest)


def encode(profile, version, build, package_run, state_run, attempt, digest, uploaded=False):
    value = ':'.join(map(str, ['aegis-ios-v1', profile, version, build, package_run, state_run, attempt, digest]))
    if uploaded and str(package_run) == str(state_run):
        value = value.replace('aegis-ios-v1:', 'aegis-ios-v2:', 1) + ':uploaded'
    decode(value)
    return value

"""Install an explicitly supplied, ordered test relay list in the Alpha app bundle."""
import base64
import ipaddress
import json
import os
from pathlib import Path
import re
import stat
import sys
import unicodedata
from urllib.parse import unquote, unquote_to_bytes, urlsplit

RESOURCE = 'AegisAlphaTestNodes.json'
MAX_NODES = 16
MAX_URI_BYTES = 8192
MAX_RESOURCE_BYTES = 131_500  # AccessAlphaNodeCatalogue rejects larger bundle resources.
MAX_JSON_BYTES = 6 * MAX_NODES * MAX_URI_BYTES + 1024  # Input may use JSON escapes.
UUID = re.compile(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}')
PORT_AUTHORITY = re.compile(r'(\[[0-9a-fA-F:.]+\]|[0-9a-zA-Z.-]+)(?::([0-9]{1,5}))?')
DNS_LABEL = re.compile(r'[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?')
BAD_ESCAPE = re.compile(r'%(?![0-9a-fA-F]{2})')
URI_QUERY = re.compile(r"[A-Za-z0-9._~!$&'()*+,;=:@/?%-]*")
FLOW = 'xtls-rprx-vision'
TLS = {'type', 'security', 'encryption', 'sni', 'host', 'fp'}
WS_FIELDS = TLS | {'path', 'alpn'}
TCP_TLS_FIELDS = TLS | {'flow', 'headerType'}
GRPC_FIELDS = (TLS - {'host'}) | {'path', 'serviceName', 'pbk', 'sid'}
REALITY_ALIASES = (('sni', 'serverName', 'server_name'), ('pbk', 'publicKey', 'public_key'),
                   ('sid', 'shortId', 'short_id'), ('fp', 'fingerprint'))
REALITY_FIELDS = (set().union(*REALITY_ALIASES) |
                  {'type', 'security', 'encryption', 'flow', 'headerType', 'spx', 'pcks', 'support-x25519mlkem768'})
WS_FINGERPRINTS = {'', 'chrome', 'firefox', 'safari', 'ios', 'android', 'edge'}
# Accepted names in the pinned Xray TLS tables, excluding the values rejected by
# the AccessKit bridge. Keep this in sync with the core pin and admission code.
CORE_FINGERPRINTS = WS_FINGERPRINTS | set("""
360 qq random randomized randomizednoalpn
hellofirefox_120 hellofirefox_148 hellochrome_120 hellochrome_131 hellochrome_133 hellochrome_155
helloios_13 helloios_14 helloedge_106 hellosafari_26_3 hello360_11_0 helloqq_11_1
hellorandomized hellorandomizedalpn hellorandomizednoalpn hellofirefox_auto hellofirefox_55
hellofirefox_56 hellofirefox_63 hellofirefox_65 hellofirefox_99 hellofirefox_102 hellofirefox_105
hellochrome_auto hellochrome_58 hellochrome_62 hellochrome_70 hellochrome_72 hellochrome_83
hellochrome_87 hellochrome_96 hellochrome_100 hellochrome_102 hellochrome_106_shuffle
helloios_auto helloios_11_1 helloios_12_1 helloandroid_11_okhttp helloedge_85 helloedge_auto
hellosafari_16_0 hellosafari_auto hello360_auto hello360_7_5 helloqq_auto
hellochrome_100_psk hellochrome_112_psk_shuf hellochrome_114_padding_psk_shuf
hellochrome_115_pq hellochrome_115_pq_psk hellochrome_120_pq
""".split())


def read_private(path, maximum):
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), 'rb') as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
            raise ValueError('Expected an owner-only private input file')
        raw = stream.read(maximum + 1)
    if not 0 < len(raw) <= maximum:
        raise ValueError('Invalid private input size')
    return raw


def write_private(path, raw):
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as stream:
        stream.write(raw)


def dns_name(name, allow_root_label=False):
    if allow_root_label:
        name = name.removesuffix('.')
    labels = name.split('.')
    return (len(name) <= 253 and len(labels) >= 2 and re.search(r'[A-Za-z]', labels[-1])
            and all(DNS_LABEL.fullmatch(label) for label in labels))


def valid_authority(value, port_required=False):
    match = PORT_AUTHORITY.fullmatch(value)
    if not match:
        return False
    host, port = match.groups()
    if (port is None and port_required) or (port is not None and not 0 < int(port) <= 65535):
        return False
    if dns_name(host, allow_root_label=True):
        return True
    try:
        if host.startswith('['):
            ipaddress.IPv6Address(host[1:-1])
        else:
            ipaddress.IPv4Address(host)
        return True
    except ValueError:
        return False


def control(character):
    return unicodedata.category(character) in ('Cc', 'Cf')


# Assigned letters, numbers, punctuation and symbols, minus the modifier
# categories (Lm, Sk) and the two spacing vowels Swift treats as extenders.
LABEL_START_CATEGORIES = frozenset(('Lu', 'Ll', 'Lt', 'Lo', 'Nd', 'Nl', 'No', 'Pc', 'Pd', 'Ps',
                                    'Pe', 'Pi', 'Pf', 'Po', 'Sm', 'Sc', 'So'))
LABEL_START_EXCLUDED = frozenset(('\u0e33', '\u0eb3'))


def label_start(character):
    return character.isascii() or (unicodedata.category(character) in LABEL_START_CATEGORIES
                                   and character not in LABEL_START_EXCLUDED)


def relay_host(address):
    # Foundation's IDNA handling of percent-encoded hosts differs from
    # Python's codec, and one unloadable entry discards the whole bundled list.
    # Admit only a percent-decoded ASCII host; international relays must be
    # written as A-labels (xn--...).
    if not address.isascii():
        raise ValueError('Invalid VLESS URI')
    return address


def share(uri):
    if (not isinstance(uri, str) or len(uri.encode('utf-8')) > MAX_URI_BYTES
            or any(c.isspace() or control(c) or ord(c) == 92 for c in uri) or BAD_ESCAPE.search(uri)):
        raise ValueError('Invalid VLESS URI')
    # The app parses everything before the label with
    # URLComponents(string:encodingInvalidCharacters: false), which rejects a
    # literal non-ASCII character; one such entry would discard the whole
    # bundled list. International relays must be written as A-labels.
    if not uri.partition('#')[0].isascii():
        raise ValueError('Invalid VLESS URI')
    parts = urlsplit(uri)
    user, separator, authority = parts.netloc.partition('@')
    raw_address, port_separator, port = authority.rpartition(':')
    try:
        address = relay_host(unquote(raw_address, errors='strict'))
    except UnicodeError as error:
        raise ValueError('Invalid VLESS URI') from error
    if (parts.scheme != 'vless' or not separator or not UUID.fullmatch(user)
            or not port_separator or not valid_authority(f'{address}:{port}', port_required=True)
            or (address.startswith('[') and address != raw_address) or parts.path not in ('', '/')
            or '://' in parts.fragment or not URI_QUERY.fullmatch(parts.query)):
        raise ValueError('Invalid VLESS URI')
    return parts, user.lower(), address


def share_query(raw):
    # URLComponents percent-decodes but preserves '+' in names and values.
    result = {}
    for pair in raw.split('&'):
        name, separator, value = pair.partition('=')
        name = unquote(name, errors='strict')
        value = unquote(value, errors='strict')
        if not separator or not name or name in result or any(map(control, value)):
            raise ValueError('Invalid or duplicate VLESS query field')
        result[name] = value
    return result


def alias(query, names, default=None):
    present = [query[key] for key in names if key in query]
    if len(present) > 1:
        raise ValueError('Ambiguous VLESS query aliases')
    return present[0] if present else default


def validate_reality_key(public_key, short_id):
    if (not re.fullmatch(r'[A-Za-z0-9_-]{43}', public_key)
            or len(base64.urlsafe_b64decode(public_key + '=')) != 32
            or not re.fullmatch(r'(?:[0-9a-fA-F]{2}){0,8}', short_id)):
        raise ValueError('Invalid REALITY credentials')


def valid_ws_target(path):
    if (not path.startswith('/') or path.startswith('//') or len(path) > 2048
            or not URI_QUERY.fullmatch(path) or BAD_ESCAPE.search(path)):
        return False
    decoded = unquote_to_bytes(path)
    if any(byte < 32 or byte == 127 for byte in decoded):
        return False
    without_http = re.sub(rb'(?i)(?<![a-z0-9+.-])https?://', b'', decoded)
    if re.search(rb'[A-Za-z][A-Za-z0-9+.-]*://', without_http):
        return False
    query = path.partition('?')[2]
    return all(unquote(item.partition('=')[0]) != 'ed' for item in query.split('&'))


def valid_spider(path):
    if not path:
        return True
    if (not path.startswith('/') or path.startswith('//') or not URI_QUERY.fullmatch(path)
            or BAD_ESCAPE.search(path)):
        return False
    query = path.partition('?')[2]
    return ';' not in query and all(unquote(item.partition('=')[0]) not in {'p', 'c', 't', 'i', 'r'}
                                    for item in query.split('&'))


def validate_transport(uri, *, anchor=False):
    identity, _ = validated_route(uri, anchor=anchor)
    return identity


def distinct_json_fields(pairs):
    fields = dict(pairs)
    if len(fields) != len(pairs):
        raise ValueError('Duplicate VMess field')
    return fields


def tls_name(sni, peer, fallback):
    if sni and peer and sni != peer:
        raise ValueError('Conflicting TLS names')
    name = sni or peer or fallback
    if not dns_name(name):
        raise ValueError('Invalid TLS name')
    return name


def validate_vmess(payload):
    if not re.fullmatch(r'[A-Za-z0-9+/_-]+={0,2}', payload):
        raise ValueError('Invalid VMess share')
    fields = json.loads(base64.b64decode(payload + '=' * (-len(payload) % 4), altchars=b'-_', validate=True)
                        .decode('utf-8'), object_pairs_hook=distinct_json_fields)
    allowed = {'v', 'ps', 'add', 'port', 'id', 'aid', 'net', 'type', 'host', 'path', 'tls',
               'sni', 'peer', 'fp', 'alpn', 'scy', 'method'}
    if (not isinstance(fields, dict) or not fields.keys() <= allowed
            or any(type(value) not in ((str, int) if key in {'port', 'v', 'aid'} else (str,))
                   for key, value in fields.items())):
        raise ValueError('Invalid VMess fields')
    net, address, port, client = (fields.get(key, '') for key in ('net', 'add', 'port', 'id'))
    if (str(fields.get('v', '2')) != '2' or str(fields.get('aid', '0')) != '0'
            or net not in {'ws', 'httpupgrade'} or fields.get('tls') != 'tls'
            or fields.get('type', '') not in {'', 'none'} or not UUID.fullmatch(client)
            or not re.fullmatch(r'[0-9]{1,5}', str(port))):
        raise ValueError('Invalid VMess format')
    dial_address = f'[{address}]' if ':' in address and not address.startswith('[') else address
    if not valid_authority(f'{dial_address}:{port}', port_required=True):
        raise ValueError('Invalid VMess endpoint')

    server = tls_name(fields.get('sni'), fields.get('peer'), address)
    host, path = fields.get('host') or server, fields.get('path') or '/'
    fingerprint = fields.get('fp', '')
    alpn = fields.get('alpn') or 'http/1.1'
    primary, alternate = fields.get('scy'), fields.get('method')
    cipher = primary or alternate or 'auto'
    if (fingerprint not in WS_FINGERPRINTS or alpn != 'http/1.1'
            or not valid_authority(host) or not valid_ws_target(path)
            or (primary and alternate and primary != alternate)
            or cipher not in {'auto', 'aes-128-gcm', 'chacha20-poly1305'}):
        raise ValueError('Invalid VMess TLS transport or cipher')
    identity = client.lower()
    return identity, ('vmess', net, dial_address.strip('[]'), int(port), identity, server,
                      fingerprint, alpn, host, path, cipher)


def bandwidth(value):
    if not re.fullmatch(r'[0-9]{1,6}', value) or int(value) > 100_000:
        raise ValueError('Invalid Hysteria2 bandwidth')
    return int(value)


def validate_additional_tls(uri, scheme):
    wire, _, label = uri.partition('#')
    if (len(uri.encode('utf-8')) > MAX_URI_BYTES or not wire.isascii() or '://' in label
            # Match the Swift parser's Character boundary at the fragment delimiter.
            or (label and not label_start(label[0]))
            or any(c.isspace() or control(c) or c == chr(92) for c in uri) or BAD_ESCAPE.search(wire)):
        raise ValueError('Invalid TLS share')
    if scheme == 'vmess':
        return validate_vmess(wire.split('://', 1)[1])

    parts = urlsplit(wire)
    password, separator, authority = parts.netloc.partition('@')
    host, port_separator, port = authority.rpartition(':')
    address = relay_host(unquote(host, errors='strict'))
    password = unquote(password, errors='strict')
    if (not separator or not port_separator or not UUID.fullmatch(password)
            or parts.path not in {'', '/'} or not valid_authority(f'{address}:{port}', port_required=True)
            or not URI_QUERY.fullmatch(parts.query)):
        raise ValueError('Invalid private Alpha TLS relay')
    query = share_query(parts.query) if parts.query else {}
    server = tls_name(query.get('sni'), query.get('peer'), address)
    tls = {'sni', 'peer', 'alpn'}
    key = (address.strip('[]'), int(port), password, server)
    if scheme == 'trojan':
        fingerprint = query.get('fp', '')
        if (not query.keys() <= (tls | {'fp', 'type', 'security'})
                or query.get('alpn', 'http/1.1') != 'http/1.1'
                or query.get('security', 'tls') != 'tls' or query.get('type', 'tcp') not in {'tcp', 'raw'}
                or fingerprint not in WS_FINGERPRINTS):
            raise ValueError('Invalid Trojan TLS fields')
        return password.lower(), ('trojan', *key, fingerprint)

    if (not query.keys() <= (tls | {'insecure', 'upmbps', 'downmbps'})
            or query.get('alpn', 'h3') != 'h3' or query.get('insecure', '0') != '0'):
        raise ValueError('Invalid Hysteria2 TLS fields')
    return password.lower(), ('hysteria2', *key, bandwidth(query.get('upmbps', '0')),
                              bandwidth(query.get('downmbps', '0')))


def validated_route(uri, *, anchor=False):
    scheme = uri.partition('://')[0].lower() if isinstance(uri, str) else ''
    if not anchor and scheme in {'vmess', 'trojan', 'hysteria2', 'hy2'}:
        return validate_additional_tls(uri, scheme)
    parts, identity, address = share(uri)
    # The bundled list parser splits at the first Character equal to '#'.
    # An extending scalar would hide the delimiter from that parser.
    if not anchor and parts.fragment and not label_start(parts.fragment[0]):
        raise ValueError('Invalid VLESS URI')
    query = share_query(parts.query)
    if anchor:
        # The shared quota session reads the legacy TCP/REALITY node. Its
        # parser defaults missing flow and transport; the Alpha list does not.
        query['type'] = query.get('type') or 'tcp'
        query['flow'] = query.get('flow') or FLOW
        if (query['type'], query.get('security'), query['flow']) != ('tcp', 'reality', FLOW):
            raise ValueError('Invalid quota anchor transport')
    fields = {
        ('tcp', 'tls', FLOW): TCP_TLS_FIELDS,
        ('ws', 'tls', None): WS_FIELDS,
        ('tcp', 'reality', FLOW): REALITY_FIELDS,
        ('grpc', 'reality', None): GRPC_FIELDS,
    }.get((query.get('type'), query.get('security'), query.get('flow')))
    if fields is None or query.keys() - fields or query.get('encryption', '') not in ('', 'none'):
        raise ValueError('Unsupported Alpha transport or query field')
    # The app's list loader admits exactly these four tuples, then runs the
    # per-transport AccessKit parsers. Check their arguments before Xcode.
    if fields == REALITY_FIELDS:
        server, key, short, finger = (alias(query, names) for names in REALITY_ALIASES)
    else:
        server, key, short, finger = (query.get(name) for name in ('sni', 'pbk', 'sid', 'fp'))
    if not server or not dns_name(server):
        raise ValueError('Invalid VLESS server name')
    if fields == WS_FIELDS:
        request_host = query.get('host', server)
        path = query.get('path', '/')
        alpn = query.get('alpn', '')
        finger = finger if finger is not None else ''
        if (not valid_authority(request_host) or not valid_ws_target(path)
                or finger not in WS_FINGERPRINTS or alpn not in ('', 'http/1.1')):
            raise ValueError('Invalid WS/TLS fields')
        transport_settings = (request_host, path, alpn)
    else:
        transport_settings = ()
        if finger is None or (fields == REALITY_FIELDS and not finger):
            finger = 'chrome'
        finger = finger.lower()
        if finger not in CORE_FINGERPRINTS or (query['security'] == 'reality' and not finger):
            raise ValueError('Invalid VLESS fingerprint')
    if fields in (TCP_TLS_FIELDS, REALITY_FIELDS) and query.get('headerType', 'none') != 'none':
        raise ValueError('Unsupported TCP header')
    if fields == TCP_TLS_FIELDS and query.get('host') and not valid_authority(query['host']):
        raise ValueError('Invalid TCP/TLS host hint')
    if query['security'] == 'reality':
        if key is None or short is None:
            raise ValueError('Missing REALITY fields')
        validate_reality_key(key, short)
    if fields == REALITY_FIELDS:
        if ('://' in uri[len('vless://'):] or query.get('pcks', '') != ''
                or query.get('support-x25519mlkem768', 'true') != 'true'
                or not valid_spider(query.get('spx', ''))):
            raise ValueError('Invalid TCP/REALITY fields')
        transport_settings = (key, short.lower(), query.get('spx', ''))
    if fields == GRPC_FIELDS:
        service = query.get('serviceName', query.get('path'))
        if (service is None or len(service) > 2048 or query.get('path', service) != service
                or any(part in ('.', '..') or not re.fullmatch(r'[A-Za-z0-9._~-]+', part)
                       for part in service.removeprefix('/').split('/'))):
            raise ValueError('Invalid or ambiguous gRPC service name')
        transport_settings = (key, short.lower(), service)
    route = (query['type'], query['security'], address, parts.port, identity, server, finger, *transport_settings)
    return identity, route


def canonicalize(raw, expected_user=None):
    if not 0 < len(raw) <= MAX_JSON_BYTES:
        raise ValueError('Invalid Alpha list size')
    nodes = json.loads(raw.decode('utf-8'))
    if not isinstance(nodes, list) or not 1 <= len(nodes) <= MAX_NODES:
        raise ValueError('Expected a nonempty bounded Alpha list')
    seen = set()
    for uri in nodes:
        identity, route = validated_route(uri)
        if expected_user is None:
            expected_user = identity
        if identity != expected_user:
            raise ValueError('Alpha list user differs from the anchored node')
        if route in seen:
            raise ValueError('Duplicate Alpha node')
        seen.add(route)
    output = json.dumps(nodes, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
    if len(output) > MAX_RESOURCE_BYTES:
        raise ValueError('Canonical Alpha resource exceeds the app limit')
    return output


def install(channel, source, output):
    output.unlink(missing_ok=True)
    if source == '/dev/null':
        return
    if channel != 'alpha':
        raise ValueError('Private Alpha list requires the Alpha channel')
    raw = canonicalize(read_private(source, MAX_JSON_BYTES))
    # The installed app must be able to read the bundle resource. The private
    # archive and build products are enclosed by the runner's 0700 directory.
    with output.open('xb') as resource:
        resource.write(raw)


if __name__ == '__main__':
    try:
        install(os.environ.get('AEGIS_ACCESS_RELEASE_CHANNEL'), os.environ['SCRIPT_INPUT_FILE_1'],
                Path(os.environ['SCRIPT_OUTPUT_FILE_0']))
    except (KeyError, OSError, ValueError, UnicodeError, RecursionError):
        sys.exit('Cannot package the private Alpha node list. Check the private input and channel.')

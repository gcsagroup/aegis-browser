"""Stage one private VLESS URI in an explicitly selected internal app build."""
import os
from pathlib import Path
import sys
from urllib.parse import urlsplit


def install(channel, source, output):
    output.unlink(missing_ok=True)
    if channel not in ('dev', 'alpha', 'beta') or source == '/dev/null':
        return
    # A build setting contains only a path. Never include file contents in errors.
    with open(source, 'rb') as stream:
        uri = stream.read(8193)
    if len(uri) > 8192:
        raise ValueError
    uri = uri.decode('utf-8').strip()
    parts = urlsplit(uri)
    if (parts.scheme != 'vless' or not parts.username or not parts.hostname or not parts.port
            or any(ch.isspace() for ch in uri)):
        raise ValueError
    with output.open('xb') as resource:
        resource.write(uri.encode('utf-8'))


if __name__ == '__main__':
    try:
        install(os.environ.get('AEGIS_ACCESS_RELEASE_CHANNEL'), os.environ['SCRIPT_INPUT_FILE_1'],
                Path(os.environ['SCRIPT_OUTPUT_FILE_0']))
    except (KeyError, OSError, ValueError):
        sys.exit('Cannot package the private Access test node. Supply a file with one VLESS URI.')

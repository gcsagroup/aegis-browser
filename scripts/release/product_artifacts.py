"""Publish verified deliverables into the user's Downloads artifact catalogue."""
import hashlib
import os
from pathlib import Path
import re
import shutil
import tempfile

CHANNELS = {'alpha': 'alpha', 'beta': 'Beta', 'release': 'Release', 'draft': 'Draft'}


def digest(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def publish(files, product, version, build, channel, root=None):
    """Copy an explicit hash-bound inventory atomically, without overwriting."""
    if (not re.fullmatch(r'[a-z][a-z0-9-]{0,63}', product)
            or not re.fullmatch(r'[0-9]+\.[0-9]+(?:\.[0-9]+)?', version)
            or not re.fullmatch(r'[1-9][0-9]{0,9}', build) or channel not in CHANNELS):
        raise ValueError('Invalid artifact catalogue identity')
    base = Path(root) if root else Path.home() / 'Downloads/artifacts'
    base = base.expanduser().resolve()
    target = base / product / version / CHANNELS[channel]
    for parent in (base / product, base / product / version, target):
        if parent.is_symlink():
            raise ValueError('Artifact catalogue must use physical child directories')
    target.mkdir(parents=True, exist_ok=True)
    result = []
    for filename, expected in files:
        original = Path(filename)
        if original.is_symlink() or not original.is_file() or digest(original) != expected:
            raise ValueError('Original deliverable differs from its verified digest')
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', original.name) or '..' in original.name:
            raise ValueError('Unsafe deliverable filename')
        destination = target / ('build-' + build + '-' + expected[:12] + '-' + original.name)
        if destination.is_symlink():
            raise ValueError('Existing catalogue entry is a symlink')
        if destination.exists():
            if digest(destination) != expected:
                raise ValueError('Existing catalogue entry differs; retain both originals')
        else:
            with tempfile.NamedTemporaryFile(dir=target, prefix='.publish-', delete=False) as output:
                temporary = Path(output.name)
                try:
                    with original.open('rb') as source:
                        shutil.copyfileobj(source, output)
                    output.flush()
                    os.fsync(output.fileno())
                    if digest(temporary) != expected:
                        raise ValueError('Deliverable changed during publication')
                    try:
                        os.link(temporary, destination)
                    except FileExistsError:
                        if destination.is_symlink() or digest(destination) != expected:
                            raise ValueError('Concurrent catalogue publication differs')
                finally:
                    temporary.unlink(missing_ok=True)
        result.append(str(destination))
    return result

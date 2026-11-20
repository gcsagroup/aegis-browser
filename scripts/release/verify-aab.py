#!/usr/bin/env python3
"""Verify an Android App Bundle signature without printing key material."""
import importlib.util
from pathlib import Path
import re
import subprocess

spec = importlib.util.spec_from_file_location('android_package_archive', Path(__file__).with_name('android_package_archive.py'))
archive = importlib.util.module_from_spec(spec)
spec.loader.exec_module(archive)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def normalize_certificate(value):
    text = str(value).replace(':', '').replace(' ', '').lower()
    require(re.fullmatch(r'[0-9a-f]{64}', text) is not None, 'Android certificate SHA-256 is invalid')
    return text


def parse_certificate(output):
    require(isinstance(output, str) and 'jar verified' in output.lower(), 'Android App Bundle signature was not verified')
    require(re.search(r'jar is unsigned', output, re.IGNORECASE) is None, 'Android App Bundle is unsigned')
    found = re.findall(r'SHA-?256:\s*((?:[0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2})', output)
    unique = {normalize_certificate(item) for item in found}
    require(len(unique) == 1, 'Android App Bundle certificate is missing or ambiguous')
    return unique.pop()


def certificate_sha256(path, runner=None):
    archive.assert_aab(path)
    command = ['jarsigner', '-verify', '-certs', '-verbose', str(path)]
    if runner is None:
        result = subprocess.run(command, capture_output=True, text=True, timeout=120)
        output, code = (result.stdout or '') + (result.stderr or ''), result.returncode
    else:
        output, code = runner(command)
    require(code == 0, 'jarsigner could not verify the Android App Bundle')
    return parse_certificate(output)

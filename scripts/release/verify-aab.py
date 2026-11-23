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


def certificate_sha256(path):
    archive.assert_aab(path)
    source = Path(__file__).with_name('VerifiedAabCertificate.java')
    result = subprocess.run(['java', str(source), str(Path(path).resolve())],
                            capture_output=True, text=True, timeout=120)
    require(result.returncode == 0, 'App Bundle payload must be signed by a single verified certificate')
    return normalize_certificate(result.stdout.strip())

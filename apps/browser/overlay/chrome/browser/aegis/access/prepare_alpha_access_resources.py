#!/usr/bin/env python3
"""Stage private Access inputs without printing node values."""

import argparse
import hashlib
import json
import os
import subprocess
from pathlib import Path
import tempfile


def stage_windows_directory(output: Path) -> None:
    # The path is data, not interpolated into PowerShell source. Create the
    # directory with an inheritable current-user DACL before writing secrets.
    windows = Path(os.environ["SystemRoot"])
    exe = windows / "System32/WindowsPowerShell/v1.0/powershell.exe"
    script = r"""
$ErrorActionPreference = 'Stop'
$path = $env:AEGIS_PRIVATE_ACCESS_STAGE
$user = [Security.Principal.WindowsIdentity]::GetCurrent().User
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetOwner($user)
$acl.SetAccessRuleProtection($true, $false)
$rule = [Security.AccessControl.FileSystemAccessRule]::new(
    $user, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
$acl.AddAccessRule($rule)
if (-not [IO.Directory]::Exists($path)) {
    [IO.Directory]::CreateDirectory($path, $acl) | Out-Null
}
$item = Get-Item -LiteralPath $path -Force
if (-not $item.PSIsContainer -or
    ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { exit 1 }
$existing = Get-Acl -LiteralPath $path
if ($existing.GetOwner([Security.Principal.SecurityIdentifier]) -ne $user) { exit 1 }
# Ninja precreates output parents with inherited permissions. Secure the owned
# directory before any resource is written, including on that first build.
Set-Acl -LiteralPath $path -AclObject $acl
$actual = Get-Acl -LiteralPath $path
$rules = @($actual.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
if (-not $actual.AreAccessRulesProtected -or
    $actual.GetOwner([Security.Principal.SecurityIdentifier]) -ne $user -or
    $rules.Count -ne 1 -or $rules[0].IdentityReference -ne $user -or
    $rules[0].AccessControlType -ne 'Allow' -or
    $rules[0].FileSystemRights -ne 'FullControl' -or
    $rules[0].InheritanceFlags -ne $rule.InheritanceFlags -or
    $rules[0].PropagationFlags -ne 'None') { exit 1 }
"""
    result = subprocess.run(
        [str(exe), "-NoProfile", "-NonInteractive", "-Command", script],
        env={**os.environ, "AEGIS_PRIVATE_ACCESS_STAGE": str(output.absolute())},
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
        timeout=20)
    if result.returncode:
        raise ValueError("Cannot establish private Windows resource directory")


def stage(source: Path, output: Path, channel: str, binary_name: str = "xray") -> None:
    if (os.name == "nt") != (binary_name == "xray.exe"):
        raise ValueError("Private test executable does not match the build host")
    if channel not in ("alpha", "beta") or binary_name not in ("xray", "xray.exe"):
        raise ValueError("Test resources are restricted to Alpha and Beta")
    manifest_bytes = (source / "core-manifest.json").read_bytes()
    manifest = json.loads(manifest_bytes)
    if (manifest.get("schemaVersion") != 1 or manifest.get("channel") != channel
            or manifest.get("binaryRelativePath") != binary_name
            or manifest.get("nodeConfigRelativePath") != "node.json"):
        raise ValueError("Invalid private resource manifest")
    binary = (source / binary_name).read_bytes()
    node_bytes = (source / "node.json").read_bytes()
    if (hashlib.sha256(binary).hexdigest() != manifest.get("binarySha256")
            or hashlib.sha256(node_bytes).hexdigest() != manifest.get("nodeConfigSha256")):
        raise ValueError("Private resource pin mismatch")
    node = json.loads(node_bytes)
    outbound = node.get("outbounds", [None])[0]
    if (not isinstance(outbound, dict) or outbound.get("protocol") != "vless"
            or outbound.get("streamSettings", {}).get("network") != "tcp"
            or outbound.get("streamSettings", {}).get("security") != "reality"):
        raise ValueError("Unsupported private test transport")
    if os.name == "nt":
        stage_windows_directory(output)
    else:
        output.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(output, 0o700)
    # Replace inodes, so an already assembled/running immutable candidate
    # cannot be changed through a hardlinked build resource.
    for name, data, mode in (("core-manifest.json", manifest_bytes, 0o600),
                             ("node.json", node_bytes, 0o600),
                             (binary_name, binary, 0o700)):
        descriptor, temporary = tempfile.mkstemp(dir=output, prefix=".private-")
        try:
            with os.fdopen(descriptor, "wb") as stream:
                if os.name != "nt":
                    os.fchmod(stream.fileno(), mode)
                stream.write(data)
            os.replace(temporary, output / name)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--channel", required=True)
    parser.add_argument("--binary", choices=("xray", "xray.exe"), default="xray")
    parser.add_argument("--source-dir", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    try:
        stage(args.source_dir, args.output_dir, args.channel, args.binary)
    except (OSError, ValueError, KeyError, IndexError, TypeError, subprocess.TimeoutExpired):
        # Private input values and exception payloads never enter build logs.
        parser.exit(1, "Cannot prepare validated private test resources.\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""Verify actual EmbeddedCore build inputs without changing the reviewed source lock."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import shutil


SLICE_KEYS = {"ios-arm64": "iosArm64Sha256", "ios-arm64-simulator": "iosArm64SimulatorSha256"}


def file_digest(path):
    with Path(path).open("rb") as stream:
        digest = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
        return digest.hexdigest()


def directory_digest(root):
    root = Path(root)
    files = sorted(path for path in root.rglob("*") if path.is_file() and not path.name.startswith("."))
    if not files:
        raise ValueError(f"empty build input: {root.name}")
    digest = hashlib.sha256()
    for path in files:
        digest.update(path.relative_to(root).as_posix().encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def slice_digests(framework):
    framework = Path(framework)
    simulator = [path for path in framework.iterdir()
                 if path.is_dir() and "simulator" in path.name and "arm64" in path.name]
    if len(simulator) != 1:
        raise ValueError("expected one arm64 simulator slice")
    return {"iosArm64Sha256": directory_digest(framework / "ios-arm64"),
            "iosArm64SimulatorSha256": directory_digest(simulator[0])}


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def record(root, source_lock, products, mode):
    root, source_lock, products = Path(root).resolve(), Path(source_lock).resolve(), Path(products).resolve()
    lock = json.loads(source_lock.read_text())
    if lock.get("status") != "verified_build":
        raise ValueError("source lock must be verified_build")
    framework = products / "AegisEmbeddedCore.xcframework"
    actual = slice_digests(framework)
    if mode == "strict" and any(lock["artifacts"].get(key) != value for key, value in actual.items()):
        raise ValueError("actual EmbeddedCore slices differ from frozen digests")
    effective = {**lock, "artifacts": {**lock["artifacts"], **actual}}
    write_json(products / "embedded-core-lock.json", effective)
    # Xcode's script sandbox grants literal directory inputs, not recursive reads.
    # Enumerate the exact files/directories the in-build verification will read.
    inputs = [root / "scripts/release/ios_embedded_core.py", source_lock,
              products / "embedded-core-lock.json", products / "build-manifest.json"]
    for directory in (root / "apps/ios/EmbeddedCore/bridge", framework):
        inputs.extend([directory, *sorted(directory.rglob("*"))])
    (products / "build-inputs.xcfilelist").write_text("".join(str(path) + "\n" for path in inputs))
    binding = shutil.which("gomobile")
    if not binding:
        raise ValueError("gomobile build tool is missing")
    metadata = subprocess.check_output(["go", "version", "-m", binding], text=True)
    modules = [line.split()[1:3] for line in metadata.splitlines() if line.split()[:1] == ["mod"]]
    if len(modules) != 1:
        raise ValueError("cannot identify the actual gomobile module")
    binding_module = "@".join(modules[0])
    if lock.get("toolchain", {}).get("gomobile", binding_module) != binding_module:
        raise ValueError("actual gomobile module differs from the source pin")
    manifest = {
        "schemaVersion": 1,
        "kind": "ios-embedded-core-build",
        "digestMode": mode,
        "sourceCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
        "sourceLockSha256": file_digest(source_lock),
        "bridgeSha256": directory_digest(root / "apps/ios/EmbeddedCore/bridge"),
        "effectiveLockSha256": file_digest(products / "embedded-core-lock.json"),
        "frameworkSha256": directory_digest(framework),
        "slices": actual,
        "inputFileListSha256": file_digest(products / "build-inputs.xcfilelist"),
        "goVersion": subprocess.check_output(["go", "version"], text=True).strip(),
        "xcodeVersion": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
        "gomobileModule": binding_module,
        "sdkVersions": {sdk: subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-version"], text=True).strip()
                        for sdk in ("iphoneos", "iphonesimulator")},
    }
    write_json(products / "build-manifest.json", manifest)
    return manifest


def verify(root, source_lock, products):
    root, source_lock, products = Path(root), Path(source_lock), Path(products)
    manifest = json.loads((products / "build-manifest.json").read_text())
    if manifest.get("schemaVersion") != 1 or manifest.get("kind") != "ios-embedded-core-build":
        raise ValueError("unsupported EmbeddedCore build manifest")
    expected = {
        "sourceLockSha256": file_digest(source_lock),
        "bridgeSha256": directory_digest(root / "apps/ios/EmbeddedCore/bridge"),
        "effectiveLockSha256": file_digest(products / "embedded-core-lock.json"),
        "frameworkSha256": directory_digest(products / "AegisEmbeddedCore.xcframework"),
        "slices": slice_digests(products / "AegisEmbeddedCore.xcframework"),
        "inputFileListSha256": file_digest(products / "build-inputs.xcfilelist"),
    }
    if any(manifest.get(key) != value for key, value in expected.items()):
        raise ValueError("actual EmbeddedCore build inputs differ from their manifest")
    source = json.loads(source_lock.read_text())
    effective = json.loads((products / "embedded-core-lock.json").read_text())
    if source.get("status") != "verified_build" or effective != {
        **source, "artifacts": {**source["artifacts"], **expected["slices"]}
    }:
        raise ValueError("bundled lock differs from the source pins or actual slices")
    return {**manifest, "manifestSha256": file_digest(products / "build-manifest.json")}


def verify_bundle(bundle, products):
    bundle, products = Path(bundle), Path(products)
    lock = bundle / "Frameworks/AccessKit.framework/embedded-core-lock.json"
    if file_digest(lock) != file_digest(products / "embedded-core-lock.json"):
        raise ValueError("app bundled a different EmbeddedCore lock")
    manifest = bundle / "Frameworks/AccessKit.framework/embedded-core-build.json"
    if file_digest(manifest) != file_digest(products / "build-manifest.json"):
        raise ValueError("app bundled a different EmbeddedCore build manifest")
    return {"appBinarySha256": file_digest(bundle / "Aegis"), "bundledLockSha256": file_digest(lock),
            "bundledBuildManifestSha256": file_digest(manifest)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("record", "verify", "install"))
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--source-lock", required=True, type=Path)
    parser.add_argument("--products", required=True, type=Path)
    parser.add_argument("--mode", choices=("strict", "ci-rebuild"), default="strict")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--bundle", type=Path)
    args = parser.parse_args()
    result = (record(args.root, args.source_lock, args.products, args.mode) if args.operation == "record"
              else verify(args.root, args.source_lock, args.products))
    if args.operation == "install":
        if not args.bundle:
            parser.error("install requires --bundle")
        shutil.copyfile(args.products / "embedded-core-lock.json", args.bundle / "embedded-core-lock.json")
        shutil.copyfile(args.products / "build-manifest.json", args.bundle / "embedded-core-build.json")
    elif args.bundle:
        result.update(verify_bundle(args.bundle, args.products))
    if args.output:
        write_json(args.output, result)
    else:
        print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()

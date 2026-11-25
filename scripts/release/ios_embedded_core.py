"""Verify actual EmbeddedCore build inputs without changing the reviewed source lock."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess


SLICE_KEYS = {"ios-arm64": "iosArm64Sha256", "ios-arm64-simulator": "iosArm64SimulatorSha256"}
APPLE_TOOLCHAIN = "com.apple.dt.toolchain.XcodeDefault"
IOS_SDKS = ("iphoneos", "iphonesimulator")
MOBILE_DEPENDENCIES = {"golang.org/x/mod": "v0.42.0", "golang.org/x/sync": "v0.24.0",
                       "golang.org/x/tools": "v0.52.0"}
BINDING_TOOL_POLICY = "private-pinned-graph-v1"
CORE_NAME = "AegisEmbeddedCore"
FRAMEWORK_NAME = CORE_NAME + ".framework"


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


def normalized_xcframework_info():
    libraries = []
    for identifier, architectures, variant in (("ios-arm64", ["arm64"], {}),
            ("ios-arm64_x86_64-simulator", ["arm64", "x86_64"], {"SupportedPlatformVariant": "simulator"})):
        libraries.append({"LibraryIdentifier": identifier, "LibraryPath": FRAMEWORK_NAME,
                          "BinaryPath": f"{FRAMEWORK_NAME}/{CORE_NAME}", "SupportedPlatform": "ios",
                          "SupportedArchitectures": architectures, **variant})
    return {"AvailableLibraries": libraries, "CFBundlePackageType": "XFWK", "XCFrameworkFormatVersion": "1.0"}


def verify_frozen_xcframework_layout(framework):
    # The slice hashes cover the binary, headers and modules. Independently
    # lock the routing plist and exact paths so Xcode cannot choose another slice.
    # gobind names headers after the exported bridge packages, so the header set
    # follows the build as long as both slices agree and the umbrella is present.
    layout = normalized_xcframework_info()
    leaves = [Path(library["LibraryIdentifier"]) / FRAMEWORK_NAME for library in layout["AvailableLibraries"]]
    header_sets = {frozenset(path.name for path in (framework / leaf / "Headers").glob("*")) for leaf in leaves}
    headers = next(iter(header_sets)) if len(header_sets) == 1 else frozenset()
    if (CORE_NAME + ".h" not in headers
            or not all(re.fullmatch(r"[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*\.h", name, flags=re.ASCII)
                       for name in headers)):
        raise ValueError("EmbeddedCore XCFramework does not match the frozen Alpha layout")
    directories = set()
    files = {Path("Info.plist")}
    for leaf in leaves:
        directories.update((leaf.parent, leaf, leaf / "Headers", leaf / "Modules"))
        files.update(leaf / name for name in (CORE_NAME, "Info.plist", "Modules/module.modulemap"))
        files.update(leaf / "Headers" / name for name in headers)
    if (framework.is_symlink()
            or {path.relative_to(framework) for path in framework.rglob("*")} != directories | files
            or any((framework / path).is_symlink() or not (framework / path).is_dir() for path in directories)
            or any((framework / path).is_symlink() or not (framework / path).is_file() for path in files)
            or (framework / "Info.plist").read_bytes() != plistlib.dumps(layout, sort_keys=True)):
        raise ValueError("EmbeddedCore XCFramework does not match the frozen Alpha layout")


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def input_list(root, source_lock, products, framework):
    # Xcode's script sandbox grants literal directory inputs, not recursive reads.
    # Enumerate the exact files/directories the in-build verification will read.
    inputs = [root / "scripts/release/ios_embedded_core.py", source_lock,
              products / "embedded-core-lock.json", products / "build-manifest.json"]
    for directory in (root / "apps/ios/EmbeddedCore/bridge", framework):
        inputs.extend([directory, *sorted(directory.rglob("*"))])
    return "".join(str(path) + "\n" for path in inputs)


def tool_field(field, command, pattern, *, cwd=None, env=None):
    value = subprocess.check_output(command, cwd=cwd, env=env, text=True).removesuffix("\n")
    if not re.fullmatch(pattern, value, flags=re.ASCII):
        raise ValueError(f"unexpected EmbeddedCore {field} output")
    return value


def mobile_modules(toolchain, bridge):
    path, version = toolchain["gomobile"].split("@", 1)
    if path != "golang.org/x/mobile" or not re.fullmatch(r"v0\.0\.0-[0-9]{14}-[0-9a-f]{12}", version):
        raise ValueError("invalid pinned mobile module")
    rows = [line.split() for line in (bridge / "go.sum").read_text().splitlines()]
    modules = {}
    for module, revision in {path: version, **MOBILE_DEPENDENCIES}.items():
        sums = {}
        for suffix, key in (("", "Sum"), ("/go.mod", "GoModSum")):
            matches = [row[2] for row in rows if len(row) == 3 and row[:2] == [module, revision + suffix]]
            if len(matches) != 1 or not re.fullmatch(r"h1:[A-Za-z0-9+/]{43}=", matches[0]):
                raise ValueError("binding tool module is missing its approved checksums")
            sums[key] = matches[0]
        modules[module] = {"Path": module, "Version": revision, **sums}
    return modules


def go_version(go, toolchain, *, env=None):
    return tool_field("Go version", [go, "version"],
                      rf"go version go{re.escape(toolchain['go'])} darwin/(?:arm64|amd64)", env=env)


def check_mobile_tool(go, executable, name, toolchain, modules, host_arch, *, env=None):
    metadata = json.loads(subprocess.check_output([go, "version", "-m", "-json", executable], env=env))
    path = "golang.org/x/mobile"
    expected = {module: {key: value for key, value in info.items() if key != "GoModSum"}
                for module, info in modules.items()}
    dependencies = metadata.get("Deps", [])
    target = [(setting["Key"], setting["Value"]) for setting in metadata.get("Settings", [])
              if setting["Key"] in {"GOOS", "GOARCH"}]
    if (metadata.get("Path") != f"{path}/cmd/{name}" or metadata.get("GoVersion") != f"go{toolchain['go']}"
            or metadata.get("Main") != expected.pop(path)
            or len(dependencies) != len(expected)
            or {dep["Path"]: dep for dep in dependencies} != expected
            or sorted(target) != [("GOARCH", host_arch), ("GOOS", "darwin")]):
        raise ValueError(f"actual {name} host or module graph differs from the source pins")


def apple_build_environment(environment):
    """Use the same default toolchain in gomobile, xcrun and the receipt."""
    env = dict(environment, TOOLCHAINS=APPLE_TOOLCHAIN)
    selected = env.get("DEVELOPER_DIR") or subprocess.check_output(["xcode-select", "-p"], env=env, text=True).strip()
    developer = Path(selected)
    if developer.suffix == ".app":
        developer /= "Contents/Developer"
    if not developer.is_absolute() or not developer.is_dir():
        raise ValueError("Apple developer directory must be an existing absolute path")
    env["DEVELOPER_DIR"] = str(developer.resolve(strict=True))
    return env


def apple_metadata(env):
    if env.get("TOOLCHAINS") != APPLE_TOOLCHAIN or not env.get("DEVELOPER_DIR"):
        raise ValueError("Apple build does not select the pinned toolchain")
    version_pattern = r"[0-9]{1,3}(?:\.[0-9]{1,3}){0,2}"
    compiler_root = Path(env["DEVELOPER_DIR"]) / "Toolchains/XcodeDefault.xctoolchain/usr/bin"
    digests = {}
    clang = {}
    for sdk in IOS_SDKS:
        path = Path(tool_field(sdk + " clang", ["xcrun", "--sdk", sdk, "--find", "clang"],
                               r"/[^\r\n]+", env=env)).resolve(strict=True)
        if not path.is_relative_to(compiler_root) or not path.is_file():
            raise ValueError("clang is outside the pinned Xcode toolchain")
        if path not in digests:
            digests[path] = file_digest(path)
        clang[sdk] = digests[path]
    return {
        "appleToolchain": APPLE_TOOLCHAIN,
        "clangSha256": clang,
        "xcodeVersion": tool_field("Xcode version", ["xcodebuild", "-version"],
                                   rf"Xcode {version_pattern}\nBuild version [0-9]{{1,3}}[A-Z][0-9]{{1,6}}[a-z]?", env=env),
        "sdkVersions": {sdk: tool_field(sdk, ["xcrun", "--sdk", sdk, "--show-sdk-version"], version_pattern, env=env)
                        for sdk in IOS_SDKS},
        "sdkBuildVersions": {sdk: tool_field(sdk, ["xcrun", "--sdk", sdk, "--show-sdk-build-version"],
                                            r"[0-9]{1,3}[A-Z][0-9]{1,6}[a-z]?", env=env)
                             for sdk in IOS_SDKS},
    }


def verify_apple_pin(metadata, toolchain):
    if (metadata.get("xcodeVersion", "").split("\n")[-1] != "Build version " + toolchain["xcode"]
            or any(key in toolchain and metadata.get(key) != toolchain[key]
                   for key in ("sdkVersions", "sdkBuildVersions"))):
        raise ValueError("actual Apple toolchain differs from the source pin")


def tool_metadata(root, toolchain, bridge, apple, go, tools, env):
    version = go_version(go, toolchain, env=env)
    modules = mobile_modules(toolchain, bridge)
    gomobile, gobind = tools
    for name, executable in (("gomobile", gomobile), ("gobind", gobind)):
        check_mobile_tool(go, executable, name, toolchain, modules, version.rsplit("/", 1)[1], env=env)
    return {
        "sourceCommit": tool_field("source commit", ["git", "--no-replace-objects", "rev-parse", "HEAD"],
                                   r"[0-9a-f]{40}", cwd=root, env=env),
        "goVersion": version,
        "bindingToolPolicy": BINDING_TOOL_POLICY,
        "gomobileModule": toolchain["gomobile"],
        "gobindModule": toolchain["gomobile"],
        **apple,
    }


def record(root, source_lock, products, mode, xcode_root=None, xcode_lock=None, *, apple, go, tools, env=None):
    root, source_lock, products = Path(root).resolve(), Path(source_lock).resolve(), Path(products).resolve()
    lock = json.loads(source_lock.read_text())
    if lock.get("status") != "verified_build":
        raise ValueError("source lock must be verified_build")
    framework = products / "AegisEmbeddedCore.xcframework"
    actual = slice_digests(framework)
    if mode == "strict" and any(lock["artifacts"].get(key) != value for key, value in actual.items()):
        raise ValueError("actual EmbeddedCore slices differ from frozen digests")
    compiled_bridge = directory_digest(products / "work/bridge")
    if (products / "compiled-bridge.sha256").read_text().strip() != compiled_bridge:
        raise ValueError("EmbeddedCore bridge copy differs from the gomobile build input")
    metadata = tool_metadata(root, lock["toolchain"], products / "work/bridge", apple, go, tools, env)
    if mode == "strict":
        verify_apple_pin(metadata, lock["toolchain"])
    effective = {**lock, "artifacts": {**lock["artifacts"], **actual}}
    write_json(products / "embedded-core-lock.json", effective)
    (products / "build-inputs.xcfilelist").write_text(input_list(
        Path(xcode_root or root).resolve(), Path(xcode_lock or source_lock).resolve(), products, framework))
    manifest = {
        "schemaVersion": 1,
        "kind": "ios-embedded-core-build",
        "digestMode": mode,
        "sourceLockSha256": file_digest(source_lock),
        "bridgeSha256": compiled_bridge,
        "compiledBridgeSha256": compiled_bridge,
        "effectiveLockSha256": file_digest(products / "embedded-core-lock.json"),
        "frameworkSha256": directory_digest(framework),
        "slices": actual,
        "inputFileListSha256": file_digest(products / "build-inputs.xcfilelist"),
        **metadata,
    }
    write_json(products / "build-manifest.json", manifest)
    return manifest


def verify(root, source_lock, products, mode=None):
    root, source_lock, products = Path(root).resolve(), Path(source_lock).resolve(), Path(products).resolve()
    manifest_bytes = (products / "build-manifest.json").read_bytes()
    manifest = json.loads(manifest_bytes)
    if manifest.get("schemaVersion") != 1 or manifest.get("kind") != "ios-embedded-core-build":
        raise ValueError("unsupported EmbeddedCore build manifest")
    file_list = products / "build-inputs.xcfilelist"
    if file_list.read_text() != input_list(root, source_lock, products, products / "AegisEmbeddedCore.xcframework"):
        raise ValueError("Xcode input list points to different build inputs")
    bridge = directory_digest(root / "apps/ios/EmbeddedCore/bridge")
    source_bytes = source_lock.read_bytes()
    effective_bytes = (products / "embedded-core-lock.json").read_bytes()
    expected = {
        "sourceLockSha256": hashlib.sha256(source_bytes).hexdigest(),
        "bridgeSha256": bridge,
        "compiledBridgeSha256": bridge,
        "effectiveLockSha256": hashlib.sha256(effective_bytes).hexdigest(),
        "frameworkSha256": directory_digest(products / "AegisEmbeddedCore.xcframework"),
        "slices": slice_digests(products / "AegisEmbeddedCore.xcframework"),
        "inputFileListSha256": file_digest(products / "build-inputs.xcfilelist"),
    }
    if any(manifest.get(key) != value for key, value in expected.items()):
        raise ValueError("actual EmbeddedCore build inputs differ from their manifest")
    source = json.loads(source_bytes)
    toolchain = source["toolchain"]
    if any(manifest.get(key) != toolchain["gomobile"] for key in ("gomobileModule", "gobindModule")):
        raise ValueError("recorded binding tools differ from the source pin")
    if manifest.get("bindingToolPolicy") != BINDING_TOOL_POLICY:
        raise ValueError("missing private binding tool provenance")
    clang = manifest.get("clangSha256")
    if (manifest.get("appleToolchain") != APPLE_TOOLCHAIN or not isinstance(clang, dict)
            or set(clang) != set(IOS_SDKS)
            or any(not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value) for value in clang.values())):
        raise ValueError("missing pinned Apple compiler provenance")
    if mode == "strict" and any(source["artifacts"].get(k) != v for k, v in expected["slices"].items()):
        raise ValueError("cached slices differ from frozen digests")
    if mode == "strict":
        verify_apple_pin(manifest, toolchain)
    effective = json.loads(effective_bytes)
    if source.get("status") != "verified_build" or effective != {
        **source, "artifacts": {**source["artifacts"], **expected["slices"]}
    }:
        raise ValueError("bundled lock differs from the source pins or actual slices")
    return {**manifest, "manifestSha256": hashlib.sha256(manifest_bytes).hexdigest()}


def verify_bundle(bundle, products, derived, platform, *, owned_linker_paths=False):
    bundle, products = Path(bundle), Path(products)
    lock = bundle / "Frameworks/AccessKit.framework/embedded-core-lock.json"
    if file_digest(lock) != file_digest(products / "embedded-core-lock.json"):
        raise ValueError("app bundled a different EmbeddedCore lock")
    manifest = bundle / "Frameworks/AccessKit.framework/embedded-core-build.json"
    if file_digest(manifest) != file_digest(products / "build-manifest.json"):
        raise ValueError("app bundled a different EmbeddedCore build manifest")
    from ios_linked_core import verify_link
    return {**verify_link(bundle, products, Path(derived), platform, owned_linker_paths=owned_linker_paths),
            "appBinarySha256": file_digest(bundle / "Aegis"), "bundledLockSha256": file_digest(lock),
            "bundledBuildManifestSha256": file_digest(manifest)}


def verify_prepared_source(manifest, root, commit, framework):
    embedded = Path(root) / "apps/ios/EmbeddedCore"
    bridge = directory_digest(embedded / "bridge")
    lock_bytes = (embedded / "embedded-core-lock.json").read_bytes()
    if (manifest["sourceCommit"] != commit
            or manifest["sourceLockSha256"] != hashlib.sha256(lock_bytes).hexdigest()
            or manifest.get("compiledBridgeSha256") != bridge
            or manifest["bridgeSha256"] != bridge):
        raise ValueError("EmbeddedCore inputs do not match the prepared Alpha source")
    if manifest.get("digestMode") != "strict":
        raise ValueError("Commit-stamped Alpha requires a strict EmbeddedCore build; ci-rebuild cannot certify it")
    lock = json.loads(lock_bytes)
    if manifest.get("slices") != {key: lock["artifacts"][key] for key in SLICE_KEYS.values()}:
        raise ValueError("EmbeddedCore slices differ from the prepared Alpha source's frozen digests")
    verify_apple_pin(manifest, lock["toolchain"])
    verify_frozen_xcframework_layout(framework)


def install_verified_receipts(products, bundle, manifest):
    lock = (products / "embedded-core-lock.json").read_bytes()
    receipt = (products / "build-manifest.json").read_bytes()
    if (hashlib.sha256(lock).hexdigest() != manifest["effectiveLockSha256"]
            or hashlib.sha256(receipt).hexdigest() != manifest["manifestSha256"]):
        raise ValueError("EmbeddedCore lock or manifest changed during installation")
    (bundle / "embedded-core-lock.json").write_bytes(lock)
    (bundle / "embedded-core-build.json").write_bytes(receipt)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("verify", "install"))
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--source-lock", required=True, type=Path)
    parser.add_argument("--products", required=True, type=Path)
    parser.add_argument("--mode", choices=("strict", "ci-rebuild"))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--derived", type=Path)
    parser.add_argument("--platform", choices=("device", "simulator"))
    parser.add_argument("--prepared-source", nargs=2, metavar=("ROOT", "COMMIT"))
    args = parser.parse_args()
    if args.prepared_source and args.operation != "install":
        parser.error("--prepared-source requires install")
    result = verify(args.root, args.source_lock, args.products, args.mode)
    if args.operation == "install":
        if not args.bundle:
            parser.error("install requires --bundle")
        if args.prepared_source:
            verify_prepared_source(result, *args.prepared_source, args.products / "AegisEmbeddedCore.xcframework")
        install_verified_receipts(args.products, args.bundle, result)
    elif args.bundle:
        if not args.derived or not args.platform:
            parser.error("bundle verification requires --derived and --platform")
        result.update(verify_bundle(args.bundle, args.products, args.derived, args.platform))
    if args.output:
        write_json(args.output, result)
    else:
        print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()

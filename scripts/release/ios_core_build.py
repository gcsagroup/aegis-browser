#!/usr/bin/env python3
"""Build the pinned iOS binding with a private, reproducible gomobile layout."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from ios_embedded_core import (apple_build_environment, apple_metadata, check_mobile_tool, directory_digest,
                               go_version, mobile_modules, normalized_xcframework_info, record, verify_apple_pin)

NAME = "AegisEmbeddedCore"
FRAMEWORK = NAME + ".framework"
XCFRAMEWORK = NAME + ".xcframework"
BRIDGE_MODULE = "aegis.browser/ios/embeddedcore"
RELATIVE_BRIDGE = "../../../../bridge"
TARGETS = {("ios", "arm64"), ("iossimulator", "arm64"), ("iossimulator", "amd64")}
GO_CONTEXT = ("GOPROXY", "GOSUMDB", "GOPRIVATE", "GONOPROXY", "GONOSUMDB", "GOINSECURE", "GOVCS",
              "GOAUTH", "GOPATH", "GOBIN", "GOMODCACHE", "GOCACHE")
COMPILE_OVERRIDES = ("GOOS", "GOARCH", "GOARM64", "GOAMD64", "GOEXPERIMENT", "GOFIPS140", "GO_EXTLINK_ENABLED",
                     "GOCACHEPROG", "CC", "CXX", "AR", "CGO_ENABLED",
                     "CGO_CFLAGS", "CGO_CPPFLAGS", "CGO_CXXFLAGS", "CGO_FFLAGS", "CGO_LDFLAGS",
                     "CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH", "LIBRARY_PATH", "COMPILER_PATH",
                     "SDKROOT", "IPHONEOS_DEPLOYMENT_TARGET", "MACOSX_DEPLOYMENT_TARGET")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def capture(command, **kwargs):
    return subprocess.check_output(command, text=True, **kwargs)


def run(command, **kwargs):
    subprocess.run(command, check=True, **kwargs)


class UniquePlistDict(dict):
    def __setitem__(self, key, value):
        require(key not in self, "duplicate plist key")
        super().__setitem__(key, value)


def read_plist(data):
    return plistlib.loads(data, dict_type=UniquePlistDict)


def plain(path, directory=False):
    info = path.lstat()
    require(path.resolve(strict=True) == path and
            (stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode) and info.st_nlink == 1),
            f"unexpected build input type: {path.name}")
    return path


def plain_tree(root):
    plain(root, directory=True)
    for path in root.rglob("*"):
        plain(path, directory=path.is_dir())
        require(not path.name.startswith("."), "unexpected hidden build input")


def selected_go(version, repo, environment):
    require(re.fullmatch(r"1\.[0-9]+\.[0-9]+", version), "invalid pinned Go version")
    environment["GOTOOLCHAIN"] = "local"
    env = dict(environment, GOENV="off")

    def check(raw_root):
        if not raw_root:
            return None
        root = Path(raw_root)
        if not root.is_absolute() or not (root / "bin/go").is_file():
            return None
        root = root.resolve(strict=True)
        go = root / "bin/go"
        candidate = dict(env, GOROOT=str(root))
        try:
            actual = capture([go, "version"], env=candidate, stderr=subprocess.DEVNULL)
            if not re.fullmatch(rf"go version go{re.escape(version)} darwin/(?:arm64|amd64)\n", actual):
                return None
            compiler = capture([go, "tool", "compile", "-V=full"], env=candidate, stderr=subprocess.DEVNULL)
        except (OSError, subprocess.CalledProcessError):
            return None
        return go if compiler == f"compile version go{version}\n" else None

    inherited = environment.get("GOROOT")
    if scratch := environment.get("IOS_CI_SCRATCH"):
        require(inherited == str(Path(scratch) / "go"), "supervised Go root is outside job scratch")
        go = check(inherited)
        require(go is not None, "supervised Go root differs from the lock")
        return go
    if go := check(inherited):
        return go
    env.pop("GOROOT", None)
    if mise := shutil.which("mise", path=env["PATH"]):
        try:
            installed = capture([mise, "where", f"go@{version}"], cwd=repo,
                                env=dict(env, MISE_TRUSTED_CONFIG_PATHS=env.get("MISE_TRUSTED_CONFIG_PATHS", str(repo))),
                                stderr=subprocess.DEVNULL).strip()
        except subprocess.CalledProcessError:
            installed = None
        if go := check(installed):
            return go
    if launcher := shutil.which("go", path=env["PATH"]):
        try:
            if go := check(capture([launcher, "env", "GOROOT"], env=env, stderr=subprocess.DEVNULL).strip()):
                return go
        except subprocess.CalledProcessError:
            pass
    raise ValueError(f"locked Go {version} is not installed")


def binding_environment(go, environment):
    environment = dict(environment, GOROOT=str(go.parent.parent))
    effective = json.loads(capture([go, "env", "-json", "GOFLAGS", *GO_CONTEXT], env=environment))
    flags = effective.pop("GOFLAGS").split()
    workers = [flag for flag in flags if re.fullmatch(r"-p=[1-9][0-9]*", flag)]
    require(len(workers) <= 1 and all(flag in workers or flag in ("-trimpath", "-buildvcs=false") for flag in flags),
            "unapproved GOFLAGS for attributed EmbeddedCore build")
    # Preserve Go's effective transport and cache settings, including values from
    # GOENV. Disable that file for compilation so it cannot inject other inputs.
    environment.update(effective, GOENV="off", GO111MODULE="on", GOWORK="off", GOTOOLCHAIN="local", GOPACKAGESDRIVER="off",
                       GOFLAGS=" ".join(["-trimpath", "-buildvcs=false", *workers]), ZERO_AR_DATE="1",
                       SOURCE_DATE_EPOCH="0")
    for key in COMPILE_OVERRIDES:
        environment.pop(key, None)
    return environment


def module_file(go, cwd, env=None):
    plain(cwd / "go.mod")
    return json.loads(capture([go, "mod", "edit", "-json"], cwd=cwd, env=env))


def generated_dir(root, cwd):
    parts = cwd.relative_to(root / "tmp").parts
    require(len(parts) == 3 and re.fullmatch(r"gomobile-work-[0-9]+", parts[0])
            and (parts[1], parts[2].removeprefix("src-")) in TARGETS and parts[2].startswith("src-"),
            "unexpected gomobile module directory")
    return parts[1], parts[2][4:]


def normalize_module(go, root, cwd, *, before_tidy):
    plain(cwd, directory=True)
    require(plain(root / "bridge", directory=True)
            == (cwd / RELATIVE_BRIDGE).resolve(strict=True), "relative replacement does not resolve to measured bridge")
    info = module_file(go, cwd)
    target = str(root / "bridge") if before_tidy else RELATIVE_BRIDGE
    require(info["Module"]["Path"] == "gobind"
            and info.get("Replace") == [{"Old": {"Path": BRIDGE_MODULE}, "New": {"Path": target}}],
            "unexpected gomobile bridge replacement")
    if before_tidy:
        run([go, "mod", "edit", f"-replace={BRIDGE_MODULE}={RELATIVE_BRIDGE}"], cwd=cwd)
        normalize_module(go, root, cwd, before_tidy=False)


def go_wrapper(root, args):
    go = os.environ["AEGIS_BIND_GO"]
    cwd = Path.cwd()
    env = os.environ.copy()
    if cwd != root / "bridge":
        platform, arch = generated_dir(root, cwd)
        require(env["GOFLAGS"] == "-tags=ios" and env["GOOS"] == "ios" and env["GOARCH"] == arch,
                "unexpected gomobile Go target")
        env["GOFLAGS"] += " " + env["AEGIS_BIND_GOFLAGS"]
        if args == ["mod", "tidy"]:
            normalize_module(go, root, cwd, before_tidy=True)
        else:
            output = root / "tmp" / cwd.relative_to(root / "tmp").parts[0] / f"{NAME}-{platform}-{arch}.a"
            require(args == ["build", "-ldflags", "-buildid=", "-trimpath",
                             "-buildmode=c-archive", "-o", str(output), "./gobind"] and not os.path.lexists(output),
                    "unexpected gomobile archive command")
            normalize_module(go, root, cwd, before_tidy=False)
            plain(cwd / "go.sum")
            plain_tree(cwd / "gobind")
    else:
        # The pinned tool also runs per-target package queries from the bridge.
        if env["GOFLAGS"] == "-tags=ios":
            env["GOFLAGS"] += " " + env["AEGIS_BIND_GOFLAGS"]
        require(args and args[0] in {"env", "list", "version"}, "unexpected gomobile bridge command")
    os.execve(go, [go, *args], env)


def framework_plist(framework, *, normalize=False):
    plain_tree(framework)
    require({path.name for path in framework.iterdir()} == {"Info.plist", NAME, "Headers", "Modules"}
            and {path.name for path in (framework / "Modules").iterdir()} == {"module.modulemap"}
            and all(path.is_file() and path.suffix == ".h" for path in (framework / "Headers").iterdir())
            and (framework / "Headers" / f"{NAME}.h").is_file()
            and (framework / "Modules/module.modulemap").is_file() and plain(framework / NAME).stat().st_size > 0,
            "unexpected generated framework layout")
    path = plain(framework / "Info.plist")
    data = path.read_bytes()
    fields = read_plist(data)
    version = fields.get("CFBundleVersion")
    require(isinstance(version, str) and re.fullmatch(r"0\.0\.[0-9]+", version)
            and fields == {"CFBundleExecutable": NAME, "CFBundleIdentifier": NAME, "CFBundlePackageType": "FMWK",
                           "MinimumOSVersion": "100.0", "CFBundleVersion": version, "CFBundleShortVersionString": version},
            "unexpected gomobile framework plist")
    if normalize:
        original = f"<string>{version}</string>".encode()
        require(data.count(original) == 2, "unexpected gomobile framework version encoding")
        path.write_bytes(data.replace(original, b"<string>0.0.0</string>"))
    else:
        require(version == "0.0.0", "packaged framework version changed")


def package_wrapper(root, args):
    require(Path.cwd() == root / "bridge" and len(args) == 9 and args[0] == "-create-xcframework"
            and args[1:7:2] == ["-framework"] * 3 and args[-2:] == ["-output", str(root / XCFRAMEWORK)]
            and not os.path.lexists(root / XCFRAMEWORK), "unexpected gomobile XCFramework command")
    works = list((root / "tmp").glob("gomobile-work-*"))
    require(len(works) == 1 and re.fullmatch(r"gomobile-work-[0-9]+", works[0].name),
            "unexpected gomobile scratch layout")
    work = works[0]
    device = work / "ios/iphoneos" / FRAMEWORK
    simulator = work / "iossimulator/iphonesimulator" / FRAMEWORK
    require(sorted(args[2:7:2]) == sorted(map(str, (device, simulator, simulator))),
            "unexpected gomobile framework inputs")
    for framework in (device, simulator):
        framework_plist(framework, normalize=True)
    receipt = {key: directory_digest(framework) for key, framework in
               (("ios-arm64", device), ("ios-arm64_x86_64-simulator", simulator))}
    with (root / "packaging-inputs.json").open("x") as stream:
        json.dump(receipt, stream)
    executable = os.environ["AEGIS_BIND_XCODEBUILD"]
    os.execv(executable, [executable, *args])


def normalize_xcframework(path):
    plain_tree(path)
    canonical = normalized_xcframework_info()
    expected = canonical["AvailableLibraries"]
    libraries = [item["LibraryIdentifier"] for item in expected]
    require({item.name for item in path.iterdir()} == {"Info.plist", *libraries}, "unexpected XCFramework layout")
    plist = plain(path / "Info.plist")
    fields = read_plist(plist.read_bytes())
    found = fields.get("AvailableLibraries")
    require(isinstance(found, list) and len(found) == len(expected) and all(isinstance(entry, dict) for entry in found),
            "unexpected XCFramework library list")
    require(fields.keys() == {"AvailableLibraries", "CFBundlePackageType", "XCFrameworkFormatVersion"}
            and fields["CFBundlePackageType"] == "XFWK" and fields["XCFrameworkFormatVersion"] == "1.0"
            and sorted(found, key=lambda item: item.get("LibraryIdentifier", "")) == expected,
            "unexpected XCFramework library identities")
    input_digests = json.loads(plain(path.parent / "packaging-inputs.json").read_bytes())
    binary_digests = {}
    for name in libraries:
        slice_path = plain(path / name, directory=True)
        require({item.name for item in slice_path.iterdir()} == {FRAMEWORK}, "unexpected XCFramework slice contents")
        framework_plist(slice_path / FRAMEWORK)
        binary_digests[name] = directory_digest(slice_path / FRAMEWORK)
    require(input_digests == binary_digests, "packaged slice differs from the generated framework")
    plist.write_bytes(plistlib.dumps(canonical, sort_keys=True))


def mobile_tools(go, toolchain, root, env, bridge):
    names = ("gomobile", "gobind")
    private_bin = root / "tools"
    private_bin.mkdir(mode=0o700)
    module_root = root / "tool-module"
    module_root.mkdir(mode=0o700)
    modules = mobile_modules(toolchain, bridge)
    required = "\n".join(f"  {module} {info['Version']}" for module, info in modules.items())
    (module_root / "go.mod").write_text(f"module aegis.browser/ios/embeddedcore-tools\n\ngo {toolchain['go']}\n\n"
                                      f"require (\n{required}\n)\n")
    shutil.copyfile(bridge / "go.sum", module_root / "go.sum")
    host_arch = go_version(go, toolchain, env=env).rsplit("/", 1)[1]
    tools_env = dict(env, GOBIN=str(private_bin), GOOS="darwin", GOARCH=host_arch)
    # Download exact modules against the reviewed checksums, then verify the
    # shared cache's extracted source before compiling in the private module.
    for info in modules.values():
        actual = json.loads(capture([go, "mod", "download", "-json", f"{info['Path']}@{info['Version']}"],
                                    cwd=module_root, env=tools_env, timeout=90))
        require(all(actual.get(key) == value for key, value in info.items()),
                "binding tool source differs from the approved module checksums")
    run([go, "mod", "verify"], cwd=module_root, env=tools_env, timeout=90)
    run([go, "install", "-mod=readonly", *(f"golang.org/x/mobile/cmd/{name}" for name in names)],
        cwd=module_root, env=tools_env, timeout=180)
    binaries = [plain(private_bin / name) for name in names]
    for name, path in zip(names, binaries):
        require(os.access(path, os.X_OK), f"{name} is not executable")
        check_mobile_tool(go, path, name, toolchain, modules, host_arch, env=tools_env)
    return binaries


def publish(root, output, digest):
    output.mkdir(parents=True, exist_ok=True)
    plain(output, directory=True)
    for name in (XCFRAMEWORK, "work"):
        target = output / name
        if os.path.lexists(target):
            plain_tree(target)
    for name in ("build-manifest.json", "compiled-bridge.sha256", "slice-digests.txt",
                 "embedded-core-lock.json", "build-inputs.xcfilelist"):
        target = output / name
        if os.path.lexists(target):
            plain(target).unlink()
    for name in (XCFRAMEWORK, "work"):
        target = output / name
        if target.is_dir():
            shutil.rmtree(target)
    (output / "work").mkdir(mode=0o700)
    shutil.copytree(root / "bridge", output / "work/bridge")
    shutil.copytree(root / XCFRAMEWORK, output / XCFRAMEWORK)
    (output / "compiled-bridge.sha256").write_text(digest + "\n")


def build(repo, lock, output, record_for):
    source = json.loads(lock.read_bytes())
    xray = source["xrayCore"]
    require(all(xray.get(key) for key in ("commit", "tag", "tree", "repository"))
            and re.fullmatch(r"[0-9a-f]{40}", xray["commit"]) and source["status"] in ("verified_build", "source_candidate"),
            "invalid EmbeddedCore source lock")
    toolchain = source["toolchain"]
    require(toolchain["iosVersion"] == "15.0", "unexpected EmbeddedCore deployment target")
    mode = os.environ.get("AEGIS_EMBEDDED_CORE_DIGEST_MODE", "strict")
    require(mode in {"strict", "ci-rebuild"}, "unexpected EmbeddedCore digest mode")
    if record_for:
        require(source["status"] == "verified_build", "source lock must be verified_build")
    source_bridge = repo / "apps/ios/EmbeddedCore/bridge"
    plain_tree(source_bridge)
    require(not (source_bridge / "vendor").exists(), "vendored bridge overrides are unsupported")
    require(not output.is_relative_to(source_bridge) and not source_bridge.is_relative_to(output),
            "EmbeddedCore output overlaps the bridge source")
    environment = apple_build_environment(os.environ)
    apple = apple_metadata(environment)
    if record_for and mode == "strict":
        verify_apple_pin(apple, toolchain)
    go = selected_go(toolchain["go"], repo, environment)
    env = binding_environment(go, environment)
    packager = shutil.which("xcodebuild", path=env["PATH"])
    require(bool(packager), "xcodebuild is missing")
    scratch_parent = Path(tempfile.gettempdir()).resolve(strict=True)
    if scratch := env.get("IOS_CI_SCRATCH"):
        require(scratch_parent == Path(scratch) / "tmp", "build temp is outside job scratch")
        require(output == Path(env["IOS_CI_ROOT"]) / "EmbeddedCore", "build output is outside the admitted job")
    with tempfile.TemporaryDirectory(prefix="aegis-core-", dir=scratch_parent) as tmp:
        root = Path(tmp)
        go_temp = root / "go-tmp"
        go_temp.mkdir(mode=0o700)
        env["GOTMPDIR"] = str(go_temp)
        bridge = root / "bridge"
        shutil.copytree(source_bridge, bridge)
        module = module_file(go, bridge, env)
        require(module["Module"]["Path"] == BRIDGE_MODULE and not module.get("Replace"),
                "unexpected EmbeddedCore source module or replacement")
        run([go, "mod", "tidy"], cwd=bridge, env=env)
        plain_tree(bridge)
        digest = directory_digest(bridge)
        require(digest == directory_digest(source_bridge) and any(
            xray["commit"][:12] in (bridge / file).read_text() for file in ("go.mod", "go.sum")),
            "bridge differs from the measured source or Xray pin")
        gomobile, gobind = mobile_tools(go, toolchain, root, env, bridge)
        wrappers = root / "bin"
        wrappers.mkdir()
        for name in ("go", "xcodebuild"):
            (wrappers / name).symlink_to(Path(__file__).resolve())
        tool_aliases = root / "selected-tools"
        tool_aliases.mkdir()
        for name, executable in (("gomobile", gomobile), ("gobind", gobind)):
            (tool_aliases / name).symlink_to(Path(executable).resolve(strict=True))
        temporary = root / "tmp"
        temporary.mkdir(mode=0o700)
        bound_env = dict(env, TMPDIR=str(temporary), PATH=f"{wrappers}:{tool_aliases}:{env['PATH']}",
                         CLANG_MODULE_CACHE_PATH=str(root / "clang-module-cache"),
                         AEGIS_BIND_ROOT=str(root), AEGIS_BIND_GO=str(go), AEGIS_BIND_GOFLAGS=env["GOFLAGS"],
                         AEGIS_BIND_XCODEBUILD=str(Path(packager).absolute()))
        print("building AegisEmbeddedCore.xcframework (ios + iossimulator)...", flush=True)
        run([tool_aliases / "gomobile", "bind", "-target", "ios,iossimulator", "-iosversion", "15.0",
             "-trimpath", "-ldflags", "-buildid=", "-o", root / XCFRAMEWORK, "."], cwd=bridge, env=bound_env)
        plain_tree(bridge)
        require(directory_digest(bridge) == digest, "EmbeddedCore build copy changed during gomobile bind")
        normalize_xcframework(root / XCFRAMEWORK)
        require(apple_metadata(env) == apple, "Apple compiler or SDK changed during binding")
        publish(root, output, digest)
        result = capture([repo / "scripts/release/record-ios-access-core-digests.sh", "--xcframework", output / XCFRAMEWORK])
        (output / "slice-digests.txt").write_text(result)
        print(result, end="")
        if record_for:
            manifest = record(repo, lock, output, mode, *record_for, apple=apple, go=go, tools=(gomobile, gobind), env=env)
            print(json.dumps(manifest, sort_keys=True))


def main():
    invoked = Path(sys.argv[0]).name
    if invoked in {"go", "xcodebuild"}:
        root = plain(Path(os.environ["AEGIS_BIND_ROOT"]), directory=True)
        require(root.stat().st_uid == os.getuid() and stat.S_IMODE(root.stat().st_mode) == 0o700,
                "gomobile build scratch is not private")
        if invoked == "go":
            go_wrapper(root, sys.argv[1:])
        else:
            package_wrapper(root, sys.argv[1:])
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--record-for", type=Path, nargs=2)
    args = parser.parse_args()
    output = Path(os.path.abspath(args.output))
    require(output.parent.resolve() == output.parent and not output.is_symlink(), "non-canonical EmbeddedCore output")
    build(Path(__file__).resolve().parents[2], args.lock, output, args.record_for)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode if error.returncode >= 0 else 128 - error.returncode)
    except subprocess.TimeoutExpired:
        sys.exit("EmbeddedCore private binding tool operation timed out")
    except (KeyError, OSError, TypeError, ValueError) as error:
        sys.exit(str(error))

"""Bind the bundled AccessKit image to Xcode's actual linker input and output."""
import hashlib
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

from ios_embedded_core import file_digest


ACCESS = "AccessKit.framework/AccessKit"
CORE = "AegisEmbeddedCore.framework/AegisEmbeddedCore"


def output(*command):
    return subprocess.check_output(command, text=True)


def thin(binary, arch, destination):
    # Both the static archive and the linked dylib can have a fat wrapper,
    # including a single-architecture wrapper for iphoneos.
    with binary.open("rb") as stream:
        if stream.read(4) not in (bytes.fromhex("cafebabe"), bytes.fromhex("cafebabf")):
            return binary
    subprocess.run(["lipo", binary, "-thin", arch, "-output", destination], check=True)
    return destination


def sections(binary):
    layout = output("otool", "-l", binary)
    measured = {}
    with binary.open("rb") as stream:
        for section in layout.split("\nSection\n")[1:]:
            fields = dict(re.findall(r"^\s*(sectname|segname|size|offset|flags)\s+(\S+)", section.split("Load command")[0], re.M))
            # Zero-fill sections have no bytes in the file. The linker can strip
            # debugging/symbol information in __LINKEDIT before embedding a dylib.
            if not int(fields["offset"]) or fields["segname"].startswith("__DWARF"):
                continue
            size = int(fields["size"], 16)
            stream.seek(int(fields["offset"]))
            data = stream.read(size)
            if len(data) != size:
                raise ValueError("truncated Mach-O section")
            measured[(fields["segname"], fields["sectname"])] = hashlib.sha256(data).hexdigest()
    return measured


def linked_paths(derived, platform, arch):
    config = "Debug-iphonesimulator" if platform == "simulator" else "*-iphoneos"
    # K has a fresh DerivedData and the unsigned archive has a dedicated CI root.
    records = list(derived.glob(f"**/{config}/AccessKit.build/Objects-normal/{arch}/AccessKit_dependency_info.dat"))
    if len(records) != 1:
        raise ValueError("expected a single AccessKit linker dependency record")
    entries = records[0].read_bytes().split(b"\0")
    def unique_path(tag, suffix):
        paths = {Path(os.fsdecode(row[1:])) for row in entries if row[:1] == tag and row.endswith(suffix.encode())}
        if len(paths) != 1:
            raise ValueError("linker did not record the expected " + suffix)
        return paths.pop()
    return unique_path(b"\x10", "/" + CORE), unique_path(b"\x40", "/AccessKit")


def loads(binary, arch, install_name):
    rows = output("otool", "-arch", arch, "-L", binary).splitlines()[1:]
    return any(row.strip().split(" (", 1)[0] == install_name for row in rows)


def verify_link(bundle, products, derived, platform):
    if platform not in ("simulator", "device"):
        raise ValueError("a target platform is required for core verification")
    carrier = bundle / "Frameworks" / ACCESS
    if not carrier.is_file():
        raise FileNotFoundError("missing bundled AccessKit executable")
    framework = products / "AegisEmbeddedCore.xcframework"
    libraries = plistlib.loads((framework / "Info.plist").read_bytes())["AvailableLibraries"]
    library, = [lib for lib in libraries if lib["SupportedPlatform"] == "ios"
                and lib.get("SupportedPlatformVariant") == ("simulator" if platform == "simulator" else None)]
    selected = framework / library["LibraryIdentifier"] / CORE
    app = bundle / "Aegis"
    architectures = output("lipo", "-archs", app).split()
    if not architectures or set(architectures) != set(output("lipo", "-archs", carrier).split()):
        raise ValueError("app and bundled AccessKit architectures differ")
    receipt = {}
    for arch in architectures:
        loader = app
        if loads(app, arch, "@rpath/Aegis.debug.dylib"):
            loader = bundle / "Aegis.debug.dylib"
        if not loads(loader, arch, "@rpath/" + ACCESS):
            raise ValueError("app does not load the bundled AccessKit image")
        linked_input, linked_output = linked_paths(derived, platform, arch)
        uuid_pattern = rf"UUID: ([0-9A-Fa-f-]+) \({re.escape(arch)}\)"
        image_uuid = re.search(uuid_pattern, output("dwarfdump", "--uuid", carrier))
        linked_uuid = re.search(uuid_pattern, output("dwarfdump", "--uuid", linked_output))
        if not image_uuid or not linked_uuid or image_uuid[1] != linked_uuid[1]:
            raise ValueError("bundled AccessKit UUID differs from the linker output")
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            source = thin(selected, arch, tmp / "selected.a")
            input_hash = file_digest(source)
            if file_digest(thin(linked_input, arch, tmp / "linked.a")) != input_hash:
                raise ValueError("actual linker input differs from the selected EmbeddedCore slice")
            symbols = {line.split()[-1] for line in output("nm", "-arch", arch, "-gU", carrier).splitlines() if line.strip()}
            if not {"_proxyembeddedcore__Start", "_proxyembeddedcore__Dial"}.issubset(symbols):
                raise ValueError("bundled AccessKit lacks the core bridge exports")
            packaged = sections(thin(carrier, arch, tmp / "packaged"))
            if packaged != sections(thin(linked_output, arch, tmp / "linked")):
                raise ValueError("bundled AccessKit sections differ from the linker output")
            # The Go PC/line table is relocation-free in the static go.o and
            # survives linking and stripping byte for byte. Check the actual
            # payload as well as the linker's record that it opened this archive.
            obj = tmp / "go.o"
            with obj.open("wb") as stream:
                subprocess.run(["ar", "-p", source, "go.o"], stdout=stream, check=True)
            pc_table = ("__TEXT", "__gopclntab")
            if packaged[pc_table] != sections(obj)[pc_table]:
                raise ValueError("bundled Go code table differs from the selected slice")
        receipt[arch] = {"coreCarrierUUID": image_uuid[1], "appLoader": loader.name, "appLoaderSha256": file_digest(loader),
                         "linkedStaticArchiveSha256": input_hash, "goPclntabSha256": packaged[pc_table],
                         "linkedTextSha256": packaged[("__TEXT", "__text")]}
    return {"coreCarrier": "Frameworks/" + ACCESS, "coreCarrierSha256": file_digest(carrier),
            "selectedLibrary": library["LibraryIdentifier"], "linkedArchitectures": receipt}

"""Generate and read password-dialog .pak resources using Chromium's real GRIT."""

import argparse
import copy
import io
from pathlib import Path
import sys
import xml.etree.ElementTree as ET


MESSAGES = (
    "IDS_PASSWORD_MANAGER_IMPORT_DIALOG_TITLE",
    "IDS_PASSWORD_MANAGER_EXPORT_DIALOG_TITLE",
)
EXPECTED = {
    "en": ("Import Passwords To Aegis Browser", "Export Passwords From Aegis Browser"),
    "zh-CN": ("将密码导入 Aegis Browser", "从 Aegis Browser 导出密码"),
    "zh-HK": ("匯入密碼至 Aegis Browser", "從 Aegis Browser 匯出密碼"),
    "zh-TW": ("將密碼匯入 Aegis Browser", "從 Aegis Browser 匯出密碼"),
}


def main():
    """Exercise message IDs, XTB lookup, fallback and binary resource decoding."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("src", type=Path, help="Patched Chromium source directory")
    parser.add_argument("output", type=Path, help="Directory for generated test packs")
    args = parser.parse_args()
    sys.path.insert(0, str(args.src / "tools/grit"))
    from grit import grd_reader
    from grit.format import data_pack

    app = args.src / "chrome/app"
    source = ET.parse(app / "chromium_strings.grd").getroot()
    # Retain the actual production messages and translation paths. Isolating
    # these desktop dialogs avoids unrelated feature flags and resource IDs.
    fixture = ET.Element("grit", {
        "base_dir": ".", "latest_public_release": "0",
        "current_release": "1", "source_lang_id": "en",
    })
    outputs = ET.SubElement(fixture, "outputs")
    translations = ET.SubElement(fixture, "translations")
    for lang in EXPECTED:
        ET.SubElement(outputs, "output", {
            "filename": f"passwords_{lang}.pak", "type": "data_package", "lang": lang,
        })
    for translation in source.findall("translations/file"):
        if translation.get("lang") in EXPECTED:
            translations.append(copy.deepcopy(translation))
    production_messages = source.find("release/messages")
    if production_messages is None:
        raise AssertionError("Missing production messages section")
    messages = ET.SubElement(
        ET.SubElement(fixture, "release", {"seq": "1"}),
        "messages", dict(production_messages.attrib),
    )
    for name in MESSAGES:
        matches = [node for node in source.iter("message") if node.get("name") == name]
        if len(matches) != 1:
            raise AssertionError(f"Expected one production definition for {name}")
        messages.append(copy.deepcopy(matches[0]))
    document = ET.tostring(fixture, encoding="unicode")
    args.output.mkdir(parents=True, exist_ok=True)
    for lang, expected in EXPECTED.items():
        root = grd_reader.Parse(io.StringIO(document), dir=str(app))
        root.SetOutputLanguage(lang)
        root.RunGatherers()
        root.InitializeIds()
        pack = args.output / f"passwords_{lang}.pak"
        pack.write_bytes(data_pack.Format(root, lang))
        resources = data_pack.ReadDataPack(pack).resources
        for name, text in zip(MESSAGES, expected, strict=True):
            actual = resources[root.GetIdMap()[name]].decode("utf-8")
            if actual != text:
                raise AssertionError(f"{lang} {name}: {actual!r} != {text!r}")
    print("PASS: 8 password import/export strings in GRIT-generated language packs")


if __name__ == "__main__":
    main()

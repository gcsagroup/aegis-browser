"""Read password-dialog and native menu resources using Chromium's real GRIT.

Install the pinned dependency from grit-test-requirements.txt before running.
"""

import argparse
import copy
import io
from pathlib import Path
import sys

import defusedxml.ElementTree as ET


MESSAGES = (
    "IDS_PASSWORD_MANAGER_IMPORT_DIALOG_TITLE",
    "IDS_PASSWORD_MANAGER_EXPORT_DIALOG_TITLE",
    "IDS_AEGIS_SETTINGS_MENU",
)
EXPECTED = {
    "en": (
        "Import Passwords To Aegis Browser",
        "Export Passwords From Aegis Browser",
        "Aegis Browser",
    ),
    "zh-CN": ("将密码导入 Aegis Browser", "从 Aegis Browser 导出密码", "Aegis Browser"),
    "zh-HK": ("匯入密碼至 Aegis Browser", "從 Aegis Browser 匯出密碼", "Aegis Browser"),
    "zh-TW": ("將密碼匯入 Aegis Browser", "從 Aegis Browser 匯出密碼", "Aegis Browser"),
}


def parse_source(source):
    """Reject DTDs, entity expansion and external references in source XML."""
    return ET.parse(
        source, forbid_dtd=True, forbid_entities=True, forbid_external=True,
    ).getroot()


def append_element(parent, tag, attributes=None):
    child = parent.makeelement(tag, attributes or {})
    parent.append(child)
    return child


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
    source = parse_source(app / "chromium_strings.grd")
    settings = parse_source(app / "settings_strings.grdp")
    # Retain production messages and translation paths. Isolating these desktop
    # labels avoids unrelated feature flags and resource IDs. The native menu
    # uses the product's untranslated proper name from settings_strings.grdp.
    fixture = source.makeelement("grit", {
        "base_dir": ".", "latest_public_release": "0",
        "current_release": "1", "source_lang_id": "en",
    })
    outputs = append_element(fixture, "outputs")
    translations = append_element(fixture, "translations")
    for lang in EXPECTED:
        append_element(outputs, "output", {
            "filename": f"passwords_{lang}.pak", "type": "data_package", "lang": lang,
        })
    for translation in source.findall("translations/file"):
        if translation.get("lang") in EXPECTED:
            translations.append(copy.deepcopy(translation))
    production_messages = source.find("release/messages")
    if production_messages is None:
        raise AssertionError("Missing production messages section")
    messages = append_element(
        append_element(fixture, "release", {"seq": "1"}),
        "messages", dict(production_messages.attrib),
    )
    for name in MESSAGES:
        matches = [node for document in (source, settings)
                   for node in document.iter("message") if node.get("name") == name]
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
    print("PASS: 12 password import/export and native menu strings in GRIT-generated language packs")


if __name__ == "__main__":
    main()

"""Preserve Aegis UMA values shipped before the Chromium 158 rebase."""

from functools import lru_cache
from pathlib import Path
import re
import unittest

BROWSER = Path(__file__).resolve().parents[1]
CPP = "chrome/browser/renderer_context_menu/render_view_context_menu.cc"
XML = "tools/metrics/histograms/metadata/ui/enums.xml"
COMMAND = "IDC_CONTENT_CONTEXT_SEND_TO_AEGIS_AGENT"
OPTION = "Send page context to Aegis Agent"
GENERAL = "RenderViewContextMenuItem"
SPECIFIC = "ContextMenuOptionDesktop"
HUNK = re.compile(r"^@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
END = re.compile(rf"LINT\.ThenChange\([^)]*:({GENERAL}|{SPECIFIC})\)")


def apply_hunk(lines, header, source):
    """Apply the hunk at its new-side position, after prior hunks in this file."""
    old_count, start, new_count = (int(n or 1) for n in header.groups())
    index = start - 1 if new_count else start
    old, new = [], []
    while len(old) < old_count or len(new) < new_count:
        line = next(lines)
        if line.startswith("\\ No newline"):
            continue
        if line[:1] not in {" ", "-", "+"}:
            raise ValueError(f"Unexpected unified diff line {line!r}")
        if line[0] != "+":
            old.append(line[1:])
        if line[0] != "-":
            new.append(line[1:])
    # Untouched vendor lines need no checkout. Known lines must match the
    # preimage, including context received from earlier patches.
    source.extend([None] * max(0, index + old_count - len(source)))
    for known, expected in zip(source[index:index + old_count], old):
        if known is not None and known != expected:
            raise ValueError(f"Unexpected hunk preimage at {start}: {known!r}")
    source[index:index + old_count] = new


@lru_cache(maxsize=2)
def patched_sources(patch_dir):
    sources = {CPP: [], XML: []}
    for name in (patch_dir / "series").read_text().splitlines():
        name = name.strip()
        if not name or name.startswith("#"):
            continue
        with (patch_dir / name).open() as patch:
            target = None
            for line in patch:
                if line.startswith("diff --git "):
                    target = line.rstrip().rsplit(" b/", 1)[-1]
                elif target in sources and (header := HUNK.match(line)):
                    apply_hunk(patch, header, sources[target])
    return sources


def enum_entries(lines, pattern):
    """Group rows by the named LINT boundary that ends their native table."""
    entries = {GENERAL: [], SPECIFIC: []}
    enum = None
    for line in reversed(lines):
        if line is None:
            continue
        if match := END.search(line):
            enum = match[1]
        elif match := pattern.fullmatch(line.strip()):
            if enum is None:
                raise ValueError(f"Missing enum boundary for {line.strip()}")
            entries[enum].append(int(match[1]))
    return entries


class ContextMenuUmaCompatibilityTests(unittest.TestCase):
    def test_metadata_preserves_each_enum_and_matches_cpp(self):
        cpp_row = re.compile(rf"\{{{COMMAND},\s*(\d+)\}},")
        for platform in ("patches", "patches-android"):
            with self.subTest(platform=platform):
                sources = patched_sources(BROWSER / platform)
                cpp = enum_entries(sources[CPP], cpp_row)
                self.assertEqual(cpp, {GENERAL: [170], SPECIFIC: [35]})
                for enum, label in ((GENERAL, COMMAND), (SPECIFIC, OPTION)):
                    xml_row = re.compile(rf'<int value="(\d+)" label="{label}"/>')
                    xml = enum_entries(sources[XML], xml_row)
                    self.assertEqual(xml[enum], cpp[enum])
                    self.assertEqual(sum(map(len, xml.values())), 1)


if __name__ == "__main__":
    unittest.main()

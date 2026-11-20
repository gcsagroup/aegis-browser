"""Preserve Aegis UMA values shipped before the Chromium 158 rebase."""

from collections import Counter
from functools import lru_cache
from pathlib import Path
import re
import unittest

BROWSER = Path(__file__).resolve().parents[1]
CPP = "chrome/browser/renderer_context_menu/render_view_context_menu.cc"
XML = "tools/metrics/histograms/metadata/ui/enums.xml"
COMMAND = "IDC_CONTENT_CONTEXT_SEND_TO_AEGIS_AGENT"
OPTION = "Send page context to Aegis Agent"


@lru_cache(maxsize=2)
def aegis_mappings(patch_dir):
    """Track only Aegis entries, which are absent from the vendor base.

    Count additions minus removals over the active series so subsequent
    renumbering cannot hide behind an earlier patch with the correct value.
    Context lines do not change the final mapping.
    """
    cpp = Counter()
    xml = {COMMAND: Counter(), OPTION: Counter()}
    for name in (patch_dir / "series").read_text().splitlines():
        name = name.strip()
        if not name or name.startswith("#"):
            continue
        target = None
        in_hunk = False
        for line in (patch_dir / name).read_text().splitlines():
            if line.startswith("diff --git "):
                target = line.rsplit(" b/", 1)[-1]
                in_hunk = False
            elif line.startswith("@@ "):
                in_hunk = True
            elif in_hunk and line[:1] in {"+", "-"}:
                sign = 1 if line[0] == "+" else -1
                if target == CPP:
                    match = re.fullmatch(
                        rf"\s*\{{{COMMAND},\s*(\d+)\}},\s*", line[1:])
                    if match:
                        cpp[int(match[1])] += sign
                elif target == XML:
                    match = re.fullmatch(
                        r'\s*<int value="(\d+)" label="([^"]+)"/>\s*',
                        line[1:])
                    if match and match[2] in xml:
                        xml[match[2]][int(match[1])] += sign
    return cpp, xml


class ContextMenuUmaCompatibilityTests(unittest.TestCase):
    # These persisted IDs come from the pre-upgrade Aegis mainline. They
    # identify historical logs and must not be reassigned on vendor rebases.
    def test_cpp_preserves_persisted_aegis_values(self):
        for platform in ("patches", "patches-android"):
            with self.subTest(platform=platform):
                cpp, _ = aegis_mappings(BROWSER / platform)
                self.assertEqual(cpp, Counter({170: 1, 35: 1}))

    def test_metadata_preserves_each_enum_and_matches_cpp(self):
        for platform in ("patches", "patches-android"):
            with self.subTest(platform=platform):
                cpp, xml = aegis_mappings(BROWSER / platform)
                self.assertEqual(xml[COMMAND], Counter({170: 1}))
                self.assertEqual(xml[OPTION], Counter({35: 1}))
                self.assertEqual(cpp, xml[COMMAND] + xml[OPTION])


if __name__ == "__main__":
    unittest.main()

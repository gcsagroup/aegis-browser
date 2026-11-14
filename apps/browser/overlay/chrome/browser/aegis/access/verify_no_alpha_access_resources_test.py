from pathlib import Path
import tempfile
import unittest

from verify_no_alpha_access_resources import verify


class NormalResourceBoundaryTest(unittest.TestCase):
    def test_clean_normal_output_is_accepted(self):
        with tempfile.TemporaryDirectory() as folder:
            verify(Path(folder))

    def test_stale_alpha_assets_are_rejected_and_preserved(self):
        for relative in ("AegisAlphaAccess",
                "Browser.framework/Resources/AegisAlphaAccess",
                "Browser.app/Contents/Frameworks/Browser.framework/Resources/AegisAlphaAccess"):
            with self.subTest(relative=relative), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                assets = root / relative
                assets.mkdir(parents=True)
                fixture = assets / "node.json"
                fixture.write_text("private fixture")
                with self.assertRaises(ValueError):
                    verify(root)
                self.assertEqual(fixture.read_text(), "private fixture")


if __name__ == "__main__":
    unittest.main()

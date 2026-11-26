import copy
import json
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("verify-geosite-release.py")
VERIFIER = runpy.run_path(str(SCRIPT))
SOURCE = VERIFIER["SOURCE"]


class IOSGeoSiteReleaseVerificationTests(unittest.TestCase):
    def setUp(self):
        self.metadata = json.loads((SOURCE / "geosite-release.json").read_text())

    def test_accepts_current_official_input(self):
        self.assertEqual(VERIFIER["verify"](self.metadata, self.metadata, SOURCE), self.metadata["tag_name"])

    def test_rejects_unusable_release_metadata_even_when_asset_bytes_match(self):
        for field in ("draft", "browser_download_url"):
            with self.subTest(field=field):
                invalid = copy.deepcopy(self.metadata)
                if field == "draft":
                    invalid["draft"] = True
                else:
                    del invalid["assets"][0][field]
                with self.assertRaises(ValueError):
                    VERIFIER["verify"](invalid, self.metadata, SOURCE)

    @unittest.skipUnless(sys.platform == "darwin", "Swift Apple SDK required")
    def test_package_verifier_admits_the_app_resources_and_rejects_missing_dat(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "Aegis.app"
            shutil.copytree(SOURCE, app)
            policy = app / "Frameworks/AegisPolicyKit.framework"
            policy.mkdir(parents=True)
            psl = SOURCE.parents[1] / "AegisPolicyKit/Resources/public_suffix_list.dat"
            shutil.copyfile(psl, policy / psl.name)
            command = [sys.executable, "-B", str(SCRIPT), "--app", str(app)]
            admitted = subprocess.run(command, capture_output=True, text=True, timeout=180)
            self.assertEqual(admitted.returncode, 0, admitted.stderr)
            self.assertIn(self.metadata["tag_name"], admitted.stdout)
            (app / "geosite.dat").unlink()
            rejected = subprocess.run(command, capture_output=True, text=True, timeout=180)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("geosite.dat", rejected.stderr)


if __name__ == "__main__":
    unittest.main()

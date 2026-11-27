import copy
from datetime import datetime, timedelta
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

    def trailing(self, days):
        moment = datetime.strptime(self.metadata["published_at"], "%Y-%m-%dT%H:%M:%SZ") + timedelta(days=days)
        release = copy.deepcopy(self.metadata)
        release["tag_name"] = moment.strftime("%Y%m%d%H%M%S")
        release["published_at"] = moment.strftime("%Y-%m-%dT%H:%M:%SZ")
        return release

    def run_package_check(self, official, latest):
        with tempfile.TemporaryDirectory() as temporary:
            arguments = []
            for flag, release in (("--official", official), ("--latest", latest)):
                if release is not None:
                    path = Path(temporary) / (flag.strip("-") + ".json")
                    path.write_text(json.dumps(release))
                    arguments += [flag, str(path)]
            return subprocess.run([sys.executable, "-B", str(SCRIPT), *arguments],
                                  capture_output=True, text=True, timeout=60)

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

    def test_rejects_a_bundle_that_differs_from_its_tagged_official_release(self):
        for field in ("release id", "asset id", "digest"):
            with self.subTest(field=field):
                official = copy.deepcopy(self.metadata)
                if field == "release id":
                    official["id"] += 1
                elif field == "asset id":
                    official["assets"][0]["id"] += 1
                else:
                    official["assets"][0]["digest"] = "sha256:" + "0" * 64
                with self.assertRaises(ValueError):
                    VERIFIER["verify"](self.metadata, official, SOURCE)

    def test_bounds_how_far_the_bundle_trails_the_official_latest(self):
        check = VERIFIER["check_freshness"]
        self.assertEqual(check(self.metadata, self.metadata), timedelta(0))
        self.assertEqual(check(self.metadata, self.trailing(1)), timedelta(days=1))
        self.assertEqual(check(self.metadata, self.trailing(14)), timedelta(days=14))
        draft = self.trailing(1)
        draft["draft"] = True
        malformed = self.trailing(1)
        malformed["tag_name"] = "latest"
        for name, latest in (("stale", self.trailing(14.01)), ("older latest", self.trailing(-1)),
                             ("draft", draft), ("malformed tag", malformed)):
            with self.subTest(latest=name), self.assertRaises(ValueError):
                check(self.metadata, latest)

    def test_package_check_reads_the_tagged_and_latest_responses(self):
        current = self.run_package_check(self.metadata, self.metadata)
        self.assertEqual(current.returncode, 0, current.stderr)
        self.assertNotIn("::warning::", current.stdout)
        trailing = self.run_package_check(self.metadata, self.trailing(2))
        self.assertEqual(trailing.returncode, 0, trailing.stderr)
        self.assertIn("::warning::", trailing.stdout)
        stale = self.run_package_check(self.metadata, self.trailing(15))
        self.assertNotEqual(stale.returncode, 0)
        self.assertIn("14 days", stale.stderr)
        self.assertEqual(self.run_package_check(self.metadata, None).returncode, 2)

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

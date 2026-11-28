import copy
from datetime import timedelta
import hashlib
import json
import os
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("ios-refresh-geosite.py")
REFRESH = runpy.run_path(str(SCRIPT))["refresh"]
MODULE = REFRESH.__globals__


class IOSGeoSiteRefreshTests(unittest.TestCase):
    def setUp(self):
        work = tempfile.TemporaryDirectory()
        self.addCleanup(work.cleanup)
        self.root = Path(work.name)
        self.originals = {path: (MODULE["ROOT"] / path).read_bytes() for path in MODULE["PATHS"]}
        for path, data in self.originals.items():
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        self.current = json.loads(self.originals[MODULE["METADATA"]])
        self.release = copy.deepcopy(self.current)
        old_tag = self.current["tag_name"]
        tag = (MODULE["tag_time"](old_tag) + timedelta(days=1)).strftime("%Y%m%d%H%M%S")
        published = MODULE["VERIFIER"]["published"](self.current) + timedelta(days=1)
        self.release.update(tag_name=tag, published_at=published.strftime("%Y-%m-%dT%H:%M:%SZ"),
                            html_url=self.current["html_url"].replace(old_tag, tag))
        self.downloads = {}
        for asset in self.release["assets"]:
            asset["browser_download_url"] = asset["browser_download_url"].replace(old_tag, tag)
            name = MODULE["VERIFIER"]["NAMES"][asset["name"]]
            self.downloads[asset["browser_download_url"]] = self.originals[MODULE["SOURCE"] / name]

    def download(self, url, limit, destination):
        data = self.downloads[url]
        destination.write_bytes(data)
        return data

    def run_refresh(self, validate_rules=None):
        with patch.dict(MODULE, ROOT=self.root, command=lambda *_: b"", api=lambda _: self.release,
                        download=self.download, provenance=lambda *_: ("a" * 40, "b" * 40),
                        validate_rules=validate_rules or MODULE["validate_rules"]):
            REFRESH(self.release["tag_name"], dry_run=False)

    def assert_originals(self):
        self.assertEqual({path: (self.root / path).read_bytes() for path in self.originals}, self.originals)

    def test_checksum_pair_must_match_the_dat_even_with_valid_asset_digests(self):
        checksum = next(asset for asset in self.release["assets"] if asset["name"].endswith(".sha256sum"))
        mismatched = b"0" * 64 + b"  geosite.dat\n"
        checksum["size"] = len(mismatched)
        checksum["digest"] = "sha256:" + hashlib.sha256(mismatched).hexdigest()
        self.downloads[checksum["browser_download_url"]] = mismatched
        with self.assertRaisesRegex(ValueError, "checksum does not match"):
            self.run_refresh()
        self.assert_originals()

    def test_compiler_rejection_leaves_all_refresh_files_intact(self):
        def reject(work, compiler):
            self.assertIn(self.release["tag_name"], compiler)
            self.assertEqual((work / "geosite.dat").read_bytes(),
                             self.originals[MODULE["SOURCE"] / "geosite.dat"])
            raise ValueError("DEBIAN rules changed and require scope review")

        with self.assertRaisesRegex(ValueError, "DEBIAN rules changed"):
            self.run_refresh(reject)
        self.assert_originals()

    def test_source_replacements_fail_if_expected_pins_are_missing(self):
        originals = dict(self.originals)
        compiler = MODULE["COMPILER"]
        originals[compiler] = originals[compiler].replace(self.current["tag_name"].encode(), b"")
        with self.assertRaisesRegex(ValueError, "occurrences"):
            MODULE["update_pins"](originals, self.current, self.release, "a" * 40, "b" * 40)

    def test_publish_restores_files_if_a_later_replacement_fails(self):
        replace = os.replace
        updates = {MODULE["METADATA"]: b"new metadata", MODULE["CATALOGUE"]: b"new catalogue"}

        def fail_catalogue(source, target):
            if target == self.root / MODULE["CATALOGUE"]:
                raise OSError("Cannot replace catalogue")
            replace(source, target)

        with patch.dict(MODULE, ROOT=self.root), patch.object(os, "replace", side_effect=fail_catalogue):
            with self.assertRaisesRegex(OSError, "Cannot replace catalogue"):
                MODULE["publish"](self.originals, updates)
        self.assert_originals()

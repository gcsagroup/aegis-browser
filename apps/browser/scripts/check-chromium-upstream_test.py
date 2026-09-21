"""上游监测的错误分类、Early Stable 排除和通知去重回归。"""
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlparse

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("upstream", Path(__file__).with_name("check-chromium-upstream.py"))
upstream = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upstream)


def entry(title, text, labels=("Stable updates",)):
    return {"title": {"$t": title}, "content": {"$t": text},
            "category": [{"term": x} for x in labels],
            "published": {"$t": "2026-09-08T14:24:50-07:00"},
            "link": [{"rel": "alternate", "href": "https://chromereleases.googleblog.com/example"}]}


class UpstreamTests(unittest.TestCase):
    def test_cloud_checkout_without_local_source_or_app(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            browser = root / "apps/browser"
            browser.mkdir(parents=True)
            (browser / "CHROMIUM_VERSION").write_text("153.0.8010.37")
            (browser / "CHROMIUM_COMMIT").write_text("a" * 40)
            with patch.dict(upstream.os.environ, {}, clear=True), patch.object(
                    Path, "home", return_value=root / "home"):
                identity = upstream.local_identity(root)
            self.assertEqual(identity["pinnedVersion"], "153.0.8010.37")
            self.assertIsNone(identity["sourcePath"])
            self.assertEqual(identity["artifacts"], [])

    def test_version_order_is_numeric(self):
        self.assertGreater(upstream.version_key("153.0.8010.100"), upstream.version_key("153.0.8010.37"))

    def test_pair_versions(self):
        self.assertEqual(upstream.versions("153.0.8010.36/.37 Windows/Mac"), {"153.0.8010.36", "153.0.8010.37"})

    def test_early_stable_is_excluded_even_with_stable_label(self):
        posts = upstream.announcements({"feed": {"entry": [
            entry("Stable Channel Update for Desktop", "Chrome 153.0.8010.36/.37 Security Fixes. Google is aware that an exploit for CVE-2026-87491 exists in the wild."),
            entry("Stable Channel Update for Desktop", "Chrome 154.0.8037.17 for a small percentage of users")
        ]}})
        self.assertEqual(len(posts), 1)
        self.assertEqual(posts[0]["exploited"], ["CVE-2026-87491"])
        releases = [{"platform": "Mac", "channel": "Stable", "version": v,
                     "hashes": {"chromium": "a" * 40}} for v in ("154.0.8037.17", "153.0.8010.37")]
        history = {"versions": [{"version": x["version"]} for x in releases]}
        self.assertEqual(upstream.select_candidate("Mac", releases, history, posts)["version"], "153.0.8010.37")

    def test_source_disagreement_stops_selection(self):
        posts = [{"platforms": ["Mac"], "versions": ["153.0.8010.37", "152.0.7977.83"]}]
        releases = [{"platform": "Mac", "channel": "Stable", "version": "152.0.7977.83", "hashes": {"chromium": "a" * 40}}]
        with self.assertRaisesRegex(ValueError, "尚未对齐"):
            upstream.select_candidate("Mac", releases, {"versions": [{"version": "152.0.7977.83"}]}, posts)

    def test_android_does_not_import_desktop_reference(self):
        posts = upstream.announcements({"feed": {"entry": [entry(
            "Chrome for Android Update", "We've released Chrome 153 (153.0.8010.36) for Android. Android releases contain the same fixes as Desktop (Windows & Mac: 153.0.8010.36/.37).") ]}})
        self.assertEqual(posts[0]["versions"], ["153.0.8010.36"])

    def test_empty_announcement_is_failure(self):
        with self.assertRaises(ValueError):
            upstream.announcements({"feed": {"entry": []}})

    def test_failure_preserves_success_and_deduplicates(self):
        report = {"errors": [{"source": "Mac", "message": "timeout"}], "local": {}, "candidates": {}, "unresolvedExploited": []}
        first, state = upstream.notice(report, {"lastSuccess": 99}, 100000)
        self.assertTrue(first["notify"])
        self.assertEqual(state["lastSuccess"], 99)
        second, _ = upstream.notice(report, state, 103600)
        self.assertFalse(second["notify"])

    def test_daily_pending_change_is_not_lost(self):
        report = {"errors": [], "local": {}, "candidates": {"Mac": {"version": "153.0.8010.37"}}, "unresolvedExploited": []}
        first, state = upstream.notice(report, {"lastNormalNotice": 100000}, 101000)
        self.assertFalse(first["notify"])
        second, _ = upstream.notice(report, state, 190000)
        self.assertTrue(second["notify"])

    def test_exploited_update_is_immediate(self):
        report = {"errors": [], "local": {}, "candidates": {}, "unresolvedExploited": [{"cves": ["CVE-2026-87491"]}]}
        decision, _ = upstream.notice(report, {"lastNormalNotice": 100000}, 100001)
        self.assertTrue(decision["notify"])

    def fixture_fetch(self, url):
        if "feeds/posts" in url:
            return {"feed": {"entry": [entry("Stable Channel Update for Desktop",
                "Chrome 153.0.8010.36/.37 Security Fixes. Google is aware that an exploit for CVE-2026-87491 exists in the wild."),
                entry("Chrome for Android Update", "Chrome 153.0.8010.36 for Android.")]}}
        if "chromiumdash" in url:
            platform = parse_qs(urlparse(url).query)["platform"][0]
            version = "153.0.8010.36" if platform == "Android" else "153.0.8010.37"
            return [{"platform": platform, "channel": "Stable", "version": version,
                     "hashes": {"chromium": "a" * 40}}]
        if "versionhistory" in url:
            return {"versions": [{"version": v} for v in ("153.0.8010.36", "153.0.8010.37")]}
        return {"commit": "a" * 40}

    def test_live_flow_failure_keeps_last_success_and_open_cve(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(
                upstream, "local_identity", return_value={"pinnedVersion": "151.0.7922.77", "artifacts": []}):
            out = Path(directory)
            with patch.object(upstream, "fetch_json", side_effect=self.fixture_fetch):
                first = upstream.check(out, out)
            self.assertEqual(first["status"], "checked")
            success = (out / "last-success.json").read_bytes()
            def failed_fetch(url):
                if "feeds/posts" in url:
                    raise RuntimeError("公告服务不可用")
                return self.fixture_fetch(url)
            with patch.object(upstream, "fetch_json", side_effect=failed_fetch):
                failed = upstream.check(out, out)
            self.assertEqual(failed["status"], "incomplete")
            self.assertEqual(failed["unresolvedExploited"], first["unresolvedExploited"])
            self.assertEqual((out / "last-success.json").read_bytes(), success)

    def test_old_installed_artifact_prevents_cve_clearance(self):
        identity = {"pinnedVersion": "153.0.8010.37", "artifacts": [
            {"version": "151.0.7922.77", "chromiumVersion": "151.0.7922.77"}]}
        with tempfile.TemporaryDirectory() as directory, patch.object(
                upstream, "local_identity", return_value=identity), patch.object(
                upstream, "fetch_json", side_effect=self.fixture_fetch):
            report = upstream.check(Path(directory), Path(directory))
            self.assertFalse(report["candidates"]["Mac"]["behind"])
            self.assertTrue(report["unresolvedExploited"])

    def test_tag_mismatch_never_produces_candidate(self):
        def wrong_tag(url):
            if "googlesource" in url:
                return {"commit": "b" * 40}
            return self.fixture_fetch(url)
        with tempfile.TemporaryDirectory() as directory, patch.object(
                upstream, "local_identity", return_value={"pinnedVersion": "151.0.7922.77", "artifacts": []}), patch.object(
                upstream, "fetch_json", side_effect=wrong_tag):
            report = upstream.check(Path(directory), Path(directory))
            self.assertEqual(report["status"], "incomplete")
            self.assertEqual(report["candidates"], {})

    def test_shared_tag_is_fetched_once_per_check(self):
        calls = []
        def fetch(url):
            if "googlesource" in url:
                calls.append(url)
            return self.fixture_fetch(url)
        with tempfile.TemporaryDirectory() as directory, patch.object(
                upstream, "local_identity", return_value={"pinnedVersion": "151.0.7922.77", "artifacts": []}), patch.object(
                upstream, "fetch_json", side_effect=fetch):
            for _ in range(2):
                report = upstream.check(Path(directory), Path(directory))
                self.assertEqual(report["status"], "checked")
            self.assertEqual(len(calls), 4)  # 每轮桌面一次、Android 一次，不跨轮复用。

    def test_cached_tag_still_checks_each_platform_commit(self):
        with patch.object(upstream, "fetch_json", return_value={"commit": "a" * 40}) as fetch:
            cache = {}
            upstream.verified_tag("153.0.8010.37", "a" * 40, cache)
            with self.assertRaisesRegex(ValueError, "提交不一致"):
                upstream.verified_tag("153.0.8010.37", "b" * 40, cache)
            self.assertEqual(fetch.call_count, 1)

    def test_tag_transport_fallback_preserves_actual_source_and_error(self):
        with patch.object(upstream, "fetch_json", side_effect=[RuntimeError("HTTP 503"), {"commit": "a" * 40}]) as fetch:
            evidence = upstream.verified_tag("153.0.8010.37", "a" * 40, {})
            self.assertIn("/+/153.0.8010.37?", evidence["url"])
            self.assertIn("HTTP 503", evidence["failedAttempts"][0]["message"])
            self.assertEqual(fetch.call_count, 2)
        with patch.object(upstream, "fetch_json", side_effect=[RuntimeError("HTTP 503"), {"commit": "b" * 40}]):
            with self.assertRaisesRegex(ValueError, "提交不一致"):
                upstream.verified_tag("153.0.8010.37", "a" * 40, {})

    def test_bad_tag_content_does_not_trigger_fallback(self):
        for response in [{"commit": "b" * 40}, ValueError("JSON损坏")]:
            with patch.object(upstream, "fetch_json", side_effect=[response]) as fetch:
                with self.assertRaises(ValueError):
                    upstream.verified_tag("153.0.8010.37", "a" * 40, {})
                self.assertEqual(fetch.call_count, 1)

    def test_both_tag_paths_failing_preserves_last_success(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(
                upstream, "local_identity", return_value={"pinnedVersion": "151.0.7922.77", "artifacts": []}):
            out = Path(directory)
            with patch.object(upstream, "fetch_json", side_effect=self.fixture_fetch):
                upstream.check(out, out)
            success = (out / "last-success.json").read_bytes()
            def unavailable(url):
                if "googlesource" in url:
                    raise RuntimeError("HTTP 503")
                return self.fixture_fetch(url)
            with patch.object(upstream, "fetch_json", side_effect=unavailable):
                report = upstream.check(out, out)
            self.assertEqual(report["status"], "incomplete")
            self.assertEqual(report["candidates"], {})
            self.assertEqual((out / "last-success.json").read_bytes(), success)
            self.assertTrue(all("官方备用路径失败" in x["message"] for x in report["errors"]))

    def test_identity_failure_keeps_existing_exploited_notice(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(
                upstream, "fetch_json", side_effect=self.fixture_fetch):
            out = Path(directory)
            with patch.object(upstream, "local_identity", return_value={
                    "pinnedVersion": "151.0.7922.77", "artifacts": []}):
                first = upstream.check(out, out)
            with patch.object(upstream, "local_identity", side_effect=OSError("本地版本不可读")):
                failed = upstream.check(out, out)
            self.assertEqual(failed["status"], "incomplete")
            self.assertEqual(failed["unresolvedExploited"], first["unresolvedExploited"])

    def test_unknown_artifact_version_cannot_clear_existing_notice(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(
                upstream, "fetch_json", side_effect=self.fixture_fetch):
            out = Path(directory)
            with patch.object(upstream, "local_identity", return_value={
                    "pinnedVersion": "151.0.7922.77", "artifacts": []}):
                first = upstream.check(out, out)
            with patch.object(upstream, "local_identity", return_value={
                    "pinnedVersion": "153.0.8010.37", "artifacts": [
                        {"path": "/example/Aegis.app", "version": "Ver 2.0", "chromiumVersion": None}]}):
                unknown = upstream.check(out, out)
            self.assertEqual(unknown["status"], "incomplete")
            self.assertEqual(unknown["unresolvedExploited"], first["unresolvedExploited"])


if __name__ == "__main__":
    unittest.main()

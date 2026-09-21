#!/usr/bin/env python3
"""只读核对 Chromium 正式 Stable；仅向指定证据目录写入结果。"""
import argparse
import concurrent.futures
import datetime as dt
import fcntl
import hashlib
import html
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import urllib.parse

ROOT = Path(__file__).resolve().parents[3]
PLATFORMS = {"Mac": "mac_arm64", "Windows": "win64", "Android": "android"}
VERSION = re.compile(r"\b(\d+\.\d+\.\d+\.\d+)(?:/\.(\d+))?")
FEED = "https://chromereleases.googleblog.com/feeds/posts/default"


def version_key(value):
    if not re.fullmatch(r"\d+\.\d+\.\d+\.\d+", value):
        raise ValueError("版本格式无效")
    return tuple(map(int, value.split(".")))


def versions(text):
    found = set()
    for match in VERSION.finditer(text):
        found.add(match[1])
        if match[2]:
            found.add(match[1].rsplit(".", 1)[0] + "." + match[2])
    return found


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def fetch_json(url):
    # curl 使用本机正常 TLS 配置；失败不关闭证书校验，不冒充无更新。
    result = subprocess.run(
        ["curl", "--fail", "--silent", "--show-error", "--location",
         "--proto", "=https", "--proto-redir", "=https", "--max-time", "40",
         "--max-filesize", "8388608", "--retry", "1", "--retry-all-errors", url],
        capture_output=True, timeout=90, check=False)
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors="replace")[-600:])
    return json.loads(result.stdout.decode().removeprefix(")]}'\n"))


def verified_tag(version, commit, cache):
    # 缓存仅存活于本轮检查；平台仍各自核对公告、版本历史及提交。
    if version not in cache:
        version_key(version)
        primary = f"https://chromium.googlesource.com/chromium/src/+/refs/tags/{version}?format=JSON"
        url = primary
        failures = []
        try:
            tag = fetch_json(url)
        except (RuntimeError, subprocess.TimeoutExpired) as exc:
            failures.append({"url": url, "message": str(exc)})
            url = f"https://chromium.googlesource.com/chromium/src/+/{version}?format=JSON"
            try:
                tag = fetch_json(url)
            except Exception as fallback_error:
                raise RuntimeError(f"标签主路径失败：{exc}；官方备用路径失败：{fallback_error}") from fallback_error
        # 内容损坏或提交不符不使用备用结果掩盖，也不缓存失败。
        if tag["commit"] != commit:
            raise ValueError("官方 tag 与 ChromiumDash 提交不一致")
        cache[version] = (tag, {"url": url, "sha256": digest(tag),
                                "failedAttempts": failures})
    tag, evidence = cache[version]
    if tag["commit"] != commit:
        raise ValueError("官方 tag 与 ChromiumDash 提交不一致")
    return evidence


def announcements(feed):
    result = []
    for entry in feed.get("feed", {}).get("entry", []):
        title = entry["title"]["$t"]
        labels = [x["term"] for x in entry.get("category", [])]
        text = html.unescape(re.sub(r"<[^>]+>", " ", entry["content"]["$t"]))
        text = re.sub(r"\s+", " ", text).strip()
        if "Early Stable Updates" in labels or re.search(
                r"early stable|small percentage", text[:1200], re.I):
            continue
        if title == "Stable Channel Update for Desktop" and "Stable updates" in labels:
            platforms = ["Mac", "Windows"]
        elif title == "Chrome for Android Update" and "Stable updates" in labels:
            platforms = ["Android"]
            # Android 公告随后会引用桌面版 .36/.37，不能把 .37 当作 Android 发布。
            text = text.split("Android releases contain")[0]
        else:
            continue
        # 只从公告开头提取发布版本，避免把漏洞说明中的旧版本当候选。
        release_versions = versions(text.split("Security Fixes")[0][:1200])
        exploited = set()
        for sentence in re.split(r"(?<=[.!])\s+", text):
            if re.search(r"exploit.*(?:in the wild|wild)", sentence, re.I):
                exploited.update(re.findall(r"CVE-\d{4}-\d+", sentence))
        result.append({"published": entry["published"]["$t"], "platforms": platforms,
                       "url": next(x["href"] for x in entry["link"] if x["rel"] == "alternate"),
                       "versions": sorted(release_versions, key=version_key),
                       "exploited": sorted(exploited),
                       "cves": sorted(set(re.findall(r"CVE-\d{4}-\d+", text)))})
    if not result:
        raise ValueError("公告源没有可识别的正式 Stable，禁止报告为无更新")
    return result


def select_candidate(platform, releases, history, posts):
    allowed = {v for p in posts if platform in p["platforms"] for v in p["versions"]}
    known = {x["version"] for x in history.get("versions", [])}
    if not known:
        raise ValueError(f"{platform} VersionHistory 返回空版本")
    matches = [x for x in releases if x.get("platform") == platform
               and x.get("channel") == "Stable" and x["version"] in allowed & known]
    if not matches:
        raise ValueError(f"{platform} 公告、ChromiumDash、VersionHistory 无共同正式版本")
    # 公告中更新的平台版本尚未出现在 API 时要显式报告，不静默降级到旧版。
    wanted = max(allowed, key=version_key)
    chosen = max(matches, key=lambda x: version_key(x["version"]))
    if version_key(chosen["version"]) < version_key(wanted):
        raise ValueError(f"{platform} 官方源尚未对齐：公告 {wanted}，API {chosen['version']}")
    commit = chosen.get("hashes", {}).get("chromium", "")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError(f"{platform} 缺少可信 Chromium 提交")
    return {"version": chosen["version"], "commit": commit}


def local_identity(root):
    browser = root / "apps/browser"
    pinned = (browser / "CHROMIUM_VERSION").read_text().strip()
    version_key(pinned)
    marker = browser / ".chromium-root"
    source_root = os.environ.get("CHROMIUM_ROOT") or (
        marker.read_text().strip() if marker.exists() else None)
    source = Path(source_root) / "src" if source_root else None
    result = {"pinnedVersion": pinned,
              "pinnedCommit": (browser / "CHROMIUM_COMMIT").read_text().strip(),
              "sourcePath": str(source) if source else None, "artifacts": []}
    candidates = [Path.home() / "Applications/GCSA Aegis Test.app"]
    if source:
        candidates.insert(0, source / "out/AegisRelease/GCSA Aegis.app")
    for app in candidates:
        info = app / "Contents/Info.plist"
        if info.exists():
            data = plistlib.loads(info.read_bytes())
            result["artifacts"].append({"path": str(app),
                "version": data.get("CFBundleShortVersionString"),
                "chromiumVersion": data.get("CFBundleShortVersionString") if re.fullmatch(
                    r"\d+\.\d+\.\d+\.\d+", data.get("CFBundleShortVersionString", "")) else None,
                "build": data.get("CFBundleVersion"),
                "evidence": "包元数据，未确认当前进程或补丁覆盖"})
    return result


def notice(report, state, now):
    signature = digest({k: report.get(k, []) for k in (
        "errors", "local", "candidates", "unresolvedExploited", "securityUpdates")})
    changed = signature != state.get("observedSignature")
    last = state.get("lastNormalNotice", 0)
    urgent = bool(report["errors"] or report["unresolvedExploited"])
    pending = signature != state.get("notifiedSignature")
    notify = pending and (urgent or now - last >= 86400)
    next_state = dict(state, observedSignature=signature, lastAttempt=now)
    if not report["errors"]:
        next_state["lastSuccess"] = now
    if notify:
        next_state["notifiedSignature"] = signature
        if not urgent:
            next_state["lastNormalNotice"] = now
    return {"notify": notify, "changed": changed,
            "priority": "urgent" if urgent else "daily"}, next_state


def atomic_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(path)


def check(root, out):
    now = dt.datetime.now(dt.timezone.utc)
    report = {"checkedAt": now.isoformat(), "errors": [], "candidates": {},
              "unresolvedExploited": [], "securityUpdates": [], "local": {}, "sources": {}}
    try:
        report["local"] = local_identity(root)
    except Exception as exc:
        report["errors"].append({"source": "local", "message": str(exc)})
    start = (now - dt.timedelta(days=45)).date().isoformat() + "T00:00:00Z"
    urls = {"announcements": FEED + "?" + urllib.parse.urlencode(
        {"alt": "json", "max-results": 150, "published-min": start})}
    for platform, api in PLATFORMS.items():
        urls[platform + "Dash"] = "https://chromiumdash.appspot.com/fetch_releases?" + urllib.parse.urlencode(
            {"channel": "Stable", "platform": platform, "num": 40})
        urls[platform + "History"] = f"https://versionhistory.googleapis.com/v1/chrome/platforms/{api}/channels/stable/versions?pageSize=50"
    payloads = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        futures = {executor.submit(fetch_json, url): (key, url) for key, url in urls.items()}
        for future in concurrent.futures.as_completed(futures):
            key, url = futures[future]
            try:
                payloads[key] = future.result()
                report["sources"][key] = {"url": url, "sha256": digest(payloads[key])}
            except Exception as exc:
                report["errors"].append({"source": key, "message": str(exc)})
    posts = []
    try:
        feed = payloads["announcements"]
        # 固定回查窗口必须完整；截断时失败，不悄悄漏掉公告。
        if any(x.get("rel") == "next" for x in feed["feed"].get("link", [])):
            raise ValueError("45 天公告超出单页上限，需要分页复核")
        posts = announcements(feed)
    except Exception as exc:
        report["errors"].append({"source": "announcementParsing", "message": str(exc)})
    tag_cache = {}
    for platform in PLATFORMS:
        try:
            candidate = select_candidate(platform, payloads[platform + "Dash"],
                                         payloads[platform + "History"], posts)
            evidence = verified_tag(candidate["version"], candidate["commit"], tag_cache)
            candidate["tagUrl"] = evidence["url"]
            candidate["behind"] = version_key(report["local"]["pinnedVersion"]) < version_key(candidate["version"])
            report["candidates"][platform] = candidate
            report["sources"][platform + "Tag"] = evidence
        except Exception as exc:
            report["errors"].append({"source": platform, "message": str(exc)})
    unknown_artifacts = [x["path"] for x in report["local"].get("artifacts", [])
                         if not x.get("chromiumVersion")]
    if unknown_artifacts:
        report["errors"].append({"source": "localArtifacts",
            "message": "无法确认包的 Chromium 版本：" + ", ".join(unknown_artifacts)})
    local_versions = [report["local"].get("pinnedVersion")] + [
        x.get("chromiumVersion") for x in report["local"].get("artifacts", [])]
    baseline = min((v for v in local_versions if v), key=version_key, default=None)
    previous_path = out / "latest.json"
    previous = json.loads(previous_path.read_text()) if previous_path.exists() else {}
    identity_complete = baseline is not None and not unknown_artifacts
    if baseline:
        # 版本落后只说明需核验，不能当作精确受影响判定或回补证明。
        for post in posts:
            if post["cves"] and post["versions"] and version_key(baseline) < version_key(max(post["versions"], key=version_key)):
                report["securityUpdates"].append(post)
            if post["exploited"] and post["versions"] and version_key(baseline) < version_key(max(post["versions"], key=version_key)):
                report["unresolvedExploited"].append({"cves": post["exploited"], "url": post["url"],
                    "fixedVersions": post["versions"], "published": post["published"],
                    "status": "基线早于修复公告，需核验源码回补与实际产物"})
    # 本地身份读取失败或包版本未知时，不能因为缺少比较值清除已有漏洞。
    known_urls = {x["url"] for x in report["unresolvedExploited"]}
    for item in previous.get("unresolvedExploited", []):
        if item["url"] not in known_urls and (not identity_complete or
                version_key(baseline) < version_key(max(item["fixedVersions"], key=version_key))):
            report["unresolvedExploited"].append(item)
    report["errors"].sort(key=lambda x: (x["source"], x["message"]))
    report["unresolvedExploited"].sort(key=lambda x: x["url"])
    report["securityUpdates"].sort(key=lambda x: x["url"])
    state_path = out / "state.json"
    state = json.loads(state_path.read_text()) if state_path.exists() else {}
    report["notification"], state = notice(report, state, now.timestamp())
    report["status"] = "incomplete" if report["errors"] else "checked"
    atomic_json(out / "latest.json", report)
    if not report["errors"]:
        atomic_json(out / "last-success.json", report)
    if report["notification"]["changed"]:
        runs = out / "runs"
        runs.mkdir(exist_ok=True)
        atomic_json(runs / (now.strftime("%Y%m%dT%H%M%SZ") + ".json"), report)
        evidence = out / "sources"
        evidence.mkdir(exist_ok=True)
        for payload in payloads.values():
            path = evidence / (digest(payload) + ".json")
            if not path.exists():
                atomic_json(path, payload)
    atomic_json(state_path, state)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    out = args.output or args.root / ".artifacts/chromium-upstream/monitor"
    out.mkdir(parents=True, exist_ok=True)
    with (out / "check.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(json.dumps({"status": "already-running", "notification": {"notify": False}}))
            return 0
        report = check(args.root, out)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 2 if report["errors"] else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Validate paired checkpoints and write a per-leg failure list and diagnosis."""
from collections import Counter
import csv
import ipaddress
import json
import math
from pathlib import Path
from statistics import median
from urllib.parse import urlsplit

import sys

base = Path(sys.argv[1]).resolve(strict=True)
fixture = Path(__file__).resolve().parents[2] / "Tests/Fixtures/blocked-cn-rerun.json"


def read(filename):
    path = base / filename
    return json.loads(path.read_text()) if path.exists() else []


def usable(row):
    return 200 <= (row.get("status") or 0) < 300 and not row["errors"] and not row["stoppedDowngrade"]


def route(row):
    transactions = row["transactions"]
    if not transactions:
        return "缺少 transaction metrics"
    if row["phase"] == "proxy":
        return "代理已观测" if transactions[-1]["isProxy"] else "最终事务未观测到代理"
    return "直连观察一致" if not any(tx["isProxy"] for tx in transactions) else "直连观察到代理"


def fake_range(address):
    try:
        return ipaddress.ip_address(address) in ipaddress.ip_network("198.18.0.0/15")
    except ValueError:
        return False


def diagnosis(row):
    status = row.get("status")
    if row["stoppedDowngrade"]:
        return "阻止降级或非 HTTPS 重定向"
    if status == 403:
        return "HTTP 403"
    if status == 429:
        return "HTTP 429"
    if status is not None and status >= 400:
        return f"HTTP {status // 100}xx"
    if row["errors"]:
        error = row["errors"][0]
        code = error["code"]
        if error["domain"] == "NSURLErrorDomain":
            return {
                -1022: "ATS 限制",
                -1200: "TLS 连接失败",
                -1201: "TLS 证书时效",
                -1202: "TLS 证书不受信任",
                -1203: "TLS 未知根证书",
                -1204: "TLS 证书尚未生效",
                -1001: "超时",
                -1003: "主机解析失败",
                -1004: "连接失败",
                -1005: "连接中断",
                -1006: "DNS 查询失败",
                -1007: "重定向过多",
                -1009: "网络不可用",
            }.get(code, f"URLSession {code}")
        return f'{error["domain"]} {code}'
    if usable(row):
        expected = "代理已观测" if row["phase"] == "proxy" else "直连观察一致"
        if route(row) == expected:
            return "2xx"
        return "2xx，路径未核实"
    return "仅收到其他状态码" if status else "无 HTTP 状态码"


def had_response(row):
    return row.get("status") is not None or bool(row["redirects"]) or any(
        tx.get("status") is not None for tx in row["transactions"]
    )


def destination(row):
    return urlsplit(row.get("finalURL") or "").hostname or ""


def error_text(row):
    errors = row["errors"] + ([row["streamError"]] if "streamError" in row else [])
    return " | ".join(f'{e["domain"]}:{e["code"]}' for e in errors)


def compare(pairs):
    return Counter(
        ("代理有可归属的 2xx" if diagnosis(p["proxy"]) == "2xx" else "代理无可归属的 2xx",
         "直连有可归属的 2xx" if diagnosis(p["direct"]) == "2xx" else "直连无可归属的 2xx")
        for p in pairs
    )


def wilson(successes, n):
    z = 1.96
    p = successes / n
    center = p + z * z / (2 * n)
    radius = z * math.sqrt((p * (1 - p) + z * z / (4 * n)) / n)
    return ((center - radius) / (1 + z * z / n), (center + radius) / (1 + z * z / n))


def index(rows):
    found = {p["target"]["h"]: p for p in rows}
    if len(found) != len(rows):
        raise SystemExit("Duplicate paired target")
    for pair in rows:
        if pair["direct"]["phase"] != "direct" or pair["proxy"]["phase"] != "proxy":
            raise SystemExit("Invalid paired record")
    return found


def registered_apex(host, rules):
    # The corpus stores normalized ASCII hostnames. Mirror RegisteredDomain.of's PSL rule selection.
    labels = host.split(".")
    if all(label.isdecimal() for label in labels):
        return True
    suffix_length = 1
    for index in range(len(labels)):
        suffix = ".".join(labels[index:])
        remaining = len(labels) - index
        if "!" + suffix in rules:
            suffix_length = remaining - 1
            break
        if suffix in rules:
            suffix_length = max(suffix_length, remaining)
        if index and "*." + suffix in rules:
            suffix_length = max(suffix_length, remaining + 1)
    return len(labels) == suffix_length + 1


corpus = json.loads(fixture.read_text())
pairs = read("pairs.json")
www = read("www-pairs.json")
egress = read("egress.json")
canaries = read("canaries.json")
summary = read("run-summary.json")
manifest = {row["h"]: row for row in corpus["targets"]}
primary = index(pairs)
followup = index(www)
if any(pair["target"] != manifest.get(host) for host, pair in primary.items()):
    raise SystemExit("Paired target does not match the test fixture")
if set(primary) & set(followup):
    raise SystemExit("Supplemental hosts overlap the primary pairs")

failures = base / "paired-failures.csv"
with failures.open("w", newline="", encoding="utf-8-sig") as handle:
    writer = csv.writer(handle)
    writer.writerow(["组别", "分类", "主机", "请求路径", "先测路径", "失败路径", "现象", "最终状态码",
                     "最后响应主机", "用时毫秒", "另一条路径结果", "代理观察", "观测到的 fake-IP 网段",
                     "错误域与代码", "重定向链"])
    for pair in sorted(pairs + www, key=lambda p: (p["target"]["s"], p["target"]["h"])):
        t = pair["target"]
        for phase, other_phase in (("proxy", "direct"), ("direct", "proxy")):
            row, other = pair[phase], pair[other_phase]
            result = diagnosis(row)
            if result == "2xx":
                continue
            redirects = " | ".join(
                f'{r["status"]} {r.get("from", "")} → {r.get("to", "")}' for r in row["redirects"]
            )
            writer.writerow([t["s"], t["c"], t["h"], t.get("p", "/"), pair["first"], phase, result,
                             row.get("status"), destination(row), row["milliseconds"], diagnosis(other), route(row),
                             any(fake_range(tx.get("remoteAddress", "")) for tx in row["transactions"]),
                             error_text(row), redirects])

suffix_list = fixture.parents[2] / "AegisPolicyKit/Resources/public_suffix_list.dat"
rules = {line.strip().encode("idna").decode("ascii").lower() for line in suffix_list.read_text().splitlines()
         if line.strip() and not line.startswith("//")}
expected_www = {"www." + host for host, pair in primary.items()
                if pair["target"]["k"] == "domain" and registered_apex(host, rules)
                and "www." + host not in manifest and not (usable(pair["direct"]) and usable(pair["proxy"]))}
checkpoints = {"pairs.json": pairs, "www-pairs.json": www, "canaries.json": canaries, "egress.json": egress}
recovered = summary.get("recoveredCounts", {})
complete = (
    len(primary) == len(manifest)
    and all((base / name).is_file() and recovered.get(name) == len(rows) for name, rows in checkpoints.items())
    and set(followup) == expected_www
    and len(canaries) == 7
    and sum(diagnosis(row) == "2xx" for row in canaries) >= 4
    and all(
        any(row["phase"] == phase and row["round"] == round_id and row["status"] == 200
            and (row.get("country") == "CN" and row["proxyByTransaction"] == [False] if phase == "direct"
                 else row.get("country") and row["proxyObserved"])
            for row in egress
            if "status" in row
        )
        for phase in ("direct", "proxy") for round_id in range(1, 4 if www else 3)
    )
    and summary.get("xcodeExitCode") == 0
    and summary.get("passedTests") == 1
    and summary.get("failedTests") == summary.get("skippedTests") == 0
)
lines = [
    "# iOS 真机配对复测",
    "",
    f"复测状态为 **{'完成' if complete else '证据不完整'}**。主清单 {len(primary):,}/{len(manifest):,} 对。"
    f"额外 www 复测 {len(followup):,} 对。",
    "",
    "iPhone 真机，8 个并发配对，每个配对随机决定先测直连还是代理。"
    "两侧采用相同的 8 秒请求超时和 10 秒资源超时，读取 HTTPS 响应头，记录每跳和底层错误。"
    "浏览器页面、登录、播放和 API 响应正文待产品侧验证。",
    "",
    f"GeoSite 语料版本 `{corpus['tag']}`，SHA-256 `{corpus['sha256']}`。",
    "",
    "## 出口和预检",
    "",
    "| 边界 | 路径 | 国家 | HTTP | 观测到系统代理 |",
    "| --- | --- | --- | --- | --- |",
]
for row in egress:
    lines.append(f"| {row['round']} | {row['phase']} | {row.get('country', '缺失')} | {row.get('status', '缺失')} | {row['proxyObserved']} |")
lines += ["", "出口检查只覆盖检测站点与这些时间点。对端 IP 检查只标记观测到的 198.18.0.0/15。", ""]
lines.append(f"独立代理预检通过 {sum(diagnosis(row) == '2xx' for row in canaries)}/{len(canaries)}。")
if pairs:
    lines += ["", "## 主清单", "", "| 指标 | 代理 | 直连 |", "| --- | ---: | ---: |"]
    counts = {phase: Counter(diagnosis(p[phase]) for p in pairs) for phase in ("proxy", "direct")}
    for label, metric in (
        ("有 HTTP 状态码或记录到重定向", had_response),
        ("最终响应为 2xx", usable),
        ("2xx 且路径与预期一致", lambda row: diagnosis(row) == "2xx"),
        ("缺少 transaction metrics", lambda row: not row["transactions"]),
        ("观测到 198.18.0.0/15 对端", lambda row: any(fake_range(t.get("remoteAddress", "")) for t in row["transactions"])),
    ):
        values = [sum(metric(p[phase]) for p in pairs) for phase in ("proxy", "direct")]
        lines.append(f"| {label} | {values[0]:,} | {values[1]:,} |")
    lines += ["", "| 未通过项 | 代理 | 直连 |", "| --- | ---: | ---: |"]
    for label in sorted(set(counts["proxy"]) | set(counts["direct"])):
        if label != "2xx":
            lines.append(f"| {label} | {counts['proxy'][label]:,} | {counts['direct'][label]:,} |")
    lines += ["", "### 代理侧响应和 TLS 证据", ""]
    codes = Counter(p["proxy"].get("status") for p in pairs if (p["proxy"].get("status") or 0) >= 400)
    if codes:
        lines.append("- HTTP 错误状态码 " + "、".join(f"`{code}` × {n}" for code, n in codes.most_common()) + "。")
    tls_rows = [p["proxy"] for p in pairs if diagnosis(p["proxy"]) == "TLS 连接失败"]
    stream_errors = Counter((r["streamError"]["domain"], r["streamError"]["code"]) for r in tls_rows if r.get("streamError"))
    if tls_rows:
        last_proxy = sum(route(r) == "代理已观测" for r in tls_rows)
        any_proxy = sum(any(tx["isProxy"] for tx in r["transactions"]) for r in tls_rows)
        lines.append(f"- URLSession `-1200` 共 {len(tls_rows)} 个，其中 "
                     f"{last_proxy} 个在最后一个事务观测到代理，{any_proxy} 个至少有一跳观测到代理。")
    if stream_errors:
        ssl_labels = {
            -9816: "连接关闭且没有 TLS 关闭通知",
            -9802: "TLS fatal alert",
            -9838: "TLS 对端内部错误",
            -9824: "TLS 握手失败",
            -9843: "主机名不匹配",
        }
        lines += ["", "| CFStream 域和代码 | 含义 | 数量 |", "| --- | --- | ---: |"]
        for (domain, code), count in stream_errors.most_common(10):
            interpretation = ssl_labels.get(code, "记录原始代码") if domain == "3" else "记录原始代码"
            lines.append(f"| `{domain}:{code}` | {interpretation} | {count} |")
        lines += ["", "TLS 关闭与告警只能定位客户端观察到的阶段。目标站解析、节点拨号和证书故障需要逐例关联。"]
    downgrades = [r for p in pairs if (r := p["proxy"])["stoppedDowngrade"] and r["redirects"]]
    if downgrades:
        last_hops = [r["redirects"][-1] for r in downgrades]
        same_host = sum(urlsplit(h.get("from") or "").hostname == urlsplit(h.get("to") or "").hostname for h in last_hops)
        to_http = sum(urlsplit(h.get("to") or "").scheme == "http" for h in last_hops)
        lines += ["", f"- 捕获 {len(last_hops)} 个代理侧非 HTTPS 跳转，{to_http} 个目标使用 HTTP。"
                       f"{same_host} 个跳转到同一主机，{len(last_hops) - same_host} 个跨主机。"]
    lines += ["", "配对结果按两条路径分别核对：", ""]
    for (proxy_state, direct_state), count in sorted(compare(pairs).items()):
        lines.append(f"- {proxy_state}，{direct_state}：{count:,} 对")
    sample = [p for p in pairs if p["target"]["s"] == "accel-sample"]
    reproduced = sum(diagnosis(p["proxy"]) == "2xx" and not usable(p["direct"]) for p in sample)
    both = [p for p in pairs if diagnosis(p["proxy"]) == diagnosis(p["direct"]) == "2xx"]
    if sample:
        lo, hi = wilson(reproduced, len(sample))
        lines += ["", f"首轮候选随机样本复现 {reproduced}/{len(sample)}，95% Wilson 区间 {lo:.1%} 至 {hi:.1%}。"
                  "该比例对应首轮 2,084 个候选。"]
    if both:
        difference = median(p["direct"]["milliseconds"] - p["proxy"]["milliseconds"] for p in both)
        lines += ["", f"两侧均有可归属的 2xx 的 {len(both):,} 个样本，首响应头耗时配对差"
                  f"（直连减代理）中位数为 {difference:g} 毫秒。"]
    lines += ["", "## 按抽样组比较", "",
              "| 组别 | 配对 | 代理 2xx | 直连 2xx | 两侧 2xx | 仅代理 2xx | 两侧均未通过 |",
              "| --- | ---: | ---: | ---: | ---: | ---: | ---: |"]
    strata = {
        "proxy-fail": "首轮代理未通过",
        "accel-sample": "首轮仅代理通过的随机样本",
        "both-open-named": "首轮两侧通过的命名分类",
        "representative": "代表性子域",
        "github-resource": "GitHub 真实资源",
    }
    for key, label in strata.items():
        group = [p for p in pairs if p["target"]["s"] == key]
        booleans = [(diagnosis(p["proxy"]) == "2xx", diagnosis(p["direct"]) == "2xx") for p in group]
        combinations = Counter(booleans)
        both_ok = combinations[True, True]
        only_proxy = combinations[True, False]
        only_direct = combinations[False, True]
        neither = combinations[False, False]
        lines.append(f"| {label} | {len(group)} | {both_ok + only_proxy} | {both_ok + only_direct} | "
                     f"{both_ok} | {only_proxy} | {neither} |")
    lines += ["", "## GitHub 资源", "", "| URL | 代理 | 直连 |", "| --- | --- | --- |"]
    for p in sorted(pairs, key=lambda p: p["target"]["h"]):
        t = p["target"]
        if t["s"] == "github-resource":
            lines.append(f"| `{t['h']}{t['p']}` | {diagnosis(p['proxy'])} | {diagnosis(p['direct'])} |")
    failed_representatives = [
        p for p in pairs if p["target"]["s"] == "representative" and diagnosis(p["proxy"]) != "2xx"
    ]
    if failed_representatives:
        lines += ["", "## 代表性子域的代理失败", "",
                  "| 主机 | 代理侧观察 | 直连侧观察 |",
                  "| --- | --- | --- |"]
        for p in sorted(failed_representatives, key=lambda p: p["target"]["h"]):
            proxy, direct = p["proxy"], p["direct"]
            proxy_outcome = diagnosis(proxy)
            if proxy["stoppedDowngrade"] and proxy["redirects"]:
                hop = proxy["redirects"][-1]
                target = urlsplit(hop.get("to") or "")
                proxy_outcome = f'{hop["status"]} → `{target.scheme}://{target.netloc}`'
            elif proxy.get("status"):
                proxy_outcome = f'HTTP {proxy["status"]}'
            lines.append(f'| `{p["target"]["h"]}` | {proxy_outcome} | {diagnosis(direct)} |')
    lines += ["", "## 修复方案", ""]
    if counts["proxy"]["阻止降级或非 HTTPS 重定向"] or counts["proxy"]["ATS 限制"]:
        google = primary.get("www.google.com")
        if google and google["proxy"]["stoppedDowngrade"] and google["proxy"]["redirects"]:
            hop = google["proxy"]["redirects"][-1]
            target = urlsplit(hop.get("to") or "")
            lines.append(f"- **复现 Google 的跨主机跳转。** 用分发配置的 WKWebView 打开 "
                         f"`www.google.com`，复核探针记录的 HTTP {hop['status']} 到 "
                         f"`{target.scheme}://{target.netloc}`，并对目的地主机独立验证选路与用户确认。"
                         "同主机 HTTPS 升级只覆盖实际确认的同主机问题。")
        else:
            lines.append("- **复现网页重定向。** 用分发配置的 WKWebView 对照每跳，复核目标主机的选路和用户确认。")
    if tls_rows:
        lines.append("- **补齐 TLS 失败的路径证据。** 从失败清单挑选代表性站点，关联实际 HTTP 入口的"
                     "开流、CONNECT 回包和首次读写，再对照内核侧解析、拨号和远端关闭结果。"
                     "用受控的 DNS 不存在、拒绝连接、TLS 告警三类样本验证报错区分能力。")
    if any(label.startswith("HTTP ") and value for label, value in counts["proxy"].items()):
        lines.append("- **用产品实际请求验收 CDN 和 API。** 从 WKWebView 记录页面请求，"
                     "选取代表性图片、脚本及服务公开端点。GitHub 三条 200 资源可作为对照。"
                     "保留 403、429、5xx 的状态码，通过可控样本区分站点拒绝、限流和服务端故障。")
    if www:
        restored = sum(diagnosis(p["proxy"]) == "2xx" for p in www)
        apex_failed = sum(
            diagnosis(p["proxy"]) == "2xx"
            and diagnosis(primary[p["target"]["h"][4:]]["proxy"]) != "2xx"
            for p in www
        )
        lines.append(f"- **分别验收根域和 www。** www 补测有 {restored:,}/{len(www):,} 个得到有代理标记的 2xx，"
                     f"其中 {apex_failed:,} 个对应的根域在代理侧未通过。"
                     "产品验收以真实页面入口和关键资源为准。")
    lines.append("- **验证产品路由。** 分别用具体海外分类及“全部”模式确认主页面、重定向和关键资源的实际路径。"
                 "本轮结果对应这台真机、这条 Wi-Fi 链路和这个 Reality Vision 节点。")
lines += ["", "逐请求失败及路径未核实条目见同目录 `paired-failures.csv`。"]
(base / "paired-review.zh-CN.md").write_text("\n".join(lines) + "\n")
print(f"complete={complete} primary={len(primary)}/{len(manifest)} www={len(followup)}")
raise SystemExit(0 if complete else 1)

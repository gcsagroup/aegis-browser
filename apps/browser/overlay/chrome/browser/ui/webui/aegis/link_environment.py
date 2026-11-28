"""在 GN 构建时生成原生账号服务配置，网页和用户偏好都不能更改来源。"""
import argparse
import re
from pathlib import Path
from urllib.parse import urlsplit


def portal_origin(environment, address):
    """开发包使用回环地址，测试和生产包只接受显式配置的 HTTPS 服务域名。"""
    if environment not in ("development", "testing", "production"):
        raise ValueError("unsupported Aegis Link environment")
    if not address and environment == "development":
        address = "http://localhost:5176"
    site = urlsplit(address)
    if not re.fullmatch(r"https?://[a-zA-Z0-9.-]+(?::[0-9]+)?", address):
        raise ValueError("set aegis_link_portal to an HTTP(S) origin without a path or credentials")
    if not site.hostname or site.port == 0:
        raise ValueError("invalid portal host or port")
    if environment == "development":
        if site.hostname not in ("127.0.0.1", "localhost"):
            raise ValueError("development requires a loopback portal")
    else:
        # 只接受完整 DNS 名称，排除 Chromium 可解析为本地 IP 的缩写、十六进制或整数表示。
        labels = site.hostname.split(".")
        label = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
        if (site.scheme != "https" or len(labels) < 2 or
                not all(re.fullmatch(label, part) for part in labels) or
                not re.fullmatch(r"[a-z]{2,63}|xn--[a-z0-9-]+", labels[-1]) or
                labels[-1] == "localhost" or len(site.hostname) > 253):
            raise ValueError("testing and production require an explicit HTTPS domain")
    return address


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--environment", required=True)
    parser.add_argument("--portal", default="")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    origin = portal_origin(args.environment, args.portal)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        "// 由构建配置生成，浏览器运行时固定使用此来源。\n"
        f'#define AEGIS_LINK_PORTAL_ORIGIN "{origin}"\n', encoding="utf-8")

#!/usr/bin/env python3
"""Tiny PyPI-simple merge proxy: local wheels + pypi.org.

vpython uses pip --isolated with a single --index-url, so we must:
- serve local wheels (e.g. crcmod, which has no public binary)
- still expose ALL upstream versions (local-only index.html would hide them)
"""
from __future__ import annotations

import argparse
import os
import re
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PYPI = "https://pypi.org"


class Handler(BaseHTTPRequestHandler):
    wheelhouse: Path

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("[aegis-pypi] " + (fmt % args) + "\n")

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        # Direct local wheel / file
        local_file = self._local_file(path)
        if local_file is not None:
            self._send_file(local_file)
            return

        # /simple/<pkg>/ → merge local wheel links into upstream simple HTML
        m = re.match(r"^/simple/([^/]+)/?$", path)
        if m:
            self._send_merged_simple(m.group(1))
            return

        # Root /simple/ → local package list + note
        if path in {"/simple", "/simple/"}:
            self._send_bytes(self._root_simple_html(), "text/html; charset=utf-8")
            return

        self._proxy(path)

    def _local_file(self, path: str) -> Path | None:
        rel = path.lstrip("/")
        if not rel or rel.endswith("/"):
            return None
        # /simple/<pkg>/<file.whl>
        candidate = self.wheelhouse / rel
        if candidate.is_file():
            return candidate
        # also allow /<file.whl> at wheelhouse root
        candidate = self.wheelhouse / Path(rel).name
        if candidate.is_file() and candidate.suffix == ".whl":
            return candidate
        return None

    def _local_wheels(self, pkg: str) -> list[Path]:
        pkg = pkg.lower().replace("_", "-")
        # PEP 503 normalized names
        dirs = [
            self.wheelhouse / "simple" / pkg,
            self.wheelhouse / "simple" / pkg.replace("-", "_"),
        ]
        out: list[Path] = []
        for d in dirs:
            if d.is_dir():
                out.extend(sorted(d.glob("*.whl")))
        # wheelhouse root fallback
        for whl in self.wheelhouse.glob("*.whl"):
            name = whl.name.split("-", 1)[0].lower().replace("_", "-")
            if name == pkg:
                out.append(whl)
        # dedupe
        seen = set()
        uniq = []
        for w in out:
            if w.name not in seen:
                seen.add(w.name)
                uniq.append(w)
        return uniq

    def _send_merged_simple(self, pkg: str) -> None:
        local = self._local_wheels(pkg)
        # requirements 都是精确 pin；本地已有 wheel 时直接返回本地列表，
        # 避免每个包都等上游 simple 超时，把 vpython 安装拖到不可用。
        if local:
            links = "\n".join(
                f'<a href="/simple/{pkg}/{w.name}">{w.name}</a><br/>' for w in local
            )
            html = f"<!DOCTYPE html><html><body>\n{links}\n</body></html>\n"
            self._send_bytes(html.encode(), "text/html; charset=utf-8")
            return

        # 本地没有 wheel 才回源；仍优先用更小的 PyPI simple JSON。
        upstream = ""
        try:
            upstream = self._fetch_simple_html(pkg)
        except Exception as e:  # noqa: BLE001
            self.log_message("upstream miss %s: %s", pkg, e)

        if not upstream and not local:
            self.send_error(404, f"no such project: {pkg}")
            return

        if not upstream:
            links = "\n".join(
                f'<a href="/simple/{pkg}/{w.name}">{w.name}</a><br/>' for w in local
            )
            html = f"<!DOCTYPE html><html><body>\n{links}\n</body></html>\n"
            self._send_bytes(html.encode(), "text/html; charset=utf-8")
            return

        # Inject absolute local links near the top of <body>
        inject = "".join(
            f'<a href="/simple/{pkg}/{w.name}">{w.name}</a><br/>\n' for w in local
        )
        if inject:
            if "<body>" in upstream.lower():
                # case-insensitive body open
                html = re.sub(
                    r"(?i)<body[^>]*>",
                    lambda m: m.group(0) + "\n" + inject,
                    upstream,
                    count=1,
                )
            else:
                html = inject + upstream
        else:
            html = upstream
        self._send_bytes(html.encode() if isinstance(html, str) else html, "text/html; charset=utf-8")

    def _root_simple_html(self) -> bytes:
        pkgs = sorted(
            {
                p.name
                for p in (self.wheelhouse / "simple").iterdir()
                if p.is_dir()
            }
        ) if (self.wheelhouse / "simple").is_dir() else []
        links = "\n".join(f'<a href="{p}/">{p}</a><br/>' for p in pkgs)
        return (
            "<!DOCTYPE html><html><body>\n"
            "<!-- local packages; unknown names are proxied to pypi.org -->\n"
            f"{links}\n</body></html>\n"
        ).encode()

    def _fetch_simple_html(self, pkg: str) -> str:
        """Prefer compact JSON index; fall back to HTML. Timeout keeps pip <15s."""
        opener = self._opener()
        url = f"{PYPI}/simple/{pkg}/"
        headers = {
            "User-Agent": "gcsa-aegis-pypi-proxy",
            "Accept": "application/vnd.pypi.simple.v1+json, text/html;q=0.8",
        }
        req = urllib.request.Request(url, headers=headers)
        with opener.open(req, timeout=8) as resp:
            raw = resp.read()
            ctype = (resp.headers.get("Content-Type") or "").lower()
        text = raw.decode("utf-8", errors="replace")
        if "json" in ctype or text.lstrip().startswith("{"):
            import json

            data = json.loads(text)
            links = []
            for f in data.get("files") or []:
                name = f.get("filename") or ""
                href = f.get("url") or ""
                if name and href:
                    links.append(f'<a href="{href}">{name}</a>')
            return (
                "<!DOCTYPE html><html><body>\n"
                + "\n".join(links)
                + "\n</body></html>\n"
            )
        return text

    def _fetch_text(self, url: str) -> str:
        opener = self._opener()
        req = urllib.request.Request(url, headers={"User-Agent": "gcsa-aegis-pypi-proxy"})
        with opener.open(req, timeout=8) as resp:
            return resp.read().decode("utf-8", errors="replace")

    def _opener(self):
        proxy = (
            os.environ.get("https_proxy")
            or os.environ.get("HTTPS_PROXY")
            or os.environ.get("http_proxy")
            or os.environ.get("HTTP_PROXY")
        )
        if proxy:
            return urllib.request.build_opener(
                urllib.request.ProxyHandler({"http": proxy, "https": proxy})
            )
        return urllib.request.build_opener()

    def _proxy(self, path: str) -> None:
        url = PYPI + path
        try:
            opener = self._opener()
            req = urllib.request.Request(url, headers={"User-Agent": "gcsa-aegis-pypi-proxy"})
            with opener.open(req, timeout=90) as resp:
                data = resp.read()
                ctype = resp.headers.get("Content-Type", "application/octet-stream")
                self._send_bytes(data, ctype)
        except urllib.error.HTTPError as e:
            body = e.read()
            self.send_response(e.code)
            self.send_header("Content-Type", e.headers.get("Content-Type", "text/plain"))
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except Exception as e:  # noqa: BLE001
            msg = str(e).encode()
            self.send_response(502)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(msg)))
            self.end_headers()
            self.wfile.write(msg)

    def _send_file(self, path: Path) -> None:
        data = path.read_bytes()
        ctype = (
            "text/html; charset=utf-8"
            if path.suffix in {".html", ""}
            else "application/octet-stream"
        )
        self._send_bytes(data, ctype)

    def _send_bytes(self, data: bytes, ctype: str) -> None:
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--wheelhouse", required=True)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=4173)
    args = ap.parse_args()
    Handler.wheelhouse = Path(args.wheelhouse).resolve()
    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    print(
        f"aegis-pypi-proxy on http://{args.host}:{args.port}/simple/  "
        f"wheelhouse={Handler.wheelhouse}",
        flush=True,
    )
    httpd.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

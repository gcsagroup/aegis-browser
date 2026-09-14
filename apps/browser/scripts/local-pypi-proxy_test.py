#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import io
import socket
import tempfile
import threading
import unittest
import urllib.error
from http.server import ThreadingHTTPServer
from pathlib import Path
from typing import Any


SCRIPT = Path(__file__).with_name("local-pypi-proxy.py")
SPEC = importlib.util.spec_from_file_location("local_pypi_proxy", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
PROXY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROXY)


class FakeResponse:
    def __init__(
        self,
        body: bytes,
        content_type: str,
        content_length: str,
    ) -> None:
        self.body = body
        self.headers = {
            "Content-Type": content_type,
            "Content-Length": content_length,
        }
        self.status = 200

    def __enter__(self) -> FakeResponse:
        return self

    def __exit__(self, *args: Any) -> None:
        pass

    def read(self) -> bytes:
        return self.body


class FakeOpener:
    simple_json = (
        b'{"files":[{"filename":"upstream-1.0-py3-none-any.whl",'
        b'"url":"https://files.example/upstream-1.0-py3-none-any.whl"}]}'
    )
    wheel = b"upstream-wheel"

    def open(self, request: Any, timeout: int) -> FakeResponse:
        if request.full_url.endswith("/simple/upstream/"):
            return FakeResponse(
                self.simple_json,
                "application/vnd.pypi.simple.v1+json",
                "1234",
            )
        if request.full_url.endswith("/packages/upstream.whl"):
            return FakeResponse(
                self.wheel,
                "application/octet-stream",
                str(len(self.wheel)),
            )
        if request.full_url.endswith("/packages/missing.whl"):
            raise urllib.error.HTTPError(
                request.full_url,
                404,
                "missing",
                {"Content-Type": "text/plain"},
                io.BytesIO(b"not found"),
            )
        raise AssertionError(f"unexpected upstream URL: {request.full_url}")


class QuietHandler(PROXY.Handler):
    def log_message(self, fmt: str, *args) -> None:
        pass

    def _opener(self) -> Any:
        return FakeOpener()


class LocalHeadTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.wheelhouse = Path(self.temp_dir.name)
        package_dir = self.wheelhouse / "simple" / "demo-package"
        package_dir.mkdir(parents=True)
        self.wheel = package_dir / "demo_package-1.0-py3-none-any.whl"
        self.wheel.write_bytes(b"fixture-wheel")

        QuietHandler.wheelhouse = self.wheelhouse
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), QuietHandler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp_dir.cleanup()

    def request(
        self, method: str, path: str
    ) -> tuple[int, dict[str, str], bytes]:
        with socket.create_connection(self.server.server_address) as connection:
            connection.sendall(
                f"{method} {path} HTTP/1.0\r\nHost: localhost\r\n\r\n".encode()
            )
            chunks = []
            while chunk := connection.recv(65536):
                chunks.append(chunk)

        head, separator, body = b"".join(chunks).partition(b"\r\n\r\n")
        self.assertEqual(b"\r\n\r\n", separator)
        lines = head.decode("iso-8859-1").split("\r\n")
        status = int(lines[0].split(" ", 2)[1])
        headers = {
            name.lower(): value.strip()
            for name, value in (line.split(":", 1) for line in lines[1:])
        }
        return status, headers, body

    def assert_head_matches_get(self, path: str) -> bytes:
        get_status, get_headers, get_body = self.request("GET", path)
        head_status, head_headers, head_body = self.request("HEAD", path)
        self.assertEqual(200, get_status)
        self.assertEqual(get_status, head_status)
        self.assertEqual(get_headers["content-type"], head_headers["content-type"])
        self.assertEqual(len(get_body), int(get_headers["content-length"]))
        self.assertEqual(
            get_headers["content-length"], head_headers["content-length"]
        )
        self.assertEqual(b"", head_body)
        return get_body

    def test_head_matches_local_get_responses(self) -> None:
        root_body = self.assert_head_matches_get("/simple/")
        self.assertIn(b"demo-package/", root_body)

        package_body = self.assert_head_matches_get("/simple/demo-package/")
        self.assertIn(self.wheel.name.encode(), package_body)

        wheel_body = self.assert_head_matches_get(
            f"/simple/demo-package/{self.wheel.name}"
        )
        self.assertEqual(b"fixture-wheel", wheel_body)

    def test_head_matches_rewritten_upstream_index(self) -> None:
        body = self.assert_head_matches_get("/simple/upstream/")
        self.assertIn(b"upstream-1.0-py3-none-any.whl", body)
        self.assertNotEqual(1234, len(body))

    def test_head_matches_successful_upstream_proxy(self) -> None:
        body = self.assert_head_matches_get("/packages/upstream.whl")
        self.assertEqual(FakeOpener.wheel, body)

    def test_head_omits_unknown_upstream_error_length_and_body(self) -> None:
        get_status, get_headers, get_body = self.request(
            "GET", "/packages/missing.whl"
        )
        head_status, head_headers, head_body = self.request(
            "HEAD", "/packages/missing.whl"
        )

        self.assertEqual(404, get_status)
        self.assertEqual(get_status, head_status)
        self.assertEqual(get_headers["content-type"], head_headers["content-type"])
        self.assertEqual(b"not found", get_body)
        self.assertEqual(str(len(get_body)), get_headers["content-length"])
        self.assertNotIn("content-length", head_headers)
        self.assertEqual(b"", head_body)


if __name__ == "__main__":
    unittest.main()

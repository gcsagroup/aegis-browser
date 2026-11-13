import asyncio
import base64
import hashlib
import ipaddress
import sqlite3
import ssl
import subprocess
import tempfile
import threading
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

from services.access_account import credentials, node


class ControlledNodeTest(unittest.IsolatedAsyncioTestCase):
    @classmethod
    def setUpClass(cls):
        directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(directory.cleanup)
        cls.cert = Path(directory.name) / "cert.pem"
        cls.key = Path(directory.name) / "key.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                        "-subj", "/CN=localhost", "-days", "1", "-keyout", cls.key,
                        "-out", cls.cert], check=True, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)

    async def asyncSetUp(self):
        self.received = bytearray()
        self.routes = []
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.database = Path(directory.name) / "accounts.sqlite"
        self.db = sqlite3.connect(self.database, isolation_level=None)
        self.addCleanup(self.db.close)
        self.db.executescript((Path(node.__file__).parent / "schema.sql").read_text())
        credentials.migrate(self.database)
        self.now = 1000
        for account in ("a", "b"):
            token_hash = hashlib.sha256(("session-" + account).encode()).digest()
            self.db.execute("INSERT INTO accounts VALUES (?)", (account,))
            self.db.execute("INSERT INTO sessions VALUES (?, ?, 9000, NULL)", (token_hash, account))
            self.db.execute("INSERT INTO plans VALUES (?, 'paid', 'period', 0, 9000, ?)",
                            (account, "source-" + account))
            self.db.execute("INSERT INTO snapshots VALUES (?, 'period', 1000, 0, 0, 9000, 1000, 1000)",
                            (account,))
        self.enterContext(patch.object(node, "RECHECK_SECONDS", 0.15))

        async def echo(reader, writer):
            try:
                while data := await reader.read(8192):
                    self.received.extend(data)
                    writer.write(data)
                    await writer.drain()
            finally:
                writer.close()

        async def socks(reader, writer, source):
            origin = None
            tasks = []
            try:
                self.assertEqual(await reader.readexactly(3), b"\x05\x01\x00")
                writer.write(b"\x05\x00")
                self.assertEqual(await reader.readexactly(4), b"\x05\x01\x00\x01")
                pin = str(ipaddress.ip_address(await reader.readexactly(4)))
                port = int.from_bytes(await reader.readexactly(2), "big")
                self.assertEqual((pin, port), ("127.0.0.1", self.target_port))
                self.routes.append(source)
                origin_reader, origin = await asyncio.open_connection(pin, port)
                writer.write(b"\x05\x00\x00\x01" + bytes(6))
                tasks = [asyncio.create_task(node.pump(reader, origin)),
                         asyncio.create_task(node.pump(origin_reader, writer))]
                await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            finally:
                for task in tasks:
                    task.cancel()
                if origin:
                    origin.close()
                writer.close()
                await asyncio.gather(*tasks, return_exceptions=True)

        async def listener(callback):
            server = await asyncio.start_server(callback, "127.0.0.1", 0)
            self.addAsyncCleanup(server.wait_closed)
            self.addCleanup(server.close)
            return server.sockets[0].getsockname()[1]

        self.target_port = await listener(echo)
        self.authority = f"controlled.invalid:{self.target_port}"
        self.config = {"nodeId": "node-1", "targets": {self.authority: "127.0.0.1"}, "upstreams": {}}
        for source in ("source-a", "source-b"):
            port = await listener(lambda r, w, source=source: socks(r, w, source))
            self.config["upstreams"][source] = port
        self.node = node.Node(self.config, self.database, panel=None, clock_ms=lambda: self.now)
        server = await self.node.listen("127.0.0.1", 0, self.cert, self.key)
        self.addAsyncCleanup(server.wait_closed)
        self.addCleanup(server.close)
        self.port = server.sockets[0].getsockname()[1]
        managed = credentials.ManagedNode.from_config(self.config, "localhost", self.port, ttl_ms=1000)
        self.grants = {key: credentials.issue(self.database, "session-" + key, str(uuid.uuid4()),
                                              "regular", lambda: self.now, node=managed)
                       for key in ("a", "b")}

    async def connect(self, grant, *, password=None, target=None, more_headers=b""):
        tls = ssl.create_default_context(cafile=str(self.cert))
        reader, writer = await asyncio.open_connection("127.0.0.1", self.port, ssl=tls,
                                                      server_hostname="localhost")
        self.addCleanup(writer.close)
        auth = b""
        if grant:
            pair = grant["username"] + ":" + (password or grant["password"])
            auth = b"Proxy-Authorization: Basic " + base64.b64encode(pair.encode()) + b"\r\n"
        authority = (target or self.authority).encode()
        writer.write(b"CONNECT " + authority + b" HTTP/1.1\r\nHost: " + authority
                     + b"\r\n" + auth + more_headers + b"\r\n")
        headers = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 2)
        status = int(headers.split(b" ")[1])
        if status == 407:
            self.assertIn(b'Proxy-Authenticate: Basic realm="Aegis"\r\n', headers)
        return status, reader, writer

    async def test_root_dotted_authority_uses_the_same_pinned_target(self):
        dotted = f"CONTROLLED.INVALID.:{self.target_port}"
        status, reader, writer = await self.connect(self.grants["a"], target=dotted)
        self.assertEqual(status, 200)
        writer.write(b"root")
        await writer.drain()
        self.assertEqual(await asyncio.wait_for(reader.readexactly(4), 1), b"root")
        for other in ("child." + dotted, dotted.replace(".:", "..:")):
            self.assertEqual((await self.connect(self.grants["a"], target=other))[0], 403)

    async def test_account_routing_headers_and_mixed_credentials(self):
        self.assertEqual((await self.connect(None))[0], 407)
        self.assertEqual((await self.connect(self.grants["a"], password=self.grants["b"]["password"]))[0], 407)
        self.assertEqual((await self.connect(self.grants["b"], target="elsewhere.test:443"))[0], 403)
        for user in ("a", "b"):
            status, reader, writer = await self.connect(self.grants[user],
                                                        more_headers=b"Forwarded: private-value\r\n")
            self.assertEqual(status, 200)
            payload = ("payload-" + user).encode()
            writer.write(payload)
            self.assertEqual(await asyncio.wait_for(reader.readexactly(len(payload)), 2), payload)
        self.assertEqual(self.routes, ["source-a", "source-b"])
        self.assertEqual(self.received, b"payload-apayload-b")

    async def test_revocation_stops_established_stream_preserving_other_account(self):
        status, reader, writer = await self.connect(self.grants["a"])
        self.assertEqual(status, 200)
        status, other_reader, other_writer = await self.connect(self.grants["b"])
        self.assertEqual(status, 200)
        writer.write(b"active")
        self.assertEqual(await reader.readexactly(6), b"active")
        credentials.revoke(self.database, "session-a", self.grants["a"]["credentialId"], lambda: self.now)

        async def until_cutoff():
            while True:
                try:
                    writer.write(b"x")
                    if not await reader.read(1):
                        return
                except ConnectionError:
                    return
                await asyncio.sleep(0.005)

        await asyncio.wait_for(until_cutoff(), 1)
        self.assertEqual((await self.connect(self.grants["a"]))[0], 407)
        other_writer.write(b"still-active")
        self.assertEqual(await asyncio.wait_for(other_reader.readexactly(12), 1), b"still-active")

    async def test_expiry_and_exhausted_quota_close_live_tunnels(self):
        a, b = self.grants["a"], self.grants["b"]
        status, reader_a, _ = await self.connect(a)
        self.assertEqual(status, 200)
        status, reader_b, writer_b = await self.connect(b)
        self.assertEqual(status, 200)
        self.db.execute("UPDATE snapshots SET uploaded_bytes=quota_bytes WHERE account_id='a'")
        self.assertEqual(await asyncio.wait_for(reader_a.read(1), 1), b"")
        writer_b.write(b"b")
        self.assertEqual(await asyncio.wait_for(reader_b.read(1), 1), b"b")
        self.now = b["expiresAt"]
        self.assertEqual(await asyncio.wait_for(reader_b.read(1), 1), b"")
        self.assertEqual((await self.connect(b))[0], 407)

    async def test_disabled_panel_client_cannot_open_or_keep_tunnel(self):
        status, reader, _ = await self.connect(self.grants["a"])
        self.assertEqual(status, 200)

        class DisabledPanel:
            def read(self, client, clock_ms):
                raise node.Unavailable("panel client disabled")

        self.node.panel = DisabledPanel()
        self.assertEqual(await asyncio.wait_for(reader.read(1), 1), b"")
        self.assertEqual((await self.connect(self.grants["a"]))[0], 503)

    async def test_unavailable_authority_stops_live_tunnel_within_deadline(self):
        status, reader, _ = await self.connect(self.grants["b"])
        self.assertEqual(status, 200)
        self.enterContext(patch.object(node, "VERIFY_TIMEOUT", 0.15))
        release = threading.Event()
        try:
            with patch.object(node, "verify_node", side_effect=lambda *a, **k: release.wait(5)):
                self.assertEqual(await asyncio.wait_for(reader.read(1), 1), b"")
        finally:
            release.set()

    async def test_fail_closed_on_ambiguous_auth_or_absent_account_outbound(self):
        self.assertEqual((await self.connect(self.grants["a"],
                                             more_headers=b"Proxy-Authorization: Basic aaa\r\n"))[0], 407)
        del self.node.upstreams["source-a"]
        self.assertEqual((await self.connect(self.grants["a"]))[0], 503)
        self.assertEqual(self.routes, [])

    def test_dotted_and_undotted_pins_must_agree(self):
        targets = dict(self.config["targets"])
        dotted = f"controlled.invalid.:{self.target_port}"
        targets[dotted] = targets[self.authority]
        config = dict(self.config, targets=targets)
        self.assertEqual(len(node.Node(config, None, panel=None).targets), 1)
        targets[dotted] = "192.0.2.1"
        with self.assertRaises(ValueError):
            node.Node(config, None, panel=None)

    def test_shared_ports_and_unpinned_hosts_rejected(self):
        for config in (dict(self.config, upstreams={"a": 1234, "b": 1234}),
                       dict(self.config, targets={self.authority: "controlled.invalid"})):
            with self.assertRaises(ValueError):
                node.Node(config, None, panel=None)

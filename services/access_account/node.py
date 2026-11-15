"""Controlled TLS CONNECT listener with a dedicated Xray SOCKS outbound per panel client."""

import argparse
import asyncio
import base64
import ipaddress
import json
import os
import re
import ssl
import time
from pathlib import Path

from .credentials import verify_node
from .panel import Panel
from .store import Unavailable


# A live authorization is checked after two seconds. A check that cannot finish
# within one further second terminates both sides of the tunnel.
RECHECK_SECONDS = 2
VERIFY_TIMEOUT = 1
SETUP_TIMEOUT = 5
_AUTHORITY = re.compile(r"([a-z0-9.-]+|\[[a-f0-9:]+\]):([1-9][0-9]{0,4})", re.ASCII)
_HEADER = re.compile(rb"([!#$%&'*+.^_`|~a-zA-Z0-9-]+):[ \t]*([\t\x20-\x7e]*)")


class Reject(Exception):
    def __init__(self, status):
        self.status = status


def target_key(authority):
    # A DNS root separator denotes the same absolute name and pinned address.
    host, separator, port = authority.rpartition(":")
    return host.removesuffix(".") + separator + port


def parse_connect(data):
    request, *headers = data[:-4].split(b"\r\n")
    parts = request.split(b" ")
    if len(parts) != 3 or parts[0] != b"CONNECT" or parts[2] != b"HTTP/1.1":
        raise Reject(400)
    target = parts[1].decode("ascii").lower()
    auth = []
    for line in headers:
        field = _HEADER.fullmatch(line)
        if not field:
            raise Reject(400)
        name, value = field[1].lower(), field[2].strip()
        if name in (b"content-length", b"transfer-encoding"):
            raise Reject(400)
        if name == b"proxy-authorization":
            auth.append(value)
    if len(auth) != 1:
        raise Reject(407)
    scheme, _, encoded = auth[0].partition(b" ")
    try:
        if scheme.lower() != b"basic":
            raise ValueError
        username, password = base64.b64decode(encoded, validate=True).decode("ascii").split(":", 1)
        if not username or not password:
            raise ValueError
    except ValueError:
        raise Reject(407) from None
    return target_key(target), username, password


async def socks_connect(reader, writer, address, port):
    # Send only the configured numeric target. The SOCKS client never sees
    # browser HTTP headers, node credentials, or a client-selected DNS result.
    writer.write(b"\x05\x01\x00")
    await writer.drain()
    if await reader.readexactly(2) != b"\x05\x00":
        raise Reject(502)
    family = b"\x01" if address.version == 4 else b"\x04"
    writer.write(b"\x05\x01\x00" + family + address.packed + port.to_bytes(2, "big"))
    await writer.drain()
    reply = await reader.readexactly(4)
    if reply[:3] != b"\x05\x00\x00":
        raise Reject(502)
    lengths = {1: 4, 4: 16}
    if reply[3] == 3:
        length = (await reader.readexactly(1))[0]
    elif reply[3] in lengths:
        length = lengths[reply[3]]
    else:
        raise Reject(502)
    await reader.readexactly(length + 2)


async def pump(reader, writer):
    while data := await reader.read(16384):
        writer.write(data)
        await writer.drain()
        await asyncio.sleep(0)


class Node:
    def __init__(self, config, database, *, panel, clock_ms=lambda: time.time_ns() // 1_000_000):
        self.node_id = config["nodeId"]
        self.upstreams = dict(config["upstreams"])
        self.targets = {}
        for target, pin in config["targets"].items():
            match = _AUTHORITY.fullmatch(target)
            if not match or match[1].endswith("..") or int(match[2]) > 65535:
                raise ValueError("expected a lowercase target authority and explicit port")
            key = target_key(target)
            destination = (ipaddress.ip_address(pin), int(match[2]))
            if self.targets.setdefault(key, destination) != destination:
                raise ValueError("conflicting pins for the same authority")
        ports = list(self.upstreams.values())
        if (not isinstance(self.node_id, str) or not self.node_id or not self.targets or not ports
                or any(type(port) is not int or not 0 < port <= 65535 for port in ports)
                or len(set(ports)) != len(ports)):
            raise ValueError("configure a node, numeric target pins and dedicated SOCKS ports")
        self.database = database
        self.panel = panel
        self.clock_ms = clock_ms

    async def authorize(self, username, password):
        try:
            client = await asyncio.wait_for(asyncio.to_thread(
                verify_node, self.database, username, password, self.clock_ms,
                panel=self.panel, node_id=self.node_id), VERIFY_TIMEOUT)
        except (Unavailable, asyncio.TimeoutError):
            raise Reject(503) from None
        if not client:
            raise Reject(407)
        if client not in self.upstreams:
            raise Reject(503)
        return client

    async def guard(self, username, password, client):
        while True:
            await asyncio.sleep(RECHECK_SECONDS)
            if await self.authorize(username, password) != client:
                raise Reject(407)

    async def handle(self, reader, writer):
        upstream = None
        tasks = []
        established = False
        finished = set()
        status = 502
        try:
            block = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), SETUP_TIMEOUT)
            target, username, password = parse_connect(block)
            client = await self.authorize(username, password)
            if target not in self.targets:
                raise Reject(403)
            upstream_reader, upstream = await asyncio.wait_for(
                asyncio.open_connection("127.0.0.1", self.upstreams[client]), SETUP_TIMEOUT)
            await asyncio.wait_for(socks_connect(upstream_reader, upstream, *self.targets[target]),
                                   SETUP_TIMEOUT)
            # An upstream handshake can outlive a grant. Recheck before the 200.
            if await self.authorize(username, password) != client:
                raise Reject(407)
            established = True
            writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            tasks = [asyncio.create_task(coro) for coro in (
                self.guard(username, password, client), pump(reader, upstream),
                pump(upstream_reader, writer))]
            finished, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        except Reject as error:
            status = error.status
        except (UnicodeError, asyncio.LimitOverrunError):
            status = 400
        except (OSError, asyncio.IncompleteReadError, asyncio.TimeoutError):
            pass
        finally:
            for task in tasks:
                task.cancel()
            if upstream:
                upstream.transport.abort()
            if established:
                # Flush normal upstream EOF, discard pending output after authorization loss.
                if tasks[2] in finished and tasks[0] not in finished and tasks[2].exception() is None:
                    writer.close()
                else:
                    writer.transport.abort()
            else:
                reason = {400: "Bad Request", 403: "Forbidden", 407: "Proxy Authentication Required",
                          502: "Bad Gateway", 503: "Service Unavailable"}[status]
                challenge = 'Proxy-Authenticate: Basic realm="Aegis"\r\n' if status == 407 else ""
                writer.write((f"HTTP/1.1 {status} {reason}\r\n{challenge}Connection: close\r\n"
                              "Content-Length: 0\r\nCache-Control: no-store\r\n\r\n").encode())
                writer.close()
            if tasks:
                await asyncio.gather(*tasks, return_exceptions=True)

    async def listen(self, host, port, cert, key):
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.minimum_version = ssl.TLSVersion.TLSv1_2
        tls.load_cert_chain(cert, key)
        return await asyncio.start_server(self.handle, host, port, ssl=tls, limit=8192,
                                          ssl_handshake_timeout=SETUP_TIMEOUT)


async def serve(args):
    config = json.loads(Path(args.config).read_text())
    panel = Panel(args.panel_url, os.environ.get("AEGIS_3XUI_TOKEN")) if args.panel_url else None
    node = Node(config, args.database, panel=panel)
    async with await node.listen(args.host, args.port, args.cert, args.key) as listener:
        await listener.serve_forever()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("config", "database", "cert", "key"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--panel-url")
    source.add_argument("--stored-snapshots", action="store_true")
    args = parser.parse_args()
    asyncio.run(serve(args))


if __name__ == "__main__":
    main()

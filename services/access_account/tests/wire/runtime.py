"""Ephemeral loopback processes and keys for node-metering acceptance."""
import base64
import contextlib
import hashlib
import http.client
import json
import os
import secrets
import socket
import sqlite3
import ssl
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

from .tls_target import Cover, CoverConnection, Origin, PlainOrigin, PlainConnection

HERE = Path(__file__).resolve().parent
SERVICE = HERE.parent.parent
HOST = "127.0.0.1"
PERIOD = "current"
NODE = "wire-node"


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def port():
    with socket.socket() as sock:
        sock.bind((HOST, 0))
        return sock.getsockname()[1]


def until(check, seconds=10):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(.04)
    raise TimeoutError("Timed out: " + check.__name__)


def ready(port_number):
    with socket.socket() as sock:
        sock.settimeout(.1)
        return sock.connect_ex((HOST, port_number)) == 0


def dump(path, obj):
    path.write_text(json.dumps(obj), encoding="utf-8")
    return path


class Runtime:
    def __init__(self, root, stack, stock, metered, socket_path):
        self.root, self.stack = root, stack
        self.stock, self.metered = stock, metered
        self.socket_path = socket_path
        self.db = root / "accounts.sqlite"
        self.cli = [sys.executable, "-m", "services.access_account.metering"]
        self.tokens = {}
        self.logs = []
        self.origin = None

    def launch(self, name, args, *, service_port=None, socket_path=None, meter=False):
        log = self.stack.enter_context((self.root / (name + ".log")).open("w+b"))
        self.logs.append((name, log))
        env = os.environ.copy()
        env.pop("AEGIS_XRAY_METER_SOCKET", None)
        if meter:
            env["AEGIS_XRAY_METER_SOCKET"] = str(self.socket_path)
        proc = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT, env=env)
        def stop():
            proc.terminate()
            try:
                proc.wait(3)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
        self.stack.callback(stop)
        def listening():
            if proc.poll() is not None:
                raise RuntimeError(f"{name} exited with {proc.returncode}")
            return ready(service_port) if service_port else socket_path.exists()
        until(listening)
        return proc

    def serve(self, server):
        self.stack.callback(server.server_close)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.stack.callback(server.shutdown)
        return server.server_address[1]

    def setup_targets(self):
        cert, key = self.root / "cert.pem", self.root / "key.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,DNS:paid-wire.invalid",
                        "-keyout", key, "-out", cert], capture_output=True, check=True)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.minimum_version = ssl.TLSVersion.TLSv1_3
        tls.load_cert_chain(cert, key)
        tls.num_tickets = 0
        tls.set_alpn_protocols(["h2", "http/1.1"])
        self.trust = ssl.create_default_context(cafile=cert)
        self.trust.minimum_version = ssl.TLSVersion.TLSv1_3
        self.origin = Origin(tls)
        self.target = self.serve(self.origin)
        cover = Cover((HOST, 0), CoverConnection)
        cover.context = tls
        self.cover = self.serve(cover)
        self.authority = f"localhost:{self.target}"
        self.plain = PlainOrigin((HOST, 0), PlainConnection)
        self.plain.received = self.plain.sent = 0
        self.plain_port = self.serve(self.plain)
        self.plain_authority = f"localhost:{self.plain_port}"

    def seed(self):
        now = time.time_ns() // 1_000_000
        expiry = now + 600000
        with contextlib.closing(sqlite3.connect(self.db)) as db:
            db.executescript((SERVICE / "schema.sql").read_text())
            for account in ("a", "b"):
                token = secrets.token_urlsafe(32)
                self.tokens[account] = token
                db.execute("insert into accounts values (?)", (account,))
                db.execute("insert into sessions values (?,?,?,null)",
                           (hashlib.sha256(token.encode()).digest(), account, expiry))
                db.execute("insert into plans values (?,?,?,?,?,?)",
                           (account, "paid", PERIOD, now - 5000, expiry, "client-" + account))
                db.execute("insert into snapshots values (?,?,?,?,?,?,?,?)",
                           (account, PERIOD, 10**9, 0, 0, expiry, now, now))
            db.commit()

    def setup(self):
        self.setup_targets()
        self.seed()
        socks = {name: port() for name in self.tokens}
        cfg = dump(self.root / "node.json", {"nodeId": NODE, "targets": {self.authority: HOST, self.plain_authority: HOST},
                   "upstreams": {"client-" + name: number for name, number in socks.items()}})
        self.config = cfg
        self.start_collector()
        self.start_xray(socks)
        self.entry, self.api = port(), port()
        common = ["--database", self.db, "--stored-snapshots"]
        self.launch("issuer", [sys.executable, "-m", "services.access_account.server", *common,
                               "--port", str(self.api), "--node-config", cfg, "--node-host", "localhost",
                               "--node-port", str(self.entry)], service_port=self.api)
        self.launch("entry", [sys.executable, "-m", "services.access_account.node", *common,
                              "--port", str(self.entry), "--config", cfg, "--cert", self.root / "cert.pem",
                              "--key", self.root / "key.pem"], service_port=self.entry)

    def start_collector(self):
        self.collector = self.launch("collector", [*self.cli, "serve", "--database", self.db,
                                     "--config", self.config, "--socket", self.socket_path],
                                     socket_path=self.socket_path)

    def start_xray(self, socks):
        result = subprocess.check_output([self.stock, "x25519"], text=True)
        keys = dict(line.split(": ", 1) for line in result.splitlines() if ": " in line)
        users = {name: {"id": str(uuid.uuid4()), "flow": "xtls-rprx-vision",
                        "email": "client-" + name} for name in socks}
        self.reality_port = port()
        short_id = secrets.token_hex(8)
        def stream(settings):
            return {"network": "raw", "security": "reality", "realitySettings": settings}
        inbound = {"tag": "paid", "listen": HOST, "port": self.reality_port, "protocol": "vless",
                   "settings": {"decryption": "none", "clients": list(users.values())},
                   "streamSettings": stream({"target": f"{HOST}:{self.cover}", "serverNames": ["localhost"],
                                             "privateKey": keys["PrivateKey"], "shortIds": [short_id]})}
        rules = [{"action": "allow", "network": "tcp", "port": f"{self.target},{self.plain_port}", "ip": [HOST]},
                 {"action": "block"}]
        config = {"log": {"loglevel": "warning"}, "inbounds": [inbound],
                  "outbounds": [{"protocol": "freedom", "settings": {"finalRules": rules}}]}
        self.xray_process = self.launch("server-xray", [self.metered, "run", "-c", dump(self.root / "xserver.json", config)],
                    service_port=self.reality_port, meter=True)
        for name, number in socks.items():
            server = {"address": HOST, "port": self.reality_port,
                      "users": [{**users[name], "encryption": "none"}]}
            reality = {"serverName": "localhost", "password": keys["Password (PublicKey)"], "fingerprint": "chrome",
                       "shortId": short_id}
            config = {"log": {"loglevel": "warning"},
                      "inbounds": [{"protocol": "socks", "listen": HOST, "port": number,
                                    "settings": {"auth": "noauth", "udp": False}}],
                      "outbounds": [{"protocol": "vless", "settings": {"vnext": [server]},
                                     "streamSettings": stream(reality)}]}
            self.launch("client-" + name, [self.stock, "run", "-c", dump(self.root / (name + ".json"), config)],
                        service_port=number)

    def usage(self):
        return json.loads(subprocess.check_output([*self.cli, "usage", "--database", self.db,
                                                   "--node", NODE, "--period", PERIOD]))

    def grant(self, name):
        with contextlib.closing(http.client.HTTPConnection(HOST, self.api, timeout=5)) as conn:
            conn.request("POST", "/v1/me/node-credentials",
                         json.dumps({"contextId": str(uuid.uuid4()), "mode": "regular"}),
                         {"Authorization": "Bearer " + self.tokens[name], "Content-Type": "application/json"})
            response = conn.getresponse()
            require(response.status == 200, "Issuer did not authorize the test account")
            value = json.loads(response.read())
            require(value["accountId"] == name and value["periodId"] == PERIOD, "Unexpected grant scope")
            return value

    def connect(self, name, *, plain=False):
        authority = self.plain_authority if plain else self.authority
        grant = self.grant(name)
        sock = self.trust.wrap_socket(socket.create_connection((HOST, self.entry), timeout=12),
                                      server_hostname="localhost")
        self.stack.callback(sock.close)
        auth = base64.b64encode((grant["username"] + ":" + grant["password"]).encode()).decode()
        sock.sendall((f"CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\n"
                      f"Proxy-Authorization: Basic {auth}\r\n\r\n").encode())
        header = bytearray()
        while not header.endswith(b"\r\n\r\n"):
            octet = sock.recv(1)
            require(octet and len(header) < 4096, "Missing CONNECT reply")
            header.extend(octet)
        require(header.startswith(b"HTTP/1.1 200 "), "Managed entry rejected the CONNECT")
        return sock

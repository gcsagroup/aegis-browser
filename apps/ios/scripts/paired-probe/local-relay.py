"""Temporary Reality Vision comparison node with a relay-side origin witness."""
from datetime import datetime, timezone
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import select
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import urlencode
from uuid import uuid4

ROOT = Path(os.environ["AEGIS_PROBE_OUTPUT"]).resolve()
XRAY = Path(os.environ["AEGIS_PROBE_XRAY"]).resolve()
TARGETS = ("githubassets.com", "ytimg.com", "googlevideo.com", "www.githubcopilot.com", "nflxvideo.net")
CSS_HOST = "github.githubassets.com"
CSS_PATH = "/assets/light-3ee16b3ea60adc77.css"
IMAGE_HOST = "i.ytimg.com"
IMAGE_PATH = "/vi/M7lc1UVf-VE/hqdefault.jpg"
ALLOWED = frozenset({
    "www.cloudflare.com", CSS_HOST, IMAGE_HOST, *TARGETS
})
COVER = "www.cloudflare.com"
LOCK = threading.Lock()
EVENT_LOG = None

def utc():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")

def record(event, **details):
    row = {"time": utc(), "event": event, **details}
    with LOCK, EVENT_LOG.open("a") as f:
        f.write(json.dumps(row, separators=(",", ":")) + "\n")

def receive(sock, count):
    chunks = bytearray()
    while len(chunks) < count:
        data = sock.recv(count - len(chunks))
        if not data:
            raise EOFError
        chunks.extend(data)
    return bytes(chunks)

def reply(sock, code):
    sock.sendall(bytes([5, code, 0, 1, 0, 0, 0, 0, 0, 0]))


def client_hello_sni(record):
    """Read the clear SNI from a ClientHello contained in one TLS record."""
    if len(record) < 39 or record[0] != 1:
        return None
    handshake_end = 4 + int.from_bytes(record[1:4], "big")
    if handshake_end > len(record):
        return None
    try:
        cursor = 39 + record[38]
        cursor += 2 + int.from_bytes(record[cursor:cursor + 2], "big")
        cursor += 1 + record[cursor]
        end = cursor + 2 + int.from_bytes(record[cursor:cursor + 2], "big")
        cursor += 2
        while cursor + 4 <= end <= handshake_end:
            kind = int.from_bytes(record[cursor:cursor + 2], "big")
            size = int.from_bytes(record[cursor + 2:cursor + 4], "big")
            cursor += 4
            if size > end - cursor:
                return None
            if kind == 0 and size >= 5 and record[cursor + 2] == 0:
                name_size = int.from_bytes(record[cursor + 3:cursor + 5], "big")
                name = bytes(record[cursor + 5:cursor + 5 + name_size])
                if name_size <= size - 5 and re.fullmatch(rb"[A-Za-z0-9.-]{1,253}", name):
                    return name.decode("ascii")
                return None
            cursor += size
    except IndexError:
        return None
    return None


class TLSHeaders:
    """Extract record type and plaintext alert codes, without retaining payloads."""
    def __init__(self, label):
        self.header = bytearray()
        self.remaining = 0
        self.alert = None
        self.client_hello = None
        self.label = label
        self.first = True
        self.valid = True

    def feed(self, data, describe):
        offset = 0
        while self.valid and offset < len(data):
            if self.remaining:
                count = min(self.remaining, len(data) - offset)
                if self.alert is not None:
                    self.alert.extend(data[offset:offset + count])
                if self.client_hello is not None:
                    self.client_hello.extend(data[offset:offset + count])
                offset += count
                self.remaining -= count
                if self.remaining == 0 and self.alert is not None:
                    describe("tls-alert", direction=self.label, level=self.alert[0], description=self.alert[1])
                    self.alert = None
                if self.remaining == 0 and self.client_hello is not None:
                    describe("client-hello", sni=client_hello_sni(self.client_hello))
                    self.client_hello = None
                continue
            count = min(5 - len(self.header), len(data) - offset)
            self.header.extend(data[offset:offset + count])
            offset += count
            if len(self.header) != 5:
                continue
            kind, major, minor, high, low = self.header
            self.header.clear()
            length = high * 256 + low
            self.valid = kind in (20, 21, 22, 23, 24) and major == 3 and length <= 18_432
            if self.first:
                describe("first-tls-record", direction=self.label, record_type=kind, version=f"{major}.{minor}",
                         record_payload_size=length, tls_header=self.valid)
                self.first = False
                if self.valid and self.label == "relay-to-target" and kind == 22 and 0 < length <= 8192:
                    self.client_hello = bytearray()
            if self.valid:
                self.remaining = length
                self.alert = bytearray() if kind == 21 and length == 2 else None

class OriginWitness(socketserver.BaseRequestHandler):
    def handle(self):
        proxy = self.request
        proxy.settimeout(12)
        try:
            ver, count = receive(proxy, 2)
            if ver != 5 or 0 not in receive(proxy, count):
                return
            proxy.sendall(b"\x05\x00")
            ver, cmd, reserved, atyp = receive(proxy, 4)
            if (ver, cmd, reserved, atyp) != (5, 1, 0, 3):
                reply(proxy, 8)
                return
            host = receive(proxy, receive(proxy, 1)[0]).decode("ascii").lower()
            port = int.from_bytes(receive(proxy, 2), "big")
        except (EOFError, OSError, UnicodeError):
            return
        if host not in ALLOWED or port != 443:
            reply(proxy, 2)
            return
        flow = uuid4().hex[:10]
        def event(name, **values):
            record(name, flow=flow, host=host, port=port, **values)
        event("target-request")
        started = time.monotonic()
        if self.server.origin_iface:
            answers = []
            records = []
            for kind in ("A", "AAAA"):
                try:
                    response = subprocess.run(
                        ["dig", "@" + self.server.origin_dns, host, kind,
                         "+time=2", "+tries=1", "+noall", "+comments", "+answer"],
                        capture_output=True, text=True, timeout=5,
                    ).stdout
                except subprocess.TimeoutExpired:
                    response = ""
                status = re.search(r"status: ([A-Z]+)", response)
                addrs = re.findall(r"(?m)^\S+\s+\d+\s+IN\s+" + kind + r"\s+([0-9a-fA-F:.]+)$", response)
                records.append({"type":kind,"rcode":status.group(1) if status else "NO_REPLY","answers":addrs})
                if kind == "A":
                    answers.extend(addrs)
            event("lan-dns-response", records=records)
            addresses = [(socket.AF_INET,socket.SOCK_STREAM,socket.IPPROTO_TCP,"",(ip,port)) for ip in answers]
        else:
            try:
                addresses = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
            except socket.gaierror as e:
                event("dns-error", code=e.errno, elapsed_ms=round((time.monotonic() - started) * 1000))
                addresses = []
        if not addresses:
            reply(proxy, 4)
            event("close", initiator="relay", action="socks-host-unreachable", origin_socket=False)
            return
        ips = list(dict.fromkeys(a[4][0] for a in addresses))
        event("dns-addresses", addresses=ips, elapsed_ms=round((time.monotonic() - started) * 1000))
        origin = None
        for family, kind, protocol, _, address in dict.fromkeys(addresses):
            if not ipaddress.ip_address(address[0]).is_global:
                event("tcp-skip", address=address[0], reason="non-public-resolution")
                continue
            dial = socket.socket(family, kind, protocol)
            dial.settimeout(3)
            if self.server.origin_iface:
                # Darwin IP_BOUND_IF pins this one comparison socket to Ethernet.
                dial.setsockopt(socket.IPPROTO_IP, 25, socket.if_nametoindex(self.server.origin_iface))
            mark = time.monotonic()
            event("tcp-dial", address=address[0])
            try:
                dial.connect(address)
            except OSError as e:
                event("tcp-error", address=address[0], code=e.errno, kind=type(e).__name__,
                      elapsed_ms=round((time.monotonic() - mark) * 1000))
                dial.close()
                continue
            origin = dial
            event("tcp-open", address=address[0], elapsed_ms=round((time.monotonic() - mark) * 1000))
            break
        if origin is None:
            reply(proxy, 4)
            event("close", initiator="relay", action="all-target-dials-failed", origin_socket=False)
            return
        with origin:
            reply(proxy, 0)
            self.forward(proxy, origin, event)

    @staticmethod
    def forward(proxy, origin, event):
        active = {proxy: (origin, "relay-to-target"), origin: (proxy, "target-to-relay")}
        headers = {src: TLSHeaders(direction) for src, (_, direction) in active.items()}
        closed = False
        while active:
            ready, _, _ = select.select(list(active), [], [], 12 if not closed else 2)
            if not ready:
                event("witness-idle-timeout", prior_close=closed)
                return
            for source in ready:
                peer, direction = active[source]
                initiator = "target-peer" if source is origin else "xray-relay-peer"
                try:
                    data = source.recv(16_384)
                except OSError as e:
                    event("close", initiator=initiator, action="read-error", code=e.errno, first=not closed,
                          simultaneously_readable=len(ready) > 1, origin_socket=True)
                    return
                if data:
                    headers[source].feed(data, event)
                    try:
                        peer.sendall(data)
                    except OSError as e:
                        event("forward-error", direction=direction, code=e.errno)
                        return
                    continue
                event("close", initiator=initiator, action="read-eof", first=not closed,
                      simultaneously_readable=len(ready) > 1, origin_socket=True)
                closed = True
                active.pop(source)
                try:
                    peer.shutdown(socket.SHUT_WR)
                except OSError:
                    pass

class RealityIngress(socketserver.BaseRequestHandler):
    def handle(self):
        flow = uuid4().hex[:10]
        source = "mac-control" if self.client_address[0] == self.server.mac else "lan-peer"
        def event(name, **details):
            record(name, ingress=flow, peer=source, **details)
        event("reality-ingress-open")
        try:
            with socket.create_connection(("127.0.0.1", self.server.xray_port), timeout=8) as relay:
                event("reality-ingress-forwarded", xray_source_port=relay.getsockname()[1])
                sides = {self.request: (relay, "peer-to-xray"), relay: (self.request, "xray-to-peer")}
                first = set()
                while sides:
                    ready, _, _ = select.select(list(sides), [], [], 14)
                    if not ready:
                        return
                    for client in ready:
                        other, direction = sides[client]
                        data = client.recv(16384)
                        if not data:
                            event("reality-ingress-eof", direction=direction)
                            del sides[client]
                            try:
                                other.shutdown(socket.SHUT_WR)
                            except OSError:
                                pass
                            continue
                        if direction not in first:
                            first.add(direction)
                            event("reality-ingress-first", direction=direction, bytes=len(data))
                        other.sendall(data)
        except OSError as e:
            event("reality-ingress-error", code=e.errno, kind=type(e).__name__)

class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True

def temporary_port(bind):
    with socket.socket() as temp:
        temp.bind((bind, 0))
        return temp.getsockname()[1]

def mac_control(temp, route, credentials, cases, expected_country):
    control = temporary_port("127.0.0.1")
    cfg = temp / "control.json"
    cfg.write_text(json.dumps({
        "log":{"loglevel":"warning"},
        "inbounds":[{"listen":"127.0.0.1","port":control,"protocol":"socks"}],
        "outbounds":[{"protocol":"vless","settings":{"vnext":[{"address":route[0],"port":route[1],
          "users":[{"id":credentials[0],"flow":"xtls-rprx-vision","encryption":"none"}]}]},
          "streamSettings":{"network":"tcp","security":"reality","realitySettings":{
             "fingerprint":"chrome","serverName":COVER,"password":credentials[1],
             "shortId":credentials[2],"spiderX":"/"
          }}}]
    }))
    with (temp/"mac-control.log").open("w") as log:
        with subprocess.Popen([XRAY,"run","-c",cfg],stdout=log,stderr=log) as client:
            try:
                time.sleep(0.35)
                result=subprocess.run(["curl","--proxy",f"socks5h://127.0.0.1:{control}","--noproxy","",
                                       "-fsS","--max-time","12","https://www.cloudflare.com/cdn-cgi/trace"],
                                      capture_output=True,text=True)
                country=next((line[4:] for line in result.stdout.splitlines() if re.fullmatch(r"loc=[A-Z]{2}",line)),None)
                record("mac-control", code=result.returncode, country=country)
                print("Mac-to-comparison control:", country, "curl code:", result.returncode, flush=True)
                if result.returncode != 0 or country != expected_country:
                    return False
                if cases:
                    for host, path in [(CSS_HOST, CSS_PATH), *((target, "/") for target in TARGETS),
                                       (IMAGE_HOST, IMAGE_PATH)]:
                        destination = str(temp / "resource") if host in {CSS_HOST, IMAGE_HOST} else "/dev/null"
                        record("mac-case-begin", host=host)
                        r=subprocess.run(["curl","--proxy",f"socks5h://127.0.0.1:{control}","--noproxy","",
                                          "-sS","--max-time","10","-o",destination,"-w","%{http_code}",
                                          "https://"+host+path],capture_output=True,text=True)
                        record("mac-case-end", host=host, curl_code=r.returncode, status=r.stdout.strip(),
                               reasons=[k for k in ("alert","SSL_connect","timed out","Connection reset by peer",
                                                    "unexpected eof", "certificate", "hostname", "trust",
                                                    "unable to get local issuer") if k.lower() in r.stderr.lower()])
                        if host == CSS_HOST:
                            if r.returncode or r.stdout != "200":
                                return False
                            record("mac-css-control", expected_rule="--button-primary-bgColor-active",
                                   present=b"--button-primary-bgColor-active:#197935" in Path(destination).read_bytes())
                        elif host == IMAGE_HOST and r.returncode == 0 and r.stdout == "200":
                            image = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", destination],
                                                   capture_output=True, text=True)
                            dimensions = re.findall(r"pixel(?:Width|Height): ([1-9][0-9]*)", image.stdout)
                            record("mac-thumbnail-control", decoded=image.returncode == 0 and len(dimensions) == 2)
                        time.sleep(0.3)
            finally:
                if client.poll() is None:
                    client.terminate()
        return True

def local_address():
    iface = next(line.split(":", 1)[1].strip() for line in subprocess.check_output(
        ["route", "-n", "get", "default"], text=True).splitlines() if "interface:" in line)
    ip = subprocess.check_output(["ipconfig", "getifaddr", iface], text=True).strip()
    assert ipaddress.ip_address(ip).is_private
    return ip

def keypair():
    content = subprocess.check_output([XRAY, "x25519"], text=True)
    values = re.findall(r"(?m)^\s*[^:\n]+:\s*([A-Za-z0-9_-]{43})\s*$", content)
    if len(values) < 2:
        raise RuntimeError("Could not generate the temporary Reality key pair")
    return values[:2]

def main():
    global EVENT_LOG
    os.umask(0o077)
    bind = local_address()
    mac_only = "--mac-only" in sys.argv
    lan_origin = "--lan-origin" in sys.argv
    expected_country = "CN" if lan_origin else "US"
    client = "mac" if mac_only else "phone"
    route = "-en0" if lan_origin else ""
    run = f"{client}{route}-{datetime.now(timezone.utc):%Y%m%d-%H%M%S}-{uuid4().hex[:6]}"
    run_dir = ROOT / run
    run_dir.mkdir(parents=True, mode=0o700)
    EVENT_LOG = run_dir / "origin-events.jsonl"
    account = str(uuid4())
    short_id = secrets.token_hex(4)
    private, public = keypair()
    with Server(("127.0.0.1", 0), OriginWitness) as witness, Server((bind, 0), RealityIngress) as inbound, tempfile.TemporaryDirectory(
        prefix="aegis-reality-comparison-"
    ) as directory:
        witness.origin_iface = "en0" if lan_origin else None
        witness.origin_dns = None
        if lan_origin:
            dhcp = subprocess.check_output(["ipconfig","getpacket",witness.origin_iface],text=True)
            witness.origin_dns = re.search(r"(?m)^domain_name_server \(ip_mult\): \{([0-9.]+)",dhcp).group(1)
        relay_port = inbound.server_address[1]
        xray_port = temporary_port("127.0.0.1")
        inbound.xray_port = xray_port
        inbound.mac = bind
        for server in (witness, inbound):
            threading.Thread(target=server.serve_forever, daemon=True).start()
        private_dir = Path(directory)
        config = {
            "log": {"loglevel": "info"},
            "inbounds": [{
                "listen": "127.0.0.1", "port": xray_port, "tag": "comparison-vless", "protocol": "vless",
                "settings": {"clients": [{"id": account, "flow": "xtls-rprx-vision"}], "decryption": "none"},
                "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {
                    "show": False, "target": COVER + ":443", "xver": 0, "serverNames": [COVER],
                    "privateKey": private, "shortIds": [short_id]
                }}
            }],
            "outbounds": [{"protocol": "socks", "tag": "origin-witness", "settings": {
                "servers": [{"address": "127.0.0.1", "port": witness.server_address[1]}]
            }}],
        }
        node = private_dir/"node.txt"
        params = urlencode({"type":"tcp", "security":"reality", "flow":"xtls-rprx-vision",
                            "encryption":"none", "fp":"chrome", "sni":COVER, "pbk":public, "sid":short_id})
        node.write_text(f"vless://{account}@{bind}:{relay_port}?{params}#Aegis-local-compare\n")
        source = private_dir/"server.json"
        source.write_text(json.dumps(config))
        check = subprocess.run([XRAY,"run","-test","-c",source],capture_output=True)
        if check.returncode:
            raise SystemExit("Temporary Reality relay configuration failed validation")
        record("run-start", run=run, client=client, origin_interface=witness.origin_iface or "system-default",
               expected_proxy_country=expected_country)
        rawlog = private_dir/"xray.log"
        with rawlog.open("w") as output:
            relay = subprocess.Popen([XRAY, "run", "-c", source], stdout=output, stderr=output,
                                     env={**os.environ, "TZ": "UTC"})
            try:
                time.sleep(0.3)
                if relay.poll() is not None:
                    raise SystemExit("Temporary Reality relay failed to listen")
                valid = mac_control(private_dir, (bind, relay_port), (account, public, short_id), mac_only, expected_country)
                code = 0 if valid else 1
                if valid and not mac_only:
                    command = [sys.executable, "-B", str(Path(__file__).with_name("run-targeted.py")), "--tls-only"]
                    env = {**os.environ, "AEGIS_COMPARISON_RUN":run, "AEGIS_COMPARISON_NODE_FILE":str(node),
                           "AEGIS_COMPARISON_PROXY_COUNTRY":expected_country}
                    code = subprocess.run(command, env=env).returncode
            finally:
                relay.terminate()
                try:
                    relay.wait(timeout=6)
                except subprocess.TimeoutExpired:
                    relay.kill()
                    relay.wait()
                inbound.shutdown()
                witness.shutdown()
        # Retain only events tied to the known probe targets so relay address
        # and identity material never leave the temporary session.
        matches = []
        for line in rawlog.read_text(errors="replace").splitlines():
            accepted = re.match(
                r"(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?) from (?:tcp:)?127\.0\.0\.1:(\d+)"
                r" accepted tcp:([a-z0-9.-]+):443\b", line,
            )
            if accepted and accepted[3] in ALLOWED:
                timestamp = datetime.fromisoformat(accepted[1].replace("/", "-")).replace(tzinfo=timezone.utc)
                matches.append({"time": timestamp.isoformat(), "target": accepted[3],
                                "xray_source_port": int(accepted[2])})
        (run_dir / "xray-targets.json").write_text(json.dumps(matches, indent=2)+"\n")
        record("run-finish",run=run,exit_code=code)
        print("Comparison run:", run, "server target records:", len(matches), flush=True)
        return code

if __name__ == "__main__":
    raise SystemExit(main())

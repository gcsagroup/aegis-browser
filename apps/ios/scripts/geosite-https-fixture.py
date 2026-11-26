#!/usr/bin/env python3
"""Exercise the GeoSite updater against isolated TLS origins. Only the child test receives the fixture CA."""
import argparse
import base64
import copy
import datetime
import gzip
import hashlib
import json
import os
from pathlib import Path
import secrets
import ssl
# Certificate generation and explicit local test argv use shell-free subprocesses.
import subprocess  # nosec B404
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

GROUPS = {"DEBIAN": ["debian.org", "dotdeb.org"], "DOUBAN": ["douban.com", "douban.fm", "doubanio.com"],
          "MEITUAN": ["100.me", "51ping.com", "baobaoaichi.cn", "ddcorp.net", "ddfresh.net", "ddimg.mobi", "ddmaicai.net", "ddmc.mobi", "dduser.mobi", "ddxq.mobi", "dianping.com", "dpfile.com", "imaicai.mobi", "maoyan.com", "meituan.com", "meituan.net", "mtyun.com", "neixin.cn", "sankuai.com"]}
META = "/repos/XTLS/Xray-rules-dat/releases/latest"
ASSET_NAMES = ("geosite.dat", "geosite.dat.sha256sum")
CASES = {"base", "expand", "narrow", "removed", "missing-metadata", "bad-group", "bad-checksum", "bad-body",
         "partial", "compressed", "compressed-valid", "over-limit", "wrong-length", "chunked", "slow", "redirect-twice", "wrong-origin", "metadata-redirect",
         "stale-304", "etag-conflict", "rate-limit", "frozen-official", "empty-group", "equivocate"}

def proto_varint(value):
    result = bytearray()
    while value >= 128:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return bytes(result)

def field(number, value):
    return proto_varint(number * 8 + 2) + proto_varint(len(value)) + value

def catalogue(groups, bad):
    result = bytearray()
    for group, entries in groups.items():
        payload = field(1, group.encode("ascii"))
        for value in entries:
            rule_type = 1 if bad and group == "DOUBAN" else 2
            payload += field(2, bytes((8, rule_type)) + field(2, value.encode("ascii")))
        result.extend(field(1, payload))
    return bytes(result)

def digest(data):
    return hashlib.sha256(data).hexdigest()

def make_certificate(directory):
    root_key, root_pem = directory / "ca.key", directory / "ca.pem"
    leaf_key, leaf_csr, leaf_pem = (directory / name for name in ("server.key", "server.csr", "server.pem"))
    conf = directory / "leaf.ext"
    conf.write_text("basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always,issuer\nsubjectAltName=DNS:localhost\n")
    root_config = directory / "ca.cnf"
    root_config.write_text(
        "[req]\nprompt=no\ndistinguished_name=subject\nx509_extensions=ca\n"
        "[subject]\nCN=Aegis GeoSite fixture CA\n"
        "[ca]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign\nsubjectKeyIdentifier=hash\n"
    )
    commands = [
        ["req", "-x509", "-nodes", "-newkey", "rsa:2048", "-days", "2", "-config", root_config.name,
         "-keyout", root_key.name, "-out", root_pem.name],
        ["req", "-new", "-nodes", "-newkey", "rsa:2048", "-subj", "/CN=localhost",
         "-keyout", leaf_key.name, "-out", leaf_csr.name],
        ["x509", "-req", "-in", leaf_csr.name, "-CA", root_pem.name, "-CAkey", root_key.name, "-CAcreateserial",
         "-days", "2", "-sha256", "-extfile", conf.name, "-out", leaf_pem.name]
    ]
    for args in commands:
        # The fixed system executable uses fixture-owned files and configuration in a private directory.
        subprocess.run(  # nosec B603
            ["/usr/bin/openssl", *args], cwd=directory, env={"OPENSSL_CONF": root_config.name},
            check=True, shell=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(leaf_pem, leaf_key)
    ca = ssl.PEM_cert_to_DER_cert(root_pem.read_text())
    return context, base64.b64encode(ca).decode("ascii")

class State:
    def __init__(self, frozen_source=None):
        self.guard = threading.RLock()
        self.secret = secrets.token_urlsafe(24)
        self.hosts = {}
        self.case = "base"
        self.events = []
        self.version = 0
        self.anchor_date = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0) - datetime.timedelta(minutes=10)
        self.frozen_source = frozen_source

    def snapshot(self):
        if self.case == "frozen-official":
            metadata, bodies = self.frozen_source
            meta = copy.deepcopy(metadata)
            for record in [meta, *meta["assets"]]:
                for key in ("url", "html_url", "browser_download_url"):
                    if isinstance(record.get(key), str):
                        record[key] = record[key].replace("https://api.github.com/", self.hosts["metadata"] + "/").replace("https://github.com/", self.hosts["asset"] + "/")
            return meta["tag_name"], bodies, meta
        tag_time = self.anchor_date + datetime.timedelta(seconds=self.version)
        tag = tag_time.strftime("%Y%m%d%H%M%S")
        groups = {key:list(values) for key,values in GROUPS.items()}
        if self.case == "expand":
            groups["DOUBAN"].append("expanded.example.com")
        elif self.case == "equivocate":
            groups["DOUBAN"].append("mutated.example.com")
        elif self.case == "narrow":
            groups["DOUBAN"] = ["douban.com"]
        elif self.case == "removed":
            del groups["DOUBAN"]
        elif self.case == "empty-group":
            groups["DOUBAN"] = []
        data = catalogue(groups, self.case == "bad-group")
        pair_hash = "0" * 64 if self.case == "bad-checksum" else digest(data)
        pair = (pair_hash+"  geosite.dat\n").encode()
        payloads = dict(zip(ASSET_NAMES,(data,pair)))
        version_id = 1000 + self.version
        metadata = {"id": version_id, "tag_name":tag, "draft":False, "prerelease":False, "immutable":False,
                    "published_at":tag_time.isoformat().replace("+00:00","Z"),"assets":[],
                    "html_url":self.hosts["asset"] + "/XTLS/Xray-rules-dat/releases/tag/"+tag,
                    "url":self.hosts["metadata"]+"/repos/XTLS/Xray-rules-dat/releases/"+str(version_id)}
        for i,(name,body) in enumerate(payloads.items()):
            metadata["assets"].append({"id": version_id*10+i, "name":name, "state":"uploaded", "size":len(body),
                                       "digest":"sha256:"+digest(body),
                                       "url": self.hosts["metadata"]+"/repos/XTLS/Xray-rules-dat/releases/assets/"+str(version_id*10+i),
                                       "browser_download_url": self.hosts["asset"] + "/XTLS/Xray-rules-dat/releases/download/"+tag+"/"+name})
        return tag,payloads,metadata

class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args):
        pass

    def send_bytes(self, status, data=b"", headers=None):
        self.send_response(status)
        if status!=304:
            self.send_header("Content-Length", str(len(data)))
        for key,value in (headers or {}).items():
            self.send_header(key,value)
        self.end_headers()
        if data:
            try: self.wfile.write(data)
            except (OSError,ssl.SSLError): pass

    def do_POST(self):
        state=self.server.state
        if self.server.role!="metadata" or self.path!="/_fixture/"+state.secret:
            self.send_bytes(404);return
        try:
            n=int(self.headers.get("Content-Length","0"))
            if not 0<n<=512: raise ValueError()
            message=json.loads(self.rfile.read(n))
            case,version=message["case"],message["version"]
            if case not in CASES or type(version) is not int or not 0<=version<=300: raise ValueError()
            if case == "frozen-official" and state.frozen_source is None: raise ValueError()
            with state.guard:
                state.case=case;state.version=version
                if message.get("reset"): state.events.clear()
            self.send_bytes(204)
        except (ValueError,KeyError,TypeError): self.send_bytes(400)

    def do_GET(self):
        state,role=self.server.state,self.server.role
        with state.guard:
            if role=="metadata" and self.path=="/_fixture/"+state.secret:
                self.send_bytes(200,json.dumps(state.events).encode(),{"Content-Type":"application/json"});return
            case=state.case;tag,payloads,meta=state.snapshot()
            state.events.append({"role":role,"path":self.path,"ifNoneMatch":self.headers.get("If-None-Match"),
                                 "cookieSupplied":"Cookie" in self.headers,"authSupplied":"Authorization" in self.headers,
                                 "refererSupplied":"Referer" in self.headers})
        etag='W/"'+digest(json.dumps(meta,sort_keys=True,separators=(",",":")).encode())+'"'
        if role=="metadata" and self.path==META:
            if case=="metadata-redirect": self.send_bytes(302,headers={"Location":state.hosts["cdn"]+"/meta"});return
            if case=="rate-limit": self.send_bytes(429);return
            if case=="missing-metadata": self.send_bytes(404);return
            if self.headers.get("If-None-Match")==etag or case in ("stale-304","etag-conflict"):
                self.send_bytes(304,headers={"ETag":'W/"other"' if case=="etag-conflict" else etag});return
            self.send_bytes(200,json.dumps(meta).encode(),{"ETag":etag,"Content-Type":"application/json","Set-Cookie":"fixture=1; Secure"});return
        name=self.path.rsplit("/",1)[-1]
        if name not in ASSET_NAMES: self.send_bytes(404);return
        if role=="asset" and self.path=="/XTLS/Xray-rules-dat/releases/download/"+tag+"/"+name:
            target=state.hosts["metadata" if case=="wrong-origin" else "cdn"]+"/blobs/"+name
            self.send_bytes(302,headers={"Location":target});return
        if role!="cdn" or self.path!="/blobs/"+name: self.send_bytes(404);return
        body=payloads[name]
        if name=="geosite.dat":
            if case=="redirect-twice": self.send_bytes(302,headers={"Location":state.hosts["cdn"]+"/unexpected"});return
            if case=="bad-body": body=body[:-1]+bytes([body[-1]^1])
            if case=="partial": self.send_bytes(206,body[:8]);return
            if case in ("compressed", "compressed-valid"):
                encoded = gzip.compress(body) if case == "compressed-valid" else body
                self.send_bytes(200, encoded, {"Content-Encoding": "gzip"})
                return
            if case=="wrong-length":
                self.send_response(200);self.send_header("Content-Length",str(len(body)+11));self.end_headers()
                self.wfile.write(body);self.close_connection=True;return
            if case=="chunked":
                self.send_response(200);self.send_header("Transfer-Encoding","chunked");self.end_headers()
                for pos in range(0,len(body),32):
                    part=body[pos:pos+32]
                    self.wfile.write(("%x\r\n"%len(part)).encode()+part+b"\r\n")
                self.wfile.write(b"0\r\n\r\n");return
            if case=="slow": time.sleep(3)
            if case=="over-limit":
                self.send_response(200);self.send_header("Transfer-Encoding","chunked");self.end_headers()
                chunk=b"a"*(64*1024)
                try:
                    for _ in range(257): self.wfile.write(b"10000\r\n"+chunk+b"\r\n")
                    self.wfile.write(b"0\r\n\r\n")
                except OSError: pass
                return
        self.send_bytes(200,body,{"Content-Type":"application/octet-stream"})

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt",type=Path)
    parser.add_argument("--official-source", type=Path,
                        help="Optional verified snapshot containing metadata.json, geosite.dat and its official checksum")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    options=parser.parse_args()
    command=options.command[1:] if options.command[:1]==["--"] else options.command
    if not command: parser.error("supply the test command after --")
    frozen_source = None
    if options.official_source:
        snapshot = options.official_source
        metadata = json.loads((snapshot / "metadata.json").read_bytes())
        payloads = {name: (snapshot / name).read_bytes() for name in ASSET_NAMES}
        for name, body in payloads.items():
            matches = [asset for asset in metadata["assets"] if asset["name"] == name]
            if len(matches) != 1 or matches[0]["digest"] != "sha256:" + digest(body) or matches[0]["size"] != len(body):
                parser.error("frozen official asset digest, size or identity mismatch")
        if payloads["geosite.dat.sha256sum"].split() != [digest(payloads["geosite.dat"]).encode("ascii"), b"geosite.dat"]:
            parser.error("frozen official paired checksum mismatch")
        frozen_source = (metadata, payloads)
    state=State(frozen_source);servers=[]
    with tempfile.TemporaryDirectory(prefix="aegis-geosite-tls-") as tmp:
        context,public_ca=make_certificate(Path(tmp))
        try:
            for role in ("metadata","asset","cdn"):
                server=ThreadingHTTPServer(("127.0.0.1",0),Handler);server.role=role;server.state=state
                server.socket=context.wrap_socket(server.socket, server_side=True)
                servers.append(server);state.hosts[role]="https://localhost:"+str(server.server_port)
            for server in servers:threading.Thread(target=server.serve_forever,daemon=True).start()
            environment=os.environ.copy()
            values={**{name.upper():val for name,val in state.hosts.items()},"CA":public_ca,"CONTROL":state.secret}
            for key, value in values.items():
                environment["TEST_RUNNER_AEGIS_GEOSITE_" + key] = value
            environment["TEST_RUNNER_AEGIS_GEOSITE_FROZEN"] = "1" if frozen_source else "0"
            environment["TEST_RUNNER_AEGIS_GEOSITE_FIXTURE_EXTENDED"] = "1"
            environment["TEST_RUNNER_AEGIS_GEOSITE_LIVE"] = "0"
            # Only the local test operator supplies argv. The HTTPS handlers and snapshot data cannot change it.
            # nosemgrep: dangerous-subprocess-use-audit, dangerous-subprocess-use-tainted-env-args
            code = subprocess.run(command, env=environment, check=False, shell=False).returncode  # nosec B603
            if options.receipt:
                options.receipt.write_text(json.dumps({"events":state.events,"exit":code},indent=2)+"\n")
            return code
        finally:
            for server in servers: server.shutdown();server.server_close()

if __name__=="__main__":
    raise SystemExit(main())

"""Real loopback account-service responses for WebUI contract tests.

Uses only an isolated SQLite store. It neither invokes the native client nor
contacts a panel, browser, production account or proxy node.
"""

import hashlib
from contextlib import closing
import json
from pathlib import Path
import secrets
import sqlite3
import sys
import tempfile
import threading
import urllib.request

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT))
from services.access_account.server import create_server


def responses(parent_directory, stall_after_store=False):
    instant = 1_800_000_000_000
    clock = [instant]
    used = 9_007_199_254_740_997
    quota = used + 40
    with tempfile.TemporaryDirectory(prefix="aegis-usage-wire-", dir=parent_directory) as directory:
        database = Path(directory) / "accounts.sqlite"
        with closing(sqlite3.connect(database)) as db:
            db.executescript((ROOT / "services/access_account/schema.sql").read_text())
            tokens = {who: secrets.token_urlsafe(24) for who in ("A", "B")}
            for who, token in tokens.items():
                db.execute("INSERT INTO accounts VALUES (?)", (who,))
                db.execute("INSERT INTO sessions VALUES (?,?,?,NULL)",
                           (hashlib.sha256(token.encode()).digest(), who, instant + 100000))
            db.execute("INSERT INTO plans VALUES ('A','plan','period',?,?,'source-A')",
                       (instant - 10000, instant + 60000))
            db.execute("INSERT INTO snapshots VALUES ('A','period',?,?,?,?,?,?)",
                       (quota, used // 2, used - used // 2, instant + 20000,
                        instant - 1000, instant))
            db.commit()
            if stall_after_store:
                print("fixture-store-created", flush=True)
                threading.Event().wait()
            server = create_server(database, clock_ms=lambda: clock[0])
            worker = threading.Thread(target=server.serve_forever,
                                      kwargs={"poll_interval": .01}, daemon=True)
            worker.start()
            try:
                opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

                def read(who="A"):
                    request = urllib.request.Request(
                        "http://127.0.0.1:" + str(server.server_address[1]) + "/v1/me/entitlement",
                        headers={"Authorization": "Bearer " + tokens[who]})
                    with opener.open(request, timeout=3) as reply:
                        return {"status": reply.status,
                                "cacheControl": reply.headers.get("Cache-Control"),
                                "body": json.load(reply)}

                result = {"active": read(), "other": read("B"), "activeAgain": read()}
                db.execute("UPDATE snapshots SET quota_bytes=?", (used - 1,))
                db.commit()
                result["exhausted"] = read()
                clock[0] = instant + 20000
                result["expired"] = read()
                clock[0] = instant
                db.execute("UPDATE snapshots SET quota_bytes=?,measured_at=NULL,received_at=?",
                           (quota, instant - 100))
                db.commit()
                result["unknownMeasurement"] = read()
                return result
            finally:
                server.shutdown()
                worker.join(timeout=3)
                server.server_close()
                if worker.is_alive():
                    raise RuntimeError("account fixture did not stop")


if __name__ == "__main__":
    print(json.dumps(responses(sys.argv[1], "--stall-after-store" in sys.argv[2:]),
                     separators=(",", ":")))

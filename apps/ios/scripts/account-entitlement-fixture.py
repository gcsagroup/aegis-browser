#!/usr/bin/env python3
"""Run one simulator xcodebuild command against a temporary real Aegis account service."""
from contextlib import closing
from hashlib import sha256
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import os
import secrets
import sqlite3
import subprocess
import sys
from tempfile import TemporaryDirectory
import threading

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
from services.access_account.server import create_server
from services.access_account.credentials import ManagedNode


class Redirect(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path == '/v1/me/entitlement':
            self.send_response(302)
            self.send_header('Location', '/redirected')
            self.end_headers()
        else:
            if self.path == '/redirected':
                self.server.visits += 1
            self.send_response(200)
            self.end_headers()
            self.wfile.write(str(self.server.visits).encode())


def run(command):
    now = 1800000000000
    with TemporaryDirectory() as directory:
        path = Path(directory) / 'test.db'
        env = os.environ.copy()
        with closing(sqlite3.connect(path)) as db:
            db.executescript((ROOT / 'services/access_account/schema.sql').read_text())
            for account, quota, up, down in [('A', 9007199254740997, 65539, 97), ('B', 1011, 1010, 17), ('C', 10000, 10, 20)]:
                token = secrets.token_urlsafe(32)
                db.execute('INSERT INTO accounts VALUES (?)', (account,))
                db.execute('INSERT INTO sessions VALUES (?,?,?,NULL)', (sha256(token.encode()).digest(), account, now + 10000))
                db.execute('INSERT INTO plans VALUES (?,?,?,?,?,?)', (account, 'p', '1', now-10000, now+10000, account))
                db.execute('INSERT INTO snapshots VALUES (?,?,?,?,?,?,NULL,?)', (account, '1', quota, up, down, now+10000, now))
                if account == 'C':
                    db.execute('UPDATE snapshots SET measured_at=? WHERE account_id=?', (now, account))
                env['TEST_RUNNER_AEGIS_S1_FIXTURE_' + account] = token
            db.commit()
        # Only C can issue a synthetic lease. No proxy listener or external traffic is started.
        node = ManagedNode('fixture-node', '127.0.0.1', 9443, admitted_clients=frozenset({'C'}))
        with create_server(path, clock_ms=lambda: now, managed_node=node) as server, ThreadingHTTPServer(('127.0.0.1', 0), Redirect) as redirect:
            redirect.visits = 0
            for service, key in [(server, 'ORIGIN'), (redirect, 'REDIRECT')]:
                threading.Thread(target=service.serve_forever, daemon=True).start()
                env['TEST_RUNNER_AEGIS_S1_FIXTURE_' + key] = 'http://127.0.0.1:' + str(service.server_port)
            try:
                return subprocess.call(command, env=env)
            finally:
                server.shutdown()
                redirect.shutdown()


if __name__ == '__main__':
    if len(sys.argv) < 2:
        sys.exit('Pass an xcodebuild test invocation for AccessAccountSessionTests')
    sys.exit(run(sys.argv[1:]))

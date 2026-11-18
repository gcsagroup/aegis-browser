#!/usr/bin/env python3
"""Run the opt-in HTTPS redirect test with a task-local trusted localhost certificate.

Install the certificate only on the test Simulator beforehand. Pass the xcodebuild
command after --, selecting ThreeXUISubscriptionRedirectFixtureTests. No panel or
production subscription is contacted; both servers listen only on loopback.
"""
import argparse
import json
import os
import ssl
import subprocess  # nosec B404 - explicit local test command, no shell
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        if self.server.destination and self.path == "/_fixture/requests":
            body = json.dumps(self.server.paths).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.server.destination:
            self.server.paths.append(self.path)
            self.send_response(302)
            self.send_header("Location", self.server.destination + "/landed")
            self.end_headers()
            return
        if self.path != "/visits":
            self.server.visits += 1
        body = str(self.server.visits).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cert", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a test command after -- is required")
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(args.cert, args.key)
    servers = []
    try:
        for _ in range(2):
            server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            server.socket = context.wrap_socket(server.socket, server_side=True)
            server.destination = None
            server.paths = []
            server.visits = 0
            servers.append(server)
            threading.Thread(target=server.serve_forever, daemon=True).start()
        destination, origin = servers
        origin.destination = f"https://localhost:{destination.server_port}"
        environment = os.environ.copy()
        environment["TEST_RUNNER_AEGIS_3XUI_REDIRECT_ORIGIN"] = f"https://localhost:{origin.server_port}"
        environment["TEST_RUNNER_AEGIS_3XUI_REDIRECT_DESTINATION"] = origin.destination
        result = subprocess.run(command, env=environment, check=False)  # nosec B603 - explicit local command
        print(json.dumps({"originPaths": origin.paths, "destinationVisits": destination.visits}))
        return result.returncode
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    raise SystemExit(main())

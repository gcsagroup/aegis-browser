"""Independent loopback echo origin for the W2 fixture and its tests."""

from __future__ import annotations

import argparse
import socketserver
import threading
import time


class _OriginServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


class EchoOrigin:
    def __init__(self, port: int = 0, echo: bool = True,
                 push_count: int = 0, push_interval: float = 0.0):
        self.received_bytes = 0
        self.sent_bytes = 0
        self.lock = threading.Lock()
        owner = self

        class Handler(socketserver.BaseRequestHandler):
            def handle(self) -> None:
                self.request.settimeout(3)
                for _ in range(push_count):
                    try:
                        self.request.sendall(b"d")
                    except OSError:
                        return
                    with owner.lock:
                        owner.sent_bytes += 1
                    time.sleep(push_interval)
                while True:
                    try:
                        data = self.request.recv(4096)
                    except OSError:
                        return
                    if not data:
                        return
                    with owner.lock:
                        owner.received_bytes += len(data)
                    if not echo:
                        continue
                    try:
                        self.request.sendall(data)
                    except OSError:
                        return
                    with owner.lock:
                        owner.sent_bytes += len(data)

        self.server = _OriginServer(("127.0.0.1", port), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever,
                                       kwargs={"poll_interval": 0.05}, daemon=True)

    @property
    def port(self) -> int:
        return self.server.server_address[1]

    def start(self) -> None:
        self.thread.start()

    def counts(self) -> tuple[int, int]:
        with self.lock:
            return self.received_bytes, self.sent_bytes

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)


def main() -> None:
    parser = argparse.ArgumentParser(description="Local-only counted echo origin")
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    if not 0 <= args.port <= 65535:
        parser.error("invalid port")
    origin = EchoOrigin(args.port)
    origin.start()
    print(f"READY {origin.port}", flush=True)
    try:
        while True:
            time.sleep(0.2)
    except KeyboardInterrupt:
        received, sent = origin.counts()
        print(f"ORIGIN received={received} sent={sent}", flush=True)
    finally:
        origin.close()


if __name__ == "__main__":
    main()

"""Loopback-only TCP data path using durable W2 byte permits."""

from __future__ import annotations

import argparse
import asyncio
import secrets
import socket
import sys
from pathlib import Path
from typing import Callable

from ledger import Ledger, LedgerError, MAX_PERMIT_BYTES


class MeteredRelay:
    def __init__(self, ledger: Ledger, account_id: str, period_id: str,
                 origin_port: int, chunk_bytes: int = 4096,
                 io_timeout: float = 30.0, pause_marker: Path | None = None,
                 pause_after_send_marker: Path | None = None):
        if not 1 <= origin_port <= 65535 or not 1 <= chunk_bytes <= MAX_PERMIT_BYTES:
            raise ValueError("invalid relay bounds")
        if not 0 < io_timeout <= 300:
            raise ValueError("invalid I/O timeout")
        self.ledger = ledger
        self.account_id = account_id
        self.period_id = period_id
        self.origin_port = origin_port
        self.chunk_bytes = chunk_bytes
        self.io_timeout = io_timeout
        self.pause_marker = pause_marker
        self.pause_after_send_marker = pause_after_send_marker
        self.listener: socket.socket | None = None
        self.clients: set[asyncio.Task[None]] = set()

    async def _pipe(self, source: socket.socket, destination: socket.socket,
                    stream_id: str, direction: str,
                    note_activity: Callable[[], None],
                    exhausted: asyncio.Future[None],
                    live_permits: set[str]) -> bool:
        """Return True for whole-connection failure; False ends only this direction."""
        loop = asyncio.get_running_loop()
        sequence = 0
        try:
            while True:
                data = await loop.sock_recv(source, self.chunk_bytes)
                if not data:
                    try:
                        destination.shutdown(socket.SHUT_WR)
                    except OSError:
                        pass
                    return False
                sequence += 1
                permit = self.ledger.prepare(
                    self.account_id, self.period_id, stream_id, direction,
                    sequence, secrets.token_hex(16), len(data))
                if permit is None:
                    # Only a permit on this connection can still make progress.
                    return not live_permits
                live_permits.add(permit.permit_id)
                # Give a durable permit a full idle interval to finish its
                # bounded send, even when PREPARE begins near the idle deadline.
                note_activity()
                if self.pause_marker is not None:
                    # Fault injection: the marker is written only after durable PREPARE.
                    self.pause_marker.write_text(permit.permit_id, encoding="ascii")
                    await asyncio.wait_for(asyncio.Event().wait(), 30.0)
                # sock_sendall succeeds after the bytes enter the local OS send
                # path. It does not prove the peer application received them.
                await asyncio.wait_for(
                    loop.sock_sendall(destination, data[:permit.granted_bytes]),
                    self.io_timeout)
                if self.pause_after_send_marker is not None:
                    self.pause_after_send_marker.write_text(permit.permit_id, encoding="ascii")
                    await asyncio.wait_for(asyncio.Event().wait(), 30.0)
                self.ledger.complete(permit.permit_id, permit.granted_bytes)
                live_permits.remove(permit.permit_id)
                note_activity()
                # A zero remaining balance can include another direction's
                # pending permit. Let that permit settle before closing.
                balance = self.ledger.snapshot(self.account_id, self.period_id)
                if balance.actual_bytes == balance.quota_bytes:
                    if not exhausted.done():
                        exhausted.set_result(None)
                    return True
                if permit.granted_bytes < len(data):
                    return not live_permits
        except (LedgerError, OSError, TimeoutError) as error:
            print(f"relay closed {direction}: {error}", file=sys.stderr, flush=True)
            # If sendall or COMPLETE failed, the full durable permit stays held.
            return True

    async def _client(self, client: socket.socket,
                      exhausted: asyncio.Future[None]) -> None:
        if exhausted.done():
            client.close()
            return
        loop = asyncio.get_running_loop()
        origin = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        origin.setblocking(False)
        stream_id = secrets.token_hex(16)
        connect_task: asyncio.Task[None] | None = None
        tasks: set[asyncio.Task[bool]] = set()
        live_permits: set[str] = set()
        idle: asyncio.Future[None] | None = None
        idle_handle: asyncio.TimerHandle | None = None
        try:
            connect_task = asyncio.create_task(
                loop.sock_connect(origin, ("127.0.0.1", self.origin_port)))
            connected, _ = await asyncio.wait(
                {connect_task, exhausted}, timeout=self.io_timeout,
                return_when=asyncio.FIRST_COMPLETED)
            if exhausted in connected:
                return
            if connect_task not in connected:
                raise TimeoutError("origin connect timed out")
            await connect_task
            idle = loop.create_future()

            def expire_idle() -> None:
                if not idle.done():
                    idle.set_result(None)

            idle_handle = loop.call_later(self.io_timeout, expire_idle)

            def note_activity() -> None:
                nonlocal idle_handle
                if idle.done():
                    return
                idle_handle.cancel()
                idle_handle = loop.call_later(self.io_timeout, expire_idle)

            up = asyncio.create_task(self._pipe(client, origin, stream_id, "up", note_activity,
                                                exhausted, live_permits))
            down = asyncio.create_task(self._pipe(origin, client, stream_id, "down", note_activity,
                                                  exhausted, live_permits))
            tasks = {up, down}
            active_pipes = {up, down}
            while active_pipes:
                done, _ = await asyncio.wait(active_pipes | {idle, exhausted},
                                             return_when=asyncio.FIRST_COMPLETED)
                if (idle in done or exhausted in done or
                        any(task.result() for task in done if task in active_pipes)):
                    break
                active_pipes.difference_update(done)
        except (OSError, TimeoutError) as error:
            print(f"origin connection failed: {error}", file=sys.stderr, flush=True)
        finally:
            if idle_handle is not None:
                idle_handle.cancel()
            if idle is not None and not idle.done():
                idle.cancel()
            if connect_task is not None and not connect_task.done():
                connect_task.cancel()
            for task in tasks:
                if not task.done():
                    task.cancel()
            client.close()
            origin.close()
            cleanup = set(tasks)
            if connect_task is not None:
                cleanup.add(connect_task)
            if cleanup:
                await asyncio.gather(*cleanup, return_exceptions=True)

    async def serve(self, listen_port: int) -> None:
        if not 0 <= listen_port <= 65535:
            raise ValueError("invalid listen port")
        loop = asyncio.get_running_loop()
        exhausted: asyncio.Future[None] = loop.create_future()
        balance = self.ledger.snapshot(self.account_id, self.period_id)
        if balance.actual_bytes == balance.quota_bytes:
            exhausted.set_result(None)
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", listen_port))
        listener.listen(128)
        listener.setblocking(False)
        self.listener = listener
        print(f"READY {listener.getsockname()[1]}", flush=True)
        try:
            while True:
                client, _ = await loop.sock_accept(listener)
                client.setblocking(False)
                if exhausted.done():
                    client.close()
                    continue
                task = asyncio.create_task(self._client(client, exhausted))
                self.clients.add(task)
                task.add_done_callback(self.clients.discard)
        finally:
            listener.close()
            for task in self.clients:
                task.cancel()
            if self.clients:
                await asyncio.gather(*self.clients, return_exceptions=True)


def main() -> None:
    parser = argparse.ArgumentParser(description="Local W2 byte-permit relay")
    parser.add_argument("--db", required=True)
    parser.add_argument("--account", required=True)
    parser.add_argument("--period", required=True)
    parser.add_argument("--quota", type=int, required=True)
    parser.add_argument("--origin-port", type=int, required=True)
    parser.add_argument("--listen-port", type=int, default=0)
    parser.add_argument("--chunk-bytes", type=int, default=4096)
    parser.add_argument("--io-timeout", type=float, default=30.0)
    parser.add_argument("--pause-after-prepare-marker", type=Path,
                        help="test-only kill window; waits at most 30 seconds")
    parser.add_argument("--pause-after-send-marker", type=Path,
                        help="test-only kill window before COMPLETE; waits at most 30 seconds")
    args = parser.parse_args()
    try:
        ledger = Ledger(args.db)
        ledger.recover()
        ledger.configure(args.account, args.period, args.quota)
        relay = MeteredRelay(ledger, args.account, args.period, args.origin_port,
                             args.chunk_bytes, args.io_timeout,
                             args.pause_after_prepare_marker,
                             args.pause_after_send_marker)
        asyncio.run(relay.serve(args.listen_port))
    except (LedgerError, ValueError, OSError) as error:
        parser.exit(2, f"relay refused to start: {error}\n")


if __name__ == "__main__":
    main()

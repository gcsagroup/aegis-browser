#!/usr/bin/env python3
"""Run xcodebuild against a temporary loopback Alpha entitlement service.

Child stdout/stderr are suppressed: use xcodebuild -resultBundlePath for test
artifacts. This runner's receipt contains no command, endpoint or credentials.
Only explicitly authorized test panel clients may be supplied by the operator.
"""
import argparse
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import secrets
import signal
import sqlite3
import stat
import subprocess
import sys
from tempfile import TemporaryDirectory
import threading
import time

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
from services.access_account.panel import Panel
from services.access_account.server import create_server
from services.access_account.store import read_current


class SafeParser(argparse.ArgumentParser):
    def error(self, message):
        # argparse's original message may quote a secret supplied as an argument.
        self.exit(2, "Invalid runner arguments; consult --help.\n")


def private_token(path):
    path = Path(path).absolute()
    # Resolve OS aliases (e.g. macOS /var), then pin the private parent by fd.
    parent = path.parent.resolve(strict=True)
    directory = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        info = os.fstat(directory)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError("private parent required")
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        with os.fdopen(fd, "rb") as source:
            info = os.fstat(source.fileno())
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
                raise ValueError("private regular token file required")
            token = source.read(4097).decode("ascii").strip()
            if not token or len(token) > 4096 or not token.isprintable() or any(c.isspace() for c in token):
                raise ValueError("invalid token")
            return token
    finally:
        os.close(directory)


def child_environment(origin, account, token):
    # Allowlist rather than forwarding unknown token/password aliases or shell hooks.
    allowed = {"PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "TMP", "TEMP", "LANG",
               "LC_ALL", "LC_CTYPE", "DEVELOPER_DIR", "SDKROOT", "TOOLCHAINS"}
    env = {k: v for k, v in os.environ.items() if k in allowed}
    env.update(TEST_RUNNER_AEGIS_ALPHA_ORIGIN=origin,
               TEST_RUNNER_AEGIS_ALPHA_ACCOUNT=account,
               TEST_RUNNER_AEGIS_ALPHA_TOKEN=token)
    return env


def run_child(command, env, seconds):
    with subprocess.Popen(command, env=env, stdin=subprocess.DEVNULL,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                          start_new_session=True) as child:
        try:
            return child.wait(timeout=seconds)
        except BaseException:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()
            raise


def execute(args):
    started = time.time_ns() // 1_000_000
    receipt = dict(schemaVersion=1, kind="alpha-entitlement-runner", startedAt=started,
                   finishedAt=None, stage="configuration", exitCode=3, childExitCode=None)
    # Refuse overwrite/symlinks before touching a panel or starting a child.
    fd = os.open(args.output_receipt, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as output:
        try:
            panel_token = private_token(args.panel_token_file)
            if not 60 <= args.session_seconds <= 3600:
                raise ValueError("session duration outside bounds")
            command = args.command
            if command and command[0] == "--":
                command = command[1:]
            if not command or Path(command[0]).name != "xcodebuild":
                raise ValueError("xcodebuild command required")
            if (not args.account_id or len(args.account_id) > 128
                    or not args.account_id.isprintable()
                    or any(panel_token in value for value in command)):
                raise ValueError("invalid invocation")
            panel = Panel(args.panel_url, panel_token, alpha_panel_client=args.client_email)
            token = secrets.token_urlsafe(32)
            with TemporaryDirectory(prefix="aegis-alpha-entitlement-") as temporary:
                database = Path(temporary) / "accounts.sqlite"
                now = time.time_ns() // 1_000_000
                end = now + args.session_seconds * 1000
                with closing(sqlite3.connect(database)) as db:
                    os.chmod(database, 0o600)
                    db.executescript((ROOT / "services/access_account/schema.sql").read_text())
                    db.execute("INSERT INTO accounts VALUES (?)", (args.account_id,))
                    db.execute("INSERT INTO sessions VALUES (?,?,?,NULL)",
                               (hashlib.sha256(token.encode("ascii")).digest(), args.account_id, end))
                    db.execute("INSERT INTO plans VALUES (?,?,?,?,?,?)",
                               (args.account_id, "alpha-local", secrets.token_hex(16),
                                now, end, args.client_email))
                    db.commit()
                receipt["stage"] = "preflight"
                snapshot = read_current(database, token, lambda: time.time_ns() // 1_000_000, panel=panel)
                if snapshot is None or snapshot.get("quotaSource") != "3xui_alpha":
                    raise ValueError("preflight failed")
                with create_server(database, panel=panel) as server:
                    worker = threading.Thread(target=server.serve_forever,
                                              kwargs={"poll_interval": 0.05}, daemon=True)
                    worker.start()
                    try:
                        origin = f"http://127.0.0.1:{server.server_port}"
                        receipt["stage"] = "child"
                        code = run_child(command, child_environment(origin, args.account_id, token),
                                         args.session_seconds)
                        receipt.update(childExitCode=code, exitCode=code if code >= 0 else 128 - code,
                                       stage="completed")
                    finally:
                        server.shutdown()
                        worker.join()
        except subprocess.TimeoutExpired:
            receipt.update(stage="timeout", exitCode=124)
        except KeyboardInterrupt:
            receipt.update(stage="interrupted", exitCode=130)
        except Exception:
            # No exception text/traceback: HTTP, paths and argv can contain secrets.
            receipt["exitCode"] = 3
        finally:
            receipt["finishedAt"] = time.time_ns() // 1_000_000
            json.dump(receipt, output, sort_keys=True)
            output.write("\n")
    return receipt["exitCode"]


def main(argv=None):
    parser = SafeParser(description=__doc__)
    for name in ("panel-url", "panel-token-file", "client-email", "account-id", "output-receipt"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--session-seconds", type=int, default=1800)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)

    def stop(signum, frame):
        raise KeyboardInterrupt

    previous = signal.signal(signal.SIGTERM, stop)
    try:
        return execute(args)
    except Exception:
        print("Runner could not create a private receipt; no execution completed.", file=sys.stderr)
        return 3
    finally:
        signal.signal(signal.SIGTERM, previous)


if __name__ == "__main__":
    sys.exit(main())

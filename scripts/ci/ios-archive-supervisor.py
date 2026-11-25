#!/usr/bin/env python3
"""Retain archive stage status and supervise unsigned archive stages in private sessions."""

import ctypes
import errno
import os
from pathlib import Path
import select
import shutil
import signal
import stat
# Used for the fixed process census and its error types.
import subprocess  # nosec B404
import sys
import tempfile
import time


POLL_INTERVAL = 0.05
TERM_GRACE = 0.5
CENSUS_TIMEOUT = 2


def archive_environment():
    environment = {name: value for name, value in os.environ.items()
                   if not name.startswith("GIT_TRACE") and name != "GIT_CURL_VERBOSE"}
    # Override Trace2 destinations from system/global Git configuration as well.
    environment.update(GIT_TRACE2="0", GIT_TRACE2_EVENT="0", GIT_TRACE2_PERF="0")
    return environment


def process_states(timeout=CENSUS_TIMEOUT):
    rows = subprocess.check_output(  # nosec B603 - fixed ps invocation without command lines.
        ["/bin/ps", "-ax", "-o", "pid=", "-o", "stat="], text=True, timeout=timeout)
    return [(int(pid), state) for pid, state in map(str.split, rows.splitlines())]


def in_session(pid, session):
    try:
        return os.getsid(pid) == session
    except ProcessLookupError:
        return False


def session_workers(session, timeout):
    # Reparented zombies may be visible until their new parent reaps them.
    return [pid for pid, state in process_states(timeout)
            if not state.startswith("Z") and in_session(pid, session)]


def darwin_worker_signaler():
    word = ctypes.c_uint32
    audit_token = word * 8
    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    own_task = word.in_dll(library, "mach_task_self_")
    task_name = library.task_name_for_pid
    task_name.argtypes = (word, ctypes.c_int, ctypes.POINTER(word))
    task_info = library.task_info
    task_info.argtypes = (word, ctypes.c_int, ctypes.POINTER(word), ctypes.POINTER(word))
    deallocate = library.mach_port_deallocate
    deallocate.argtypes = (word, word)
    send_signal = library.proc_signal_with_audittoken
    send_signal.argtypes = (ctypes.POINTER(audit_token), ctypes.c_int)

    def signal_worker(pid, session, signum):
        port = word()
        result = task_name(own_task, pid, ctypes.byref(port))
        if result:
            raise OSError(errno.EIO, f"task_name_for_pid({pid}) returned Mach error {result}")
        token = audit_token()
        count = word(len(token))
        try:
            result = task_info(port, 15, token, ctypes.byref(count))  # TASK_AUDIT_TOKEN
            if result:
                raise OSError(errno.EIO, f"task_info({pid}) returned Mach error {result}")
        finally:
            result = deallocate(own_task, port)
            if result:
                raise OSError(errno.EIO, f"mach_port_deallocate({pid}) returned Mach error {result}")
        if count.value != len(token) or token[5] != pid:  # audit_token_to_pid()
            raise OSError(errno.EIO, f"invalid audit token for helper {pid}")
        if in_session(pid, session):
            ctypes.set_errno(0)
            if send_signal(ctypes.byref(token), signum):
                error = ctypes.get_errno() or errno.EIO
                raise OSError(error, f"could not signal helper {pid}: {os.strerror(error)}")

    return signal_worker


def linux_signal_worker(pid, session, signum):
    descriptor = os.pidfd_open(pid)
    try:
        if in_session(pid, session):
            signal.pidfd_send_signal(descriptor, signum)
    finally:
        os.close(descriptor)


def worker_signaler():
    try:
        if sys.platform == "darwin":
            return darwin_worker_signaler()
        if sys.platform == "linux" and hasattr(os, "pidfd_open") and hasattr(signal, "pidfd_send_signal"):
            return linux_signal_worker
    except (AttributeError, ValueError) as error:
        raise OSError(errno.ENOSYS, "lifetime-bound helper signalling is unavailable") from error
    raise OSError(errno.ENOSYS, "lifetime-bound helper signalling is unavailable")


def signal_separate_workers(workers, session, signum, signal_worker):
    problem = None
    for pid in workers:
        try:
            # Check membership before acquiring a handle and again after.
            if pid != session and os.getpgid(pid) != session and in_session(pid, session):
                signal_worker(pid, session, signum)
        except ProcessLookupError:
            pass
        except OSError as error:
            problem = error
    return problem


def signal_primary_group(pid, signum):
    try:
        os.killpg(pid, signum)
    except ProcessLookupError:
        pass
    except PermissionError as error:
        # Darwin can deny signalling a reserved group containing only a zombie.
        return error
    return None


def stop_and_reap(pid, signal_worker):
    # Keep the leader unreaped to reserve both the primary PGID and session ID.
    primary_problem = signal_primary_group(pid, signal.SIGTERM)
    escalate_at = time.monotonic() + TERM_GRACE
    confirm_by = escalate_at + CENSUS_TIMEOUT
    sent_helper_term = False
    empty = False
    problem = None
    while True:
        now = time.monotonic()
        force = now >= escalate_at
        if force:
            primary_problem = signal_primary_group(pid, signal.SIGKILL) or primary_problem
        if now >= confirm_by:
            os.waitpid(pid, os.WNOHANG)
            failure = problem or primary_problem
            detail = f": {failure}" if failure else ""
            raise OSError(errno.EBUSY, f"could not confirm unsigned archive session {pid} stopped{detail}")

        boundary = confirm_by if force else escalate_at
        try:
            # A slow ps must leave time for the primary group's escalation.
            workers = session_workers(pid, boundary - now)
        except (OSError, subprocess.SubprocessError) as error:
            problem = error
            empty = False
        else:
            if not workers and empty:
                reaped, status = os.waitpid(pid, os.WNOHANG)
                if reaped:
                    return status
            # Rescan after an empty snapshot in case an exiting worker forked
            # while ps was collecting the process table.
            empty = not workers
            if force or (workers and not sent_helper_term and time.monotonic() < escalate_at):
                error = signal_separate_workers(workers, pid, signal.SIGKILL if force else signal.SIGTERM, signal_worker)
                problem = error or problem
                sent_helper_term = True
        time.sleep(min(POLL_INTERVAL, max(0, boundary - time.monotonic())))


def write_all(descriptor, data):
    pending = memoryview(data)
    while pending:
        size = os.write(descriptor, pending)
        if size == 0:
            raise OSError(errno.EIO, "empty write")
        pending = pending[size:]


def write_console(data, stream=sys.stdout):
    # A stopped Actions reader must neither backpressure the child nor prevent
    # session cleanup. Drop console bytes that cannot be written immediately.
    if stream is None:
        return
    try:
        descriptor = stream.fileno()
        blocking = os.get_blocking(descriptor)
        if blocking:
            os.set_blocking(descriptor, False)
        try:
            os.write(descriptor, data)
        finally:
            if blocking:
                os.set_blocking(descriptor, True)
    except (OSError, ValueError):
        pass


def report(message):
    write_console(f"{message}\n".encode(errors="backslashreplace"), sys.stderr)


def cancellation_notice(status):
    return f"unsigned archive wrapper cancelled with status {status}"


class ArchiveOutput:
    def __init__(self, path):
        self.log = None
        self.failed = False
        try:
            self.log = open(path, "wb", buffering=0)
        except OSError as error:
            self.log_error(error)

    def log_error(self, error):
        self.failed = True
        report(f"failed to retain xcodebuild.log (errno {error.errno})")

    def notice(self, message):
        data = f"{message}\n".encode("ascii")
        if self.log is not None:
            try:
                write_all(self.log.fileno(), data)
            except OSError as error:
                self.log_error(error)
                self.close()
        write_console(data)

    def close(self):
        if self.log is not None:
            try:
                self.log.close()
            except OSError as error:
                self.log_error(error)
            finally:
                self.log = None


def wait_until_exit(pid, cancelled):
    # macOS Python 3.9 lacks waitid. Both observers leave the child unreaped.
    queue = None
    changes = []
    try:
        if not hasattr(os, "waitid"):
            queue = select.kqueue()
            changes = [select.kevent(pid, filter=select.KQ_FILTER_PROC, flags=select.KQ_EV_ADD,
                                     fflags=select.KQ_NOTE_EXIT)]
        while not cancelled():
            if queue is None:
                if os.waitid(os.P_PID, pid, os.WEXITED | os.WNOWAIT | os.WNOHANG) is not None:
                    return
            else:
                try:
                    events = queue.control(changes, 1, 0)
                except ProcessLookupError:
                    return
                changes = []
                if events:
                    event = events[0]
                    if event.flags & select.KQ_EV_ERROR and event.data != errno.ESRCH:
                        raise OSError(event.data, os.strerror(event.data))
                    return
            time.sleep(POLL_INTERVAL)
    finally:
        if queue is not None:
            queue.close()


def run_stage(command, environment, cancelled, signal_worker):
    if cancelled():
        return None
    executable = command[0]
    if not os.path.isabs(executable):
        raise OSError(errno.EINVAL, "archive stage executable must be absolute")
    # Verify process enumeration is available before starting anything that
    # might leave a helper in a second process group.
    process_states()
    if cancelled():
        return None
    # Transport configuration can change between fetches. Discard child output
    # at spawn so no stage bytes can reach the console or retained status log.
    # Keep the direct parent, atomic session creation and runner tracking env.
    # The admitted CI entrypoints supply the executable and stage-specific argv.
    # nosemgrep: dangerous-spawn-process-audit, dangerous-spawn-process-tainted-env-args
    pid = os.posix_spawn(executable, command, environment, setsid=True, setsigmask=(),
                         setsigdef=(signal.SIGINT, signal.SIGTERM, signal.SIGPIPE),
                         file_actions=[
                             (os.POSIX_SPAWN_OPEN, 1, os.devnull, os.O_WRONLY, 0),
                             (os.POSIX_SPAWN_DUP2, 1, 2),
                         ])
    try:
        wait_until_exit(pid, cancelled)
    finally:
        status = stop_and_reap(pid, signal_worker)
    code = os.waitstatus_to_exitcode(status)
    if code < 0:
        return 128 - code
    return code


def directory_identity(path, *, private):
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or path.resolve(strict=True) != path:
        raise OSError(errno.EINVAL, "scratch directory is not canonical")
    if private:
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise OSError(errno.EPERM, "scratch directory is not private")
    elif info.st_uid not in (os.getuid(), 0) or (info.st_mode & 0o022 and not info.st_mode & stat.S_ISVTX):
        raise OSError(errno.EPERM, "scratch parent is unsafe")
    return info.st_dev, info.st_ino


class JobScratch:
    def __init__(self, root):
        # Storage admission has already checked the job hierarchy and ACLs.
        # Keep sensitive diagnostics outside the retained job root, on its volume.
        root_device, _ = directory_identity(root, private=True)
        self.parent_identity = directory_identity(root.parent, private=False)
        if root_device != self.parent_identity[0] or not shutil.rmtree.avoids_symlink_attacks:
            raise OSError(errno.EPERM, "scratch lacks a same-volume parent or safe removal")
        self.path = Path(tempfile.mkdtemp(prefix=".aegis-ios-scratch-", dir=root.parent))
        self.identity = directory_identity(self.path, private=True)

    def environment(self, environment, *, for_archive=False):
        temporary = self.path / "tmp"
        temporary.mkdir(mode=0o700)
        device, inode = self.identity
        result = dict(environment, TMPDIR=str(temporary), GOTMPDIR=str(temporary), IOS_CI_SCRATCH=str(self.path),
                      IOS_CI_SCRATCH_ID=f"{device}:{inode}")
        if for_archive:
            derived = self.path / "DerivedData"
            derived.mkdir(mode=0o700)
            derived_device, derived_inode = directory_identity(derived, private=True)
            result["IOS_CI_DERIVED_ID"] = f"{derived_device}:{derived_inode}"
        return result

    def clean(self):
        try:
            if (directory_identity(self.path.parent, private=False) != self.parent_identity
                    or directory_identity(self.path, private=True) != self.identity):
                raise OSError(errno.EPERM, "scratch directory identity changed")
            shutil.rmtree(self.path)
        except OSError as error:
            report(f"failed to remove private iOS job scratch (errno {error.errno})")
            return False
        return True


def prepare_embedded_core(shell, worker, environment, cancelled, signal_worker):
    source = Path(environment["IOS_CI_SOURCE"])
    report("EmbeddedCore preparation starting (tool diagnostics withheld)")
    code = run_stage([sys.executable, "-I", "-B", str(source / "scripts/ci/ios-archive-go.py"),
                      str(source / "apps/ios/EmbeddedCore/embedded-core-lock.json"), environment["IOS_CI_SCRATCH"]],
                     environment, cancelled, signal_worker)
    if code is not None:
        report(f"locked Go setup exited with status {code}")
    if code == 0 and not cancelled():
        code = run_stage([shell, worker], environment, cancelled, signal_worker)
    if code is not None:
        report(f"EmbeddedCore preparation exited with status {code}")
    return code


def archive(log, shell, wrapper, environment, cancelled, signal_worker, cancel_status):
    output = ArchiveOutput(log)
    try:
        output.notice("unsigned archive diagnostics withheld because transport settings can change during archive")
        code = run_stage([shell, wrapper, "--verify-embedded-core"], environment, cancelled, signal_worker)
        if code is not None:
            output.notice(f"pre-compile EmbeddedCore verification exited with status {code}")
        if code == 0 and not cancelled():
            if Path.cwd() != Path(environment["IOS_CI_SOURCE"]):
                output.notice("unsigned archive source became unavailable before compilation")
                return 1, False
            code = run_stage([shell, wrapper, "--compile-archive"], environment, cancelled, signal_worker)
            if code is not None:
                output.notice(f"unsigned archive compiler exited with status {code}")
        if cancelled():
            status = cancel_status()
            output.notice(cancellation_notice(status))
            return status, True
    finally:
        output.close()
    if cancelled() or code or output.failed:
        return code or os.EX_IOERR, False
    derived = Path(environment["IOS_CI_SCRATCH"]) / "DerivedData"
    device, inode = directory_identity(derived, private=True)
    if f"{device}:{inode}" != environment["IOS_CI_DERIVED_ID"]:
        raise OSError(errno.EPERM, "archive DerivedData identity changed")
    report("unsigned archive verification starting")
    code = run_stage([shell, wrapper, "--verify-archive"], environment, cancelled, signal_worker)
    if code is not None:
        report(f"unsigned archive verification exited with status {code}")
    return code, False


def main(*arguments):
    received = 0

    def cancel(signum, _frame):
        nonlocal received
        received = received or signum

    signal.signal(signal.SIGINT, cancel)
    signal.signal(signal.SIGTERM, cancel)
    signal.signal(signal.SIGCHLD, signal.SIG_DFL)

    def cancelled():
        return received != 0

    signal_worker = worker_signaler()
    environment = archive_environment()
    scratch = JobScratch(Path(environment["IOS_CI_ROOT"]))
    preparing = arguments[0] == "--prepare-embedded-core"
    session_stopped = True
    cancellation_reported = False
    try:
        environment = scratch.environment(environment, for_archive=not preparing)
        if preparing:
            code = prepare_embedded_core(*arguments[1:], environment, cancelled, signal_worker)
        else:
            code, cancellation_reported = archive(*arguments, environment, cancelled, signal_worker, lambda: 128 + received)
    except OSError as error:
        # Do not remove an active session's scratch if its stop could not be confirmed.
        session_stopped = error.errno != errno.EBUSY
        raise
    finally:
        cleaned = session_stopped and scratch.clean()
    if received:
        status = 128 + received
        if not cancellation_reported:
            report(f"EmbeddedCore preparation cancelled with status {status}" if preparing else cancellation_notice(status))
        return status
    return code or (0 if cleaned else os.EX_IOERR)


def cli(*arguments):
    try:
        return main(*arguments)
    except subprocess.TimeoutExpired:
        report("unsigned archive supervisor: process census timed out")
    except subprocess.SubprocessError:
        report("unsigned archive supervisor: process census failed")
    except OSError as error:
        if error.errno == errno.EBUSY:
            report("unsigned archive supervisor: could not confirm archive session stopped")
        else:
            report(f"unsigned archive supervisor: OS error {error.errno}")
    return 1


if __name__ == "__main__":
    sys.exit(cli(*sys.argv[1:]))

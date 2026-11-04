"""Bound terminal evidence reception, without execution or identity authority."""
from __future__ import annotations

import base64
import binascii
import copy
from dataclasses import asdict, dataclass
import hashlib
import json
import os
import re
import stat
import threading
from typing import Callable

MAX_FRAME_BYTES = 1_048_576
MAX_RAW_BYTES = 16_777_216
MAX_STREAM_BYTES = 8_388_608
SLOT_NAME = "terminal-receipt.json"


def _integer(value, low, high):
    if type(value) is not int or not low <= value <= high:
        raise ValueError("integer range/type")


def _identifier(value):
    if type(value) is not str or re.fullmatch(r"[A-Za-z0-9_.:-]{1,128}", value) is None:
        raise ValueError("identifier")


def _hex(value, pattern):
    if type(value) is not str or re.fullmatch(pattern, value) is None:
        raise ValueError("hex encoding")


def _timebase(value):
    if type(value) is not tuple or len(value) != 2:
        raise ValueError("timebase tuple")
    for part in value:
        _integer(part, 1, 1_000_000_000)


@dataclass(frozen=True)
class ClockSample:
    continuousNS: int
    bootID: str
    timebase: tuple[int, int]

    def __post_init__(self):
        _integer(self.continuousNS, 0, 2**63 - 1)
        _identifier(self.bootID)
        _timebase(self.timebase)


@dataclass(frozen=True)
class ExpectedContext:
    version: int
    taskID: str
    nonce: str
    productSHA: str
    nativeSHA: str
    hostID: str
    bootID: str
    deadlineNS: int
    clockBootID: str
    timebase: tuple[int, int]
    stdoutMax: int
    stderrMax: int
    rawMax: int
    recordMax: int

    def __post_init__(self):
        _integer(self.version, 1, 1)
        for value in (self.taskID, self.hostID, self.bootID, self.clockBootID):
            _identifier(value)
        _hex(self.nonce, r"[0-9a-f]{32,128}")
        _hex(self.productSHA, r"[0-9a-f]{40}")
        _hex(self.nativeSHA, r"[0-9a-f]{40}")
        _integer(self.deadlineNS, 0, 2**63 - 1)
        _timebase(self.timebase)
        _integer(self.stdoutMax, 0, MAX_STREAM_BYTES)
        _integer(self.stderrMax, 0, MAX_STREAM_BYTES)
        _integer(self.rawMax, 1, MAX_RAW_BYTES)
        _integer(self.recordMax, 4096, 65536)

    def wire(self):
        value = asdict(self)
        value["timebase"] = list(self.timebase)
        return value


def _context(value):
    if type(value) is not dict or set(value) != set(ExpectedContext.__dataclass_fields__):
        raise ValueError("context fields")
    value = value.copy()
    if type(value["timebase"]) is not list:
        raise ValueError("wire timebase")
    value["timebase"] = tuple(value["timebase"])
    return ExpectedContext(**value)


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result


def _constant(_):
    raise ValueError("non-finite JSON")


def _json(raw):
    return json.loads(raw.decode("utf-8"), object_pairs_hook=_pairs,
                      parse_constant=_constant)


class ClosedReceipt(RuntimeError):
    """The first decision is already fixed; inspect Receiver.result."""


class Receiver:
    """One slot, task and deadline. The trusted caller supplies context and clock.

    feed() accepts exactly one bounded JSON frame. It does not own a transport.
    Public methods serialize access; injected clock functions must not re-enter.
    """

    def __init__(self, expected: ExpectedContext, clock: Callable[[], ClockSample],
                 directory: str | os.PathLike):
        if type(expected) is not ExpectedContext or not callable(clock):
            raise ValueError("trusted context and clock required")
        # Revalidate even if a caller bypassed the frozen dataclass convention.
        self._expected = _context(expected.wire())
        self._clock = clock
        self._lock = threading.RLock()
        self._last = None
        self._seq = 0
        self._counts = {"stdout": 0, "stderr": 0}
        self._hashes = {name: hashlib.sha256() for name in self._counts}
        self._raw_count = 0
        self._raw_hash = hashlib.sha256()
        self._result = None
        self._fd = self._dirfd = None
        self._slot_written = False
        self._restart = None
        try:
            self._dirfd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            ds = os.fstat(self._dirfd)
            if ds.st_uid != os.geteuid() or ds.st_mode & 0o022:
                raise OSError("receiver directory ownership/mode")
            try:
                self._fd = os.open(SLOT_NAME, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                                   os.O_NOFOLLOW, 0o600, dir_fd=self._dirfd)
            except FileExistsError:
                self._read_occupied()
                self._finish("UNKNOWN", "SLOT_OCCUPIED", persist=False)
                return
            # Reserve once before receiving. Empty or partial slots close all restarts.
            os.fsync(self._dirfd)
        except OSError:
            self._finish("UNKNOWN", "SLOT_UNAVAILABLE", persist=False)
            return
        self._guard()

    def _read_occupied(self):
        fd = None
        try:
            named = os.stat(SLOT_NAME, dir_fd=self._dirfd, follow_symlinks=False)
            if (not stat.S_ISREG(named.st_mode) or named.st_nlink != 1 or
                    named.st_uid != os.geteuid()):
                raise OSError("occupied slot type/owner")
            fd = os.open(SLOT_NAME, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                         dir_fd=self._dirfd)
            st = os.fstat(fd)
            if (not stat.S_ISREG(st.st_mode) or st.st_nlink != 1 or
                    (st.st_dev, st.st_ino) != (named.st_dev, named.st_ino)):
                raise OSError("occupied slot changed")
            limit = self._expected.recordMax
            # Never read unbounded existing content, and never append or remove it.
            chunks, remaining = [], limit + 1
            while remaining:
                chunk = os.read(fd, remaining)
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            data = b"".join(chunks)
            self._restart = {"observedSize": st.st_size, "prefixBytes": len(data),
                             "prefixSHA256": hashlib.sha256(data).hexdigest(),
                             "oversized": st.st_size > limit or len(data) > limit}
        except OSError:
            self._restart = {"unreadable": True}
        finally:
            if fd is not None:
                os.close(fd)

    @property
    def result(self):
        with self._lock:
            return copy.deepcopy(self._result)

    def _open(self):
        if self._result is not None:
            raise ClosedReceipt("receipt already closed")

    def _guard(self):
        try:
            sample = self._clock()
            if type(sample) is not ClockSample:
                raise ValueError("clock sample type")
            ClockSample(sample.continuousNS, sample.bootID, sample.timebase)
        except Exception:
            self._finish("UNKNOWN", "CLOCK_FAILURE")
            return False
        if (sample.bootID != self._expected.clockBootID or
                sample.timebase != self._expected.timebase):
            self._finish("UNKNOWN", "CLOCK_BINDING")
            return False
        if self._last is not None and sample.continuousNS < self._last:
            self._finish("UNKNOWN", "CLOCK_REGRESSION")
            return False
        self._last = sample.continuousNS
        if self._last >= self._expected.deadlineNS:
            self._finish("UNKNOWN", "DEADLINE")
            return False
        return True

    def _close_fds(self):
        failed = False
        for name in ("_fd", "_dirfd"):
            fd = getattr(self, name)
            setattr(self, name, None)
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    failed = True
        return failed

    def _finish(self, state, reason, actual_exit=None, persist=True):
        if self._result is not None:
            return
        row = {"version": 1, "context": self._expected.wire(), "state": state,
               "reason": reason, "actualExit": actual_exit, "grantsExecution": False,
               "nextSeq": self._seq, "observedContinuousNS": self._last,
               "rawBytes": self._raw_count, "rawSHA256": self._raw_hash.hexdigest(),
               "streams": {name: {"bytes": self._counts[name],
                                   "sha256": self._hashes[name].hexdigest()}
                           for name in self._counts},
               "stdoutEOF": True if state == "RECEIVED" else None,
               "stderrEOF": True if state == "RECEIVED" else None,
               "waitObserved": True if state == "RECEIVED" else None,
               "observationSource": "controller-observation" if state == "RECEIVED" else None,
               "restart": self._restart, "storage": "UNCONFIRMED"}
        # This decision is closed before any storage operation; nothing can retry it.
        self._result = row
        failure = None
        if persist and self._fd is not None:
            data = (json.dumps(row, sort_keys=True, separators=(",", ":"),
                               allow_nan=False) + "\n").encode()
            self._slot_written = True  # Charge full record before the first write.
            if len(data) > self._expected.recordMax:
                failure = "RECORD_LIMIT"
            else:
                try:
                    st = os.fstat(self._fd)
                    named = os.stat(SLOT_NAME, dir_fd=self._dirfd, follow_symlinks=False)
                    if (not stat.S_ISREG(st.st_mode) or st.st_nlink != 1 or st.st_size != 0 or
                            (named.st_dev, named.st_ino) != (st.st_dev, st.st_ino)):
                        raise OSError("slot changed")
                    view = memoryview(data)
                    while view:
                        n = os.write(self._fd, view)
                        if type(n) is not int or n <= 0 or n > len(view):
                            raise OSError("short write without progress")
                        view = view[n:]
                    os.fsync(self._fd)
                    os.fsync(self._dirfd)
                    named = os.stat(SLOT_NAME, dir_fd=self._dirfd, follow_symlinks=False)
                    held = os.fstat(self._fd)
                    if (held.st_nlink != 1 or held.st_size != len(data) or
                            (named.st_dev, named.st_ino) != (held.st_dev, held.st_ino)):
                        raise OSError("slot replaced during persistence")
                    row["storage"] = "FSYNC_COMPLETED"
                except OSError:
                    failure = "PERSISTENCE_ERROR"
        if self._close_fds():
            failure = failure or "CLOSE_ERROR"
        if failure:
            # The on-disk proposal may be complete or partial. Restart never trusts it.
            row["decisionReason"] = reason
            row["reason"] = failure
            row["state"] = "UNKNOWN"
            row["storage"] = "UNCONFIRMED"

    def poll(self):
        with self._lock:
            if self._result is None:
                self._guard()
            return self.result

    def abort(self, reason="LOSS"):
        if reason not in ("LOSS", "CANCELLED", "INCOMPLETE") or type(reason) is not str:
            raise ValueError("abort reason")
        with self._lock:
            self._open()
            if self._guard():
                self._finish("UNKNOWN", reason)
            return self.result

    def feed(self, raw: bytes):
        with self._lock:
            self._open()
            if not self._guard():
                return self.result
            if type(raw) is not bytes:
                self._finish("FAILED", "FRAME_TYPE")
                return self.result
            if len(raw) > MAX_FRAME_BYTES or len(raw) > self._expected.rawMax - self._raw_count:
                self._finish("FAILED", "RAW_LIMIT")
                return self.result
            self._raw_count += len(raw)
            self._raw_hash.update(raw)
            try:
                frame = _json(raw)
                if type(frame) is not dict:
                    raise ValueError("frame object")
                _integer(frame.get("version"), 1, 1)
                if _context(frame.get("context")) != self._expected:
                    raise ValueError("binding")
                _integer(frame.get("seq"), 0, 2**63 - 1)
                if frame["seq"] != self._seq:
                    raise ValueError("sequence")
                base = {"version", "context", "seq", "kind"}
                if frame.get("kind") == "data":
                    if set(frame) != base | {"stream", "data", "bytes"}:
                        raise ValueError("data fields")
                    stream = frame["stream"]
                    if type(stream) is not str or stream not in self._counts:
                        raise ValueError("stream")
                    _integer(frame["bytes"], 0, MAX_STREAM_BYTES)
                    encoded = frame["data"]
                    if type(encoded) is not str:
                        raise ValueError("base64 type")
                    remaining = getattr(self._expected, stream + "Max") - self._counts[stream]
                    if frame["bytes"] > remaining or len(encoded) > 4 * ((remaining + 2) // 3):
                        raise OverflowError("stream limit")
                    data = base64.b64decode(encoded, validate=True)
                    if base64.b64encode(data).decode("ascii") != encoded or len(data) != frame["bytes"]:
                        raise ValueError("canonical base64/declared byte count")
                    if len(data) > remaining:
                        raise OverflowError("stream limit")
                    if not self._guard():
                        return self.result
                    self._counts[stream] += len(data)
                    self._hashes[stream].update(data)
                    self._seq += 1
                    return None
                if frame.get("kind") != "terminal" or set(frame) != base | {
                        "actualExit", "stdoutEOF", "stderrEOF", "waitObserved", "observationSource"}:
                    raise ValueError("terminal fields")
                _integer(frame["actualExit"], -(2**31), 2**31 - 1)
                if any(frame[k] is not True for k in ("stdoutEOF", "stderrEOF", "waitObserved")):
                    raise ValueError("incomplete terminal observations")
                if frame["observationSource"] != "controller-observation":
                    raise ValueError("observation source")
                if self._guard():
                    self._seq += 1
                    self._finish("RECEIVED", "COMPLETE_TERMINAL", frame["actualExit"])
            except OverflowError:
                self._finish("FAILED", "STREAM_LIMIT")
            except (ValueError, TypeError, KeyError, RecursionError, binascii.Error):
                self._finish("FAILED", "INVALID_FRAME")
            return self.result

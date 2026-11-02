#!/usr/bin/env python3
"""Bounded tracker admission and result validation; build dispatch stays sealed.

Run with the pinned interpreter's -I -S -B flags. The private implementation
grant and qualified build executor are supplied separately by the coordinator.
This module cannot turn a successful parser fixture into native acceptance.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path
import stat
import sys
import time
import xml.etree.ElementTree as ET

CASES = (
    "PolicyPublicationAckTrackerTest.SharedUnitContract",
    "PolicyPublicationAckTrackerRegressionTest.SharedRegressionContract",
)
XML_CAP = 1024 * 1024
EVIDENCE_CAP = 32 * 1024 * 1024
TERMINAL_RESERVE = 1024 * 1024
TERMINAL_CAP = 32768
DEADLINE_CLOCK = "CLOCK_MONOTONIC"


class Refusal(ValueError):
    """The attempt must stop without accepting an observation."""


def isolated_entry() -> None:
    if not (sys.flags.isolated and sys.flags.no_site and sys.dont_write_bytecode):
        raise Refusal("use the pinned interpreter with -I -S -B")


def deadline_clock_ns() -> int:
    # Python 3.11's macOS monotonic_ns uses mach_absolute_time. Native uses
    # clock_gettime(CLOCK_MONOTONIC), so admission and every check select that
    # same explicit clock, including its macOS suspend semantics.
    return time.clock_gettime_ns(time.CLOCK_MONOTONIC)


@dataclass(frozen=True)
class Deadline:
    monotonic_ns: int
    boot: str

    @classmethod
    def admit(cls, expires_utc: float, boot: str, *, utc_now: float | None = None,
              monotonic_now: int | None = None) -> Deadline:
        utc_now = time.time() if utc_now is None else utc_now
        monotonic_now = deadline_clock_ns() if monotonic_now is None else monotonic_now
        remaining = expires_utc - utc_now
        if not math.isfinite(remaining) or not 0 < remaining <= 8 * 3600 or not boot:
            raise Refusal("expired, invalid or excessive grant lifetime")
        return cls(monotonic_now + int(remaining * 1_000_000_000), boot)

    def check(self, boot: str, *, now_ns: int | None = None) -> None:
        now_ns = deadline_clock_ns() if now_ns is None else now_ns
        if boot != self.boot or now_ns >= self.monotonic_ns:
            raise Refusal("original deadline expired or boot identity changed")


class Attempt:
    """Fail-first state machine. All validation errors permanently latch stop."""

    def __init__(self, deadline: Deadline, boot, guard):
        self.deadline = deadline
        self.boot = boot
        self.guard = guard
        self.stopped = False
        self.stage = 0

    def cancel(self) -> None:
        self.stopped = True

    def _check_live(self) -> None:
        if self.stopped:
            raise Refusal("sticky stop is set")
        self.deadline.check(self.boot())
        if self.stopped:
            raise Refusal("sticky stop is set")

    def check(self) -> None:
        try:
            self._check_live()
            self.guard()
            self._check_live()
        except BaseException:
            self.stopped = True
            raise

    def before_create(self) -> None:
        self.check()

    def before_go(self) -> None:
        self.check()

    def accept(self, validate, *, retired: bool, reconcile=None) -> object:
        try:
            self.check()
            if not retired:
                raise Refusal("owned child retirement is unverified")
            observation = validate()
            # Validator, output accounting and terminal writes can consume the
            # remaining lease or uncover drift. Never advance on the first check.
            self.check()
            if reconcile is not None:
                reconcile()
                # Accounting occurs after validation and the last guard's
                # possible terminal writes. Do not run a writing guard again.
            # The sole transition always follows a non-writing live check,
            # including callers without an accounting callback.
            self._check_live()
            self.stage += 1
            return observation
        except BaseException:
            self.stopped = True
            raise


def read_regular(path: Path, cap: int) -> bytes:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise Refusal("result is not a regular file")
        chunks = []
        remaining = cap
        while True:
            part = os.read(fd, min(8192, remaining + 1))
            if not part:
                return b"".join(chunks)
            if len(part) > remaining:
                raise Refusal("result byte cap exceeded")
            chunks.append(part)
            remaining -= len(part)
    finally:
        os.close(fd)


def check_hashes(inputs: dict[str, str]) -> None:
    for name, expected in inputs.items():
        path = Path(name)
        if not path.is_absolute() or path.resolve(strict=True) != path:
            raise Refusal("input path is not an admitted canonical path")
        digest = hashlib.sha256()
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                raise Refusal("admitted input is not a regular file")
            while data := os.read(fd, 1024 * 1024):
                digest.update(data)
        finally:
            os.close(fd)
        if digest.hexdigest() != expected:
            raise Refusal("source/tool/runtime input drift")


def census(root: Path, cap: int = EVIDENCE_CAP - TERMINAL_RESERVE) -> int:
    """Descriptor-relative accounting; vanished entries are failures."""
    total = 0

    def visit(fd: int) -> None:
        nonlocal total
        for name in os.listdir(fd):
            info = os.stat(name, dir_fd=fd, follow_symlinks=False)
            if stat.S_ISREG(info.st_mode):
                total += info.st_size
                if total > cap:
                    raise Refusal("evidence cap or terminal reserve exhausted")
            elif stat.S_ISDIR(info.st_mode):
                child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                                dir_fd=fd)
                try:
                    visit(child)
                finally:
                    os.close(child)
            else:
                raise Refusal("unaccountable evidence entry")

    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        visit(fd)
        return total
    finally:
        os.close(fd)


@dataclass(frozen=True)
class OwnerCompletion:
    """Observation from waiting for this invocation's directly owned owner.

    The sealed dispatch adapter must supply this from its actual wait result,
    never deserialize it from terminal evidence or import the leaf PID.
    """
    command: tuple[str, ...]
    exit_code: int | None
    completed: bool


def validate_terminal(data: bytes, deadline: Deadline, command: tuple[str, ...],
                      completion: OwnerCompletion | None) -> int:
    """A provisional receipt alone never establishes successful completion."""
    if (not isinstance(completion, OwnerCompletion) or
            completion.completed is not True or type(completion.exit_code) is not int or
            completion.exit_code != 0 or completion.command != command or
            not isinstance(command, tuple) or not command or
            any(not isinstance(arg, str) or "\0" in arg for arg in command)):
        raise Refusal("actual successful owned-owner completion is required")
    if len(data) > TERMINAL_CAP:
        raise Refusal("terminal receipt exceeds cap")
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise Refusal("duplicate terminal field")
            result[key] = value
        return result
    try:
        receipt = json.loads(data, object_pairs_hook=unique)
    except (UnicodeError, ValueError) as exc:
        raise Refusal("invalid provisional terminal receipt") from exc
    fields = {"version", "kind", "command", "deadline_ns", "boot", "reaped",
              "stopped", "go", "status"}
    if not isinstance(receipt, dict) or set(receipt) != fields:
        raise Refusal("unsupported terminal fields; accepted is never authoritative")
    if (type(receipt["version"]) is not int or receipt["version"] != 1 or
            receipt["kind"] != "provisional" or receipt["command"] != list(command) or
            type(receipt["deadline_ns"]) is not int or
            receipt["deadline_ns"] != deadline.monotonic_ns or receipt["boot"] != deadline.boot or
            receipt["reaped"] is not True or receipt["stopped"] is not False or
            receipt["go"] is not True or type(receipt["status"]) is not int or
            receipt["status"] != 0):
        raise Refusal("terminal binding, GO or successful verified leaf retirement mismatch")
    return 0


def finalize(attempt: Attempt, root: Path, cleanup, validate, *, terminal: bytes = b"",
             command: tuple[str, ...] = (), completion: OwnerCompletion | None = None) -> object:
    """Cleanup runs even if a filesystem accounting/validator exception occurs."""
    try:
        census(root)
    except BaseException as first_error:
        attempt.cancel()
        try:
            cleanup()
        except BaseException as cleanup_error:
            # Preserve the original accounting failure as the primary error.
            raise first_error from cleanup_error
        raise
    try:
        retired = cleanup()
        census(root)
    except BaseException:
        attempt.cancel()
        raise
    def observation():
        validate_terminal(terminal, attempt.deadline, command, completion)
        return validate()
    return attempt.accept(observation, retired=retired, reconcile=lambda: census(root))


def validate_clock_probe(data: bytes, deadline: Deadline, *, before_ns: int,
                         after_ns: int) -> int:
    """Reconcile the separately admitted native clock-probe observation.

    The controller samples this SAME clock around the native command and passes
    the immutable deadline/boot binding; fixture bytes do not prove a native run.
    """
    if len(data) > 512:
        raise Refusal("clock probe exceeds cap")
    def unique(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise Refusal("duplicate clock probe field")
            value[key] = item
        return value
    try:
        probe = json.loads(data, object_pairs_hook=unique)
    except (UnicodeError, ValueError) as exc:
        raise Refusal("invalid clock probe") from exc
    if not isinstance(probe, dict) or set(probe) != {"clock", "now_ns", "deadline_ns", "boot"}:
        raise Refusal("unsupported clock probe")
    now = probe["now_ns"]
    if (probe["clock"] != DEADLINE_CLOCK or probe["boot"] != deadline.boot or
            type(probe["deadline_ns"]) is not int or probe["deadline_ns"] != deadline.monotonic_ns or
            type(now) is not int or not 0 < before_ns <= now <= after_ns < deadline.monotonic_ns):
        raise Refusal("native clock/deadline/boot observation mismatch")
    return now


def validate_listing(data: bytes) -> tuple[str, ...]:
    if len(data) > XML_CAP:
        raise Refusal("listing cap exceeded")
    suite = None
    names = []
    for raw in data.decode("utf-8").splitlines():
        if not raw.strip():
            continue
        if raw.startswith("  ") and suite is not None:
            case = raw.strip()
            if not case.isidentifier():
                raise Refusal("unsupported listing entry")
            names.append(suite + case)
        elif raw.endswith(".") and raw[:-1].isidentifier():
            suite = raw
        else:
            raise Refusal("unsupported listing output")
    if len(names) != len(CASES) or set(names) != set(CASES):
        raise Refusal("listing differs from the original tracker2 identities")
    return tuple(names)


def validate_xml(data: bytes, expected: str, *, exit_code: int) -> str:
    if exit_code != 0 or expected not in CASES or len(data) > XML_CAP:
        raise Refusal("exit, identity or XML size refused")
    if b"<!" in data:
        raise Refusal("XML declarations/entities are unsupported")
    try:
        root = ET.fromstring(data)
    except ET.ParseError as exc:
        raise Refusal("incomplete XML") from exc
    if root.tag != "testsuites" or len(root) != 1 or root[0].tag != "testsuite":
        raise Refusal("unsupported XML root/suites")
    if root.attrib or root[0].attrib:
        raise Refusal("unknown XML suite attributes")
    suite = root[0]
    if [node.tag for node in suite] != ["x-teststart", "testcase"]:
        raise Refusal("missing, duplicate or unknown test results")
    start, case = suite
    for node in (start, case):
        if node.get("classname", "") + "." + node.get("name", "") != expected:
            raise Refusal("XML test identity mismatch")
    if set(start.attrib) != {"name", "classname", "timestamp"} or set(case.attrib) != {
        "name", "classname", "timestamp", "time", "status"
    }:
        raise Refusal("unknown or missing XML test attributes")
    try:
        duration = float(case.get("time", ""))
    except ValueError as exc:
        raise Refusal("invalid test duration") from exc
    if not math.isfinite(duration) or duration < 0:
        raise Refusal("invalid test duration")
    if len(start) or case.get("status") != "run":
        raise Refusal("incomplete start or skipped test")
    for part in case:
        if part.tag != "x-test-result-part" or part.get("type") != "success":
            raise Refusal("failure, skip or unknown result part")
        if set(part.attrib) != {"type", "file", "line"}:
            raise Refusal("unknown or missing result attributes")
        if [node.tag for node in part] != ["summary", "message"]:
            raise Refusal("unknown result detail")
        if any(len(node) or node.attrib for node in part):
            raise Refusal("nested result detail")
    return expected


class TrackerSequence:
    """Exact listing -> unit -> regression, with fresh outputs and no retry."""

    def __init__(self, attempt: Attempt):
        self.attempt = attempt
        self.prepared: dict[str, Path] = {}

    def listing(self, data: bytes, *, owner_exit_code: int, leaf_exit_code: int,
                retired: bool, cancelled: bool = False, terminal: bytes = b"",
                command: tuple[str, ...] = (),
                completion: OwnerCompletion | None = None) -> tuple[str, ...]:
        if (self.attempt.stage != 0 or type(owner_exit_code) is not int or
                type(leaf_exit_code) is not int or owner_exit_code != 0 or
                leaf_exit_code != 0 or cancelled):
            self.attempt.cancel()
            raise Refusal("listing execution failed, cancelled or out of sequence")
        def observation():
            validate_terminal(terminal, self.attempt.deadline, command, completion)
            return validate_listing(data)
        return self.attempt.accept(observation, retired=retired)

    def prepare(self, expected: str, path: Path) -> None:
        try:
            self.attempt.check()
            if self.attempt.stage not in (1, 2) or expected != CASES[self.attempt.stage - 1]:
                raise Refusal("case out of sequence")
            if expected in self.prepared or os.path.lexists(path):
                raise Refusal("preexisting XML or attempted retry")
            if not path.is_absolute() or path.parent.resolve(strict=True) != path.parent:
                raise Refusal("XML output parent is not canonical")
            self.prepared[expected] = path
        except BaseException:
            self.attempt.cancel()
            raise

    def result(self, expected: str, *, exit_code: int, retired: bool,
               terminal: bytes = b"", command: tuple[str, ...] = (),
               completion: OwnerCompletion | None = None) -> str:
        try:
            if self.attempt.stage not in (1, 2) or expected != CASES[self.attempt.stage - 1]:
                raise Refusal("case result out of sequence")
            path = self.prepared.pop(expected)
            def observation():
                validate_terminal(terminal, self.attempt.deadline, command, completion)
                return validate_xml(read_regular(path, XML_CAP), expected, exit_code=exit_code)
            return self.attempt.accept(observation, retired=retired)
        except BaseException:
            self.attempt.cancel()
            raise


def build_dispatch(*_args, **_kwargs) -> None:
    raise Refusal("B1: an owned GN/Ninja executor and producer lineage are required")


if __name__ == "__main__":
    isolated_entry()
    raise SystemExit("No native dispatch grant is installed; build dispatch is sealed.")

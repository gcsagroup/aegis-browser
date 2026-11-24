import base64
import hashlib
import json
import os
import stat
import tempfile
import time
import unittest

from dataclasses import replace
from pathlib import Path
from subprocess import TimeoutExpired
from unittest.mock import patch

from access_campaign_observer import (
    CampaignLimits,
    CampaignObserver,
    LedgerObservationUnavailable,
    LedgerPollDeferred,
    LedgerPrefixChanged,
    read_campaign_receipt,
)


TARGETS = ("first.invalid", "second.invalid")
TIMEOUT_TARGETS = TARGETS + ("third.invalid", "fourth.invalid")
LIMITS = CampaignLimits(len(TARGETS), 20 * 60, 256 * 1024 * 1024, 30_000)
IDENTITY = {
    "campaignID": "owned-fixture",
    "device": "test-device",
    "sourceSHA": "a" * 40,
    "targetsSHA256": hashlib.sha256(("\n".join(TARGETS) + "\n").encode()).hexdigest(),
    "nodeInputSHA256": "c" * 64,
}
TOKEN = b"aegis-access-lease-v1 64c495d0-4e21-4f48-8dde-cce9b810a3a8\n"
NEXT_TOKEN = TOKEN.replace(b"f48", b"f18")
INITIAL_TOKEN = TOKEN.replace(b"f48", b"f08")
NS_PER_MS = 1_000_000


def row(event, **fields):
    if event in {"reserved", "dispatch", "result", "retirement"}:
        reserved_at = 2_000 + fields["ordinal"] * 1_000
        offset = {"reserved": 0, "dispatch": 3, "result": 300, "retirement": 600}[event]
        elapsed_ms = reserved_at + offset
    elif event == "health":
        elapsed_ms = 1_000 if fields.get("phase") == "before-first-target" else 12_000
    else:
        elapsed_ms = {"start": 0, "permit": 0, "dispatch-paused": 10_000, "checkpoint": 28_000}[event]
    fields.setdefault("elapsedNs", fields.get("elapsedMs", elapsed_ms) * NS_PER_MS)
    fields.setdefault("elapsedMs", fields["elapsedNs"] // NS_PER_MS)
    if event == "reserved":
        fields.setdefault("admittedAtNs", fields["elapsedNs"])
    if event == "dispatch":
        fields.setdefault("navigationIssuedAtNs", (reserved_at + 2) * NS_PER_MS)
    if event == "dispatch-paused":
        fields.setdefault("pausedAtNs", fields["elapsedNs"])
    if event == "checkpoint" and "budgetStopReason" in fields:
        fields.setdefault("budgetStopAtNs", fields["elapsedNs"])
    if event in {"result", "health"}:
        page_start = (reserved_at + 1 if event == "result"
                      else 10 if fields.get("phase") == "before-first-target" else 10_010)
        fields.setdefault("pageStartedAtNs", page_start * NS_PER_MS)
        if event == "health":
            fields.setdefault("healthAdmittedAtNs", fields["pageStartedAtNs"])
        timeline = {}
        for claim, name, at in (("navigationIssued", "loadIssued", 1),
                                ("documentCommitted", "documentCommit", 5),
                                ("documentFinished", "documentFinish", 7)):
            if fields.get(claim) is True:
                timeline[name] = at
        if fields.get("navigationIssued") is True:
            fields.setdefault("navigationIssuedAtNs", fields["pageStartedAtNs"] + NS_PER_MS)
        fields.setdefault("actualProtocol", "socks5" if fields.get("navigationIssued") or fields.get("localLoadDisposition")
                          else "unbound")
        if fields["actualProtocol"] != "unbound":
            fields.setdefault("port", 20080)
            fields.setdefault("preparationStartedAtNs", fields["pageStartedAtNs"])
            fields.setdefault("preparationDeadlineAtNs", fields["pageStartedAtNs"] + 15_000 * NS_PER_MS)
        elif fields.get("preparationDeadlineAtNs") is not None:
            fields.setdefault("preparationStartedAtNs", fields["pageStartedAtNs"])
        if "firstVisibleHTTPStatus" in fields:
            timeline["firstVisibleHTTPResponse"] = 3
        fields.setdefault("initialResponseObserved", "initialHTTPStatus" in fields)
        if fields.get("outcome") == "timeout":
            fields.setdefault("errorDomain", "NSURLErrorDomain")
            fields.setdefault("errorCode", -1001)
        if fields.get("errorDomain"):
            timeline["navigationFailure" if fields.get("navigationIssued") else "preparationFailure"] = 10
        if fields.get("localPolicyRejection"):
            timeline["policyRejection"] = 12
        if fields.get("localLoadDisposition"):
            timeline["loadNotAccepted"] = 2
        fields.setdefault("timelineMs", timeline)
        add_timeline_instants(fields)
        fields.setdefault("observationCutoffMs", 20)
        fields.setdefault("observationCutoffAtNs", fields["pageStartedAtNs"] + fields["observationCutoffMs"] * NS_PER_MS)
        late_ms = 30 if fields.get("observedAfterCutoff") else 0
        fields.setdefault("observedThroughAtNs", fields["observationCutoffAtNs"] + late_ms * NS_PER_MS)
        add_stop_instant(fields, "observedAfterCutoff", fields["pageStartedAtNs"])
        if "observedAfterCutoff" in fields:
            fields["observedAfterCutoff"] = add_timeline_instants(dict(fields["observedAfterCutoff"]))
    if event in {"health", "retirement"} and "retirementRequestedAtMs" in fields:
        base_ns = fields["pageStartedAtNs"] if event == "health" else (reserved_at + 1) * NS_PER_MS
        fields.setdefault("retirementRequestedAtNs", base_ns + fields["retirementRequestedAtMs"] * NS_PER_MS)
        if "retirementObservedMs" in fields:
            fields.setdefault("retirementObservedThroughAtNs",
                              fields["retirementRequestedAtNs"] + fields["retirementObservedMs"] * NS_PER_MS)
        for key in ("retirementCommit", "transportQuiesced"):
            if type(fields.get(key + "AtMs")) is int:
                fields.setdefault(key + "AtNs", base_ns + fields[key + "AtMs"] * NS_PER_MS)
        if "retirementObservedThroughAtNs" in fields:
            earliest_poll = (fields["observedThroughAtNs"] if event == "health" else (reserved_at + 300) * NS_PER_MS)
            fields.setdefault("retirementFirstPolledAtNs", max(earliest_poll, fields["retirementRequestedAtNs"]))
            released_ns = fields.get("retirementCommitAtNs")
            if fields["retirementState"] == "unbound":
                released_ns = fields["retirementRequestedAtNs"]
            sample = fields.get("transportQuiescedAtNs")
            exit_poll = sample if released_ns is not None and sample is not None and sample >= released_ns else (
                fields["retirementObservedThroughAtNs"])
            fields.setdefault("retirementExitPolledAtNs", exit_poll)
        if isinstance(fields.get("originalNavigationAfterClose"), dict):
            fields["originalNavigationAfterClose"] = add_timeline_instants(dict(fields["originalNavigationAfterClose"]))
        add_stop_instant(fields, "haltDuringRetirement", base_ns)
    counters = {"chargedBytes": 0, "reservedBytes": 0}
    return (json.dumps(dict(IDENTITY, schemaVersion=3, event=event, **(counters | fields)), sort_keys=True) + "\n").encode()


def add_stop_instant(fields, name, origin_ns):
    stop = fields.get(name)
    if isinstance(stop, dict) and type(stop.get("stopAtMs")) is int:
        fields[name] = {"stopAtNs": origin_ns + stop["stopAtMs"] * NS_PER_MS} | stop


def add_timeline_instants(fields):
    if "timelineMs" in fields:
        fields.setdefault("timelineNs", {key: at * NS_PER_MS for key, at in fields["timelineMs"].items()})
    return fields


def stage(event, ordinal=1, **fields):
    return row(event, ordinal=ordinal, host=TARGETS[ordinal - 1], attempt=f"owned-key-{ordinal}", **fields)


def challenge(token, *, issued=0, issued_ns=None, appended=None, **counters):
    issued_ns = issued * NS_PER_MS if issued_ns is None else issued_ns
    return row("permit", challengeSHA256=hashlib.sha256(token).hexdigest(),
               challengeIssuedAtNs=issued_ns, elapsedNs=issued_ns if appended is None else appended * NS_PER_MS,
               **counters)


def permit_series(origin, times):
    return b"".join(challenge(TOKEN.replace(b"f48", f"{index:03x}".encode()),
                              issued=origin + issued, appended=origin + written)
                    for index, (issued, written) in enumerate(times))


START = row("start", elapsedMs=1, **LIMITS.fields())
ARMED = START + challenge(INITIAL_TOKEN, appended=2)
GRANTED = ARMED + challenge(TOKEN, issued=5)
HEALTH_WITNESSES = {"retirementRequestedAtMs": 100, "retirementCommitAtMs": 150,
                    "transportQuiescedAtMs": 150, "retirementObservedMs": 60}
WITNESSES = HEALTH_WITNESSES | {"retirementCommitAtMs": 310, "transportQuiescedAtMs": 350, "retirementObservedMs": 300}
TIMEOUT_WITNESSES = WITNESSES | {"retirementRequestedAtMs": 11, "retirementObservedMs": 389}


def healthy(**fields):
    return row("health", **({"phase": "before-first-target", "outcome": "finished",
                            "firstVisibleHTTPStatus": 200, "lastHTTPStatus": 200,
                            "navigationIssued": True, "documentCommitted": True, "documentFinished": True,
                            "actualProtocol": "socks5", "retirementState": "confirmed", "transportQuiesced": True}
                           | HEALTH_WITNESSES | fields))


READY = GRANTED + healthy()
RESERVED = stage("reserved")
DISPATCH = stage("dispatch")
RESULT = stage("result", outcome="finished", navigationIssued=True, documentCommitted=True, documentFinished=True)
RETIRED = stage("retirement", retirementState="confirmed", transportQuiesced=True, **WITNESSES)
PAUSED = row("dispatch-paused", reason="three-no-http-timeouts", reservedCount=3)


def campaign_fixture(targets):
    limits = CampaignLimits(len(targets), LIMITS.duration_seconds, LIMITS.bytes, LIMITS.permit_window_ms)
    identity = IDENTITY | {"targetsSHA256": hashlib.sha256(("\n".join(targets) + "\n").encode()).hexdigest()}

    def read(raw):
        bound = raw.replace(IDENTITY["targetsSHA256"].encode(), identity["targetsSHA256"].encode())
        return read_campaign_receipt(bound, targets, identity, limits)

    return row("start", elapsedMs=1, **limits.fields()) + READY[len(START):], read


def three_timeout_fixture():
    targets = TIMEOUT_TARGETS
    native, read = campaign_fixture(targets)
    for index, host in enumerate(targets[:3], 1):
        key = {"ordinal": index, "host": host, "attempt": f"owned-key-{index}"}
        native += row("reserved", **key)
        native += row("dispatch", **key)
        native += row("result", **key, outcome="timeout", navigationIssued=True,
                      documentCommitted=False, documentFinished=False)
        native += row("retirement", **key, retirementState="confirmed", transportQuiesced=True, **TIMEOUT_WITNESSES)
    return native, read


def probe_fixtures():
    timeout, read_final = three_timeout_fixture()

    def read_initial(raw):
        return read_campaign_receipt(raw, TARGETS, IDENTITY, LIMITS)

    return (
        ("before-first-target", GRANTED, 0, read_initial),
        ("after-three-no-http-timeouts", timeout + PAUSED, 10_000, read_final),
    )


def sequenced_probe(phase, origin, **fields):
    return healthy(**({
        "phase": phase, "healthAdmittedAtNs": (origin + 8) * NS_PER_MS,
        "pageStartedAtNs": (origin + 10) * NS_PER_MS,
        "preparationStartedAtNs": (origin + 14) * NS_PER_MS,
        "preparationDeadlineAtNs": (origin + 15_014) * NS_PER_MS,
        "navigationIssuedAtNs": (origin + 20) * NS_PER_MS,
        "timelineMs": {"loadIssued": 10, "firstVisibleHTTPResponse": 22,
                       "documentCommit": 30, "documentFinish": 40},
        "observationCutoffMs": 65, "retirementRequestedAtMs": 80,
        "retirementFirstPolledAtNs": (origin + 110) * NS_PER_MS,
        "retirementCommitAtMs": 145, "transportQuiescedAtMs": 160, "retirementObservedMs": 100,
    } | fields))


def stopped_load_probe(phase, origin, *, reason, stopped, load=None, accepted=False, bound=True, charged=0):
    evidence = {"timelineMs": {}}
    if load is not None:
        marker = "loadIssued" if accepted else "loadNotAccepted"
        attempt = {"timelineMs": {marker: load - 10}}
        if not accepted:
            attempt["localLoadDisposition"] = "load-not-accepted"
        evidence.update(attempt if stopped >= load else {"observedAfterCutoff": attempt})
        if accepted:
            evidence["navigationIssuedAtNs"] = (origin + load) * NS_PER_MS
    requested = 36 if accepted or not bound else max(stopped, load or 0) + 1
    return row("health", phase=phase, outcome="stopped", stopReason=reason, elapsedMs=origin + 110,
               pageStartedAtNs=(origin + 10) * NS_PER_MS, healthAdmittedAtNs=(origin + 8) * NS_PER_MS,
               preparationStartedAtNs=(origin + 14) * NS_PER_MS, preparationDeadlineAtNs=(origin + 15_014) * NS_PER_MS,
               observationCutoffMs=stopped - 10, observedThroughAtNs=(origin + 35) * NS_PER_MS,
               navigationIssued=accepted, documentCommitted=False, documentFinished=False,
               actualProtocol="socks5" if bound else "unbound", chargedBytes=charged,
               retirementState="confirmed" if bound else "unbound", retirementRequestedAtMs=requested - 10,
               retirementFirstPolledAtNs=(origin + 40) * NS_PER_MS, retirementCommitAtMs=65 if bound else None,
               transportQuiesced=True, transportQuiescedAtMs=80, retirementObservedMs=100 - requested, **evidence)


def target_drain_fixture(offset=0):
    prefix = READY + RESERVED + DISPATCH + challenge(NEXT_TOKEN, issued=3_021 + offset)
    result = stage("result", elapsedMs=3_050 + offset, outcome="finished", navigationIssued=True,
                   documentCommitted=True, documentFinished=True,
                   firstVisibleHTTPStatus=200, lastHTTPStatus=200, observationCutoffMs=47 + offset,
                   timelineMs={"loadIssued": 1, "firstVisibleHTTPResponse": 29 + offset,
                               "documentCommit": 34 + offset, "documentFinish": 38 + offset})
    retirement = stage("retirement", elapsedMs=3_180 + offset, retirementState="confirmed", transportQuiesced=True,
                       retirementRequestedAtMs=48 + offset, retirementObservedMs=111,
                       retirementFirstPolledAtNs=(3_050 + offset) * NS_PER_MS,
                       retirementCommitAtMs=99 + offset, transportQuiescedAtMs=149 + offset)
    return prefix + result, retirement


def change_row(raw, **fields):
    return (json.dumps(json.loads(raw) | fields, sort_keys=True) + "\n").encode()


def policy_result(**fields):
    return stage("result", **({
        "outcome": "policy-blocked", "navigationIssued": True, "documentCommitted": False, "documentFinished": False,
        "localPolicyRejection": "additional-top-level-navigation", "observationCutoffMs": 61, "elapsedMs": 3_090,
        "timelineMs": {"loadIssued": 1, "policyRejection": 49},
    } | fields))


def policy_wait_prefix(written, first_permit=(5, 5), **fields):
    permits = permit_series(23_000, (first_permit, (6, 6), (7, 7)))
    return READY + RESERVED + DISPATCH + permits + policy_result(**({
        "observationCutoffMs": 20_001, "observedThroughAtNs": 23_025 * NS_PER_MS, "elapsedMs": written,
        "timelineMs": {"loadIssued": 1, "policyRejection": 19_998},
    } | fields))


def policy_retirement(requested_ns, first_ns, exit_ns, *, commit_ns=None):
    page_ns = 3_001 * NS_PER_MS
    confirmed = commit_ns is not None
    return stage("retirement", elapsedNs=exit_ns, retirementState="confirmed" if confirmed else "unconfirmed",
                 transportQuiesced=confirmed, retirementRequestedAtNs=requested_ns,
                 retirementRequestedAtMs=(requested_ns - page_ns) // NS_PER_MS,
                 retirementFirstPolledAtNs=first_ns, retirementExitPolledAtNs=exit_ns,
                 retirementObservedThroughAtNs=exit_ns, retirementObservedMs=(exit_ns - requested_ns) // NS_PER_MS,
                 retirementCommitAtNs=commit_ns,
                 retirementCommitAtMs=(commit_ns - page_ns) // NS_PER_MS if confirmed else None,
                 transportQuiescedAtNs=exit_ns if confirmed else None,
                 transportQuiescedAtMs=(exit_ns - page_ns) // NS_PER_MS if confirmed else None)


def unbound_retirement(requested_ns, first_ns):
    page_ns = 3_001 * NS_PER_MS
    return stage("retirement", elapsedNs=first_ns, retirementState="unbound", transportQuiesced=True,
                 retirementRequestedAtNs=requested_ns, retirementRequestedAtMs=(requested_ns - page_ns) // NS_PER_MS,
                 retirementObservedThroughAtNs=first_ns, retirementObservedMs=(first_ns - requested_ns) // NS_PER_MS,
                 retirementFirstPolledAtNs=first_ns, transportQuiescedAtNs=first_ns,
                 transportQuiescedAtMs=(first_ns - page_ns) // NS_PER_MS)


class CampaignObserverTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)
        self.observer = self.open_observer()
        self.replies = []
        self.transport = []
        self.deadline = time.monotonic() + 5

    def open_observer(self, name="state.json", *, recover=False):
        return CampaignObserver(TARGETS, IDENTITY, LIMITS, self.directory / name, recover=recover)

    @staticmethod
    def snapshots(*items):
        values = iter(items)

        def copy(destination, _deadline):
            value = next(values)
            if isinstance(value, tuple):
                raw, value = value
                destination.write_bytes(raw)
            if isinstance(value, Exception):
                raise value
            if isinstance(value, bytes):
                destination.write_bytes(value)
                return 0
            return value

        return copy

    def observe(self, name, *snapshots, token=TOKEN):
        return self.observer.observe_and_renew(
            self.snapshots(*snapshots), self.directory / name, self.report, lambda _: token,
            lambda value, _: self.replies.append(value), deadline=self.deadline,
        )

    def reconcile(self, *snapshots, stopped=lambda _: True):
        return self.observer.reconcile_stopped(
            self.snapshots(*snapshots), self.directory / "stopped-first", self.directory / "stopped-second",
            self.report, stopped, deadline=self.deadline,
        )

    def report(self, attempt, state):
        self.transport.append((attempt, state))

    def assert_snapshot_paths(self, name, native, *, invalid=None, verified=b"", token=NEXT_TOKEN,
                              renews=False, partial=False, targets=TARGETS, limits=LIMITS):
        digest = hashlib.sha256(("\n".join(targets) + "\n").encode()).hexdigest()
        identity = IDENTITY | {"targetsSHA256": digest}
        native = native.replace(IDENTITY["targetsSHA256"].encode(), digest.encode())
        verified = verified.replace(IDENTITY["targetsSHA256"].encode(), digest.encode())
        for path in ("live", "stopped", "partial-stop") if partial else ("live", "stopped"):
            with self.subTest(snapshot=name, path=path):
                first = self.directory / f"{name}-{path}"
                second = first.with_suffix(".second")
                state_file = first.with_suffix(".json")
                observer = CampaignObserver(targets, identity, limits, state_file)
                reads, sends, reports = [], [], []

                def report(*event):
                    reports.append(event)

                def read_challenge(_):
                    reads.append(token)
                    return token

                def observe(copy):
                    return observer.observe_and_renew(copy, first, report, read_challenge,
                                                      lambda value, _: sends.append(value), deadline=self.deadline)

                witness = native
                copies = (native, native)
                if path == "partial-stop":
                    partial_copy = native + b'{"event":' if invalid else native[:-5]
                    witness = partial_copy if invalid else native
                    copies = ((partial_copy, 1), *copies)
                copy = self.snapshots(*copies)

                def reconcile(current, source, stopped=lambda _: True):
                    return current.reconcile_stopped(source, first, second, report, stopped, deadline=self.deadline)

                def read():
                    return observe(copy) if path == "live" else reconcile(observer, copy).receipt

                if invalid is None:
                    read()
                    self.assertEqual(observer.observed_prefix, native)
                    self.assertEqual(first.read_bytes(), native)
                    if path != "live":
                        self.assertEqual(second.read_bytes(), native)
                    self.assertEqual(reads, [token] if path == "live" and renews else [])
                    self.assertEqual(sends, reads)
                    continue

                with self.assertRaisesRegex(LedgerObservationUnavailable, invalid):
                    read()
                self.assertEqual(observer.observed_prefix, verified)
                self.assertEqual(reports, [(1, "invalid-ledger")])
                self.assertFalse(first.exists())
                self.assertFalse(second.exists())
                state = json.loads(state_file.read_bytes())
                self.assertTrue(state["disputed"])
                self.assertFalse(state["pending"])
                self.assertEqual(state["verifiedLength"], len(verified))
                self.assertEqual(base64.b64decode(state["witness"]), witness)
                raw_copy, = self.directory.glob(f"{first.name}-copy-*/device.jsonl")
                self.assertEqual(raw_copy.read_bytes(), witness)
                with self.assertRaisesRegex(RuntimeError, "Renewal is closed"):
                    observe(self.snapshots())
                recovered = CampaignObserver(targets, identity, limits, state_file, recover=True)
                with self.assertRaisesRegex(LedgerObservationUnavailable, "Unresolved native copy evidence"):
                    reconcile(recovered, self.snapshots(verified, verified), stopped=lambda _: False)
                self.assertEqual(reads, [])
                self.assertEqual(sends, [])

    def test_one_observation_timeout_recovers_and_renews_after_verified_dispatch(self):
        report = self.observe("poll", TimeoutExpired("copy", 1), READY + RESERVED + DISPATCH)
        self.assertEqual(self.transport, [(1, "copy-timeout"), (2, "complete")])
        self.assertEqual(self.replies, [TOKEN])
        self.assertEqual(report.summary()["byOrdinal"], [
            {"ordinal": 1, "reserved": True, "dispatchConfirmed": True, "result": None, "retirement": None,
             "transportQuiesced": None},
        ])
        self.assertFalse(hasattr(report, "remaining_targets"))

    def test_persistent_loss_prevents_any_more_renewals_and_reconciles_without_replay(self):
        self.observe("initial", READY)
        with self.assertRaises(LedgerObservationUnavailable):
            self.observe("lost", *(TimeoutExpired("copy", 1) for _ in range(3)))
        with self.assertRaises(RuntimeError):
            self.observe("late", READY + RESERVED + DISPATCH)
        self.assertEqual(self.replies, [TOKEN])
        native = READY + RESERVED + DISPATCH + RESULT + RETIRED + stage("reserved", 2)
        reconciled = self.reconcile(native, native)
        self.assertEqual(reconciled.remaining_targets(TARGETS + ("third.invalid",)), ("third.invalid",))
        summary = reconciled.receipt.summary()
        self.assertEqual(summary["reserved"], 2)
        self.assertEqual(summary["dispatchConfirmed"], 1)
        self.assertEqual(summary["reservedWithoutDispatchProof"], 1)
        self.assertEqual(summary["withResult"], 1)
        self.assertEqual(summary["withRetirement"], 1)
        self.assertEqual(summary["byOrdinal"][1]["ordinal"], 2)
        self.assertFalse(summary["byOrdinal"][1]["dispatchConfirmed"])

    def test_torn_tail_then_rewrite_cannot_discard_a_complete_reservation(self):
        torn = READY + RESERVED + DISPATCH[:-5]
        with self.assertRaises(LedgerPrefixChanged):
            self.observe("torn", torn, READY)
        self.assertEqual(self.observer.observed_prefix, READY + RESERVED)
        self.assertFalse(self.replies)
        with self.assertRaises(LedgerPrefixChanged):
            self.reconcile(READY, READY)
        self.assertFalse((self.directory / "stopped-first").exists())

    def test_missing_final_newline_cannot_make_a_reservation_eligible(self):
        with self.assertRaises(LedgerPrefixChanged):
            self.observe("torn-reservation", READY + RESERVED[:-1], READY)
        self.observer = self.open_observer(recover=True)
        with self.assertRaises(LedgerPrefixChanged):
            self.reconcile(READY, READY)
        native = READY + RESERVED
        self.assertEqual(self.reconcile(native, native).remaining_targets(TARGETS), (TARGETS[1],))
        self.assertFalse(self.replies)

    def test_ambiguous_complete_rows_never_authorize_shorter_stopped_recovery(self):
        duplicate = RESERVED.replace(b'"event": "reserved"', b'"event": "reserved", "event": "health"')
        for index, suffix in enumerate((b"{bad-json}\n" + RESERVED, duplicate)):
            state_name = f"ambiguous-{index}.json"
            self.observer = self.open_observer(state_name)
            with self.assertRaises(LedgerObservationUnavailable):
                self.observe(f"ambiguous-{index}", READY + suffix)
            self.observer = self.open_observer(state_name, recover=True)
            with self.assertRaises(LedgerObservationUnavailable):
                self.reconcile(READY, READY)
        self.assertFalse(self.replies)

    def test_failed_device_copies_preserve_complete_reservations(self):
        for index, transfer_error in enumerate((17, TimeoutExpired("copy", 1))):
            with self.subTest(transfer_error=transfer_error):
                self.observer = self.open_observer(f"failed-{index}.json")
                with self.assertRaises(LedgerPrefixChanged):
                    self.observe("failed", (READY + RESERVED, transfer_error), READY)
                self.assertEqual(self.observer.observed_prefix, READY + RESERVED)
        self.assertFalse(self.replies)

    def test_stopped_reads_cannot_accept_a_changing_ledger(self):
        with self.assertRaises(RuntimeError):
            self.reconcile(READY, READY + RESERVED)
        self.assertFalse(self.replies)

    def test_new_observer_retains_prior_prefix_and_an_abandoned_empty_prefix(self):
        with self.assertRaises(LedgerObservationUnavailable):
            self.observe("empty", *(TimeoutExpired("copy", 1) for _ in range(3)))
        self.observer = self.open_observer(recover=True)
        self.assertEqual(self.observer.observed_prefix, b"")
        with self.assertRaises(RuntimeError):
            self.observe("resume-empty", READY)
        self.observer = self.open_observer("with-prefix.json")
        with self.assertRaises(LedgerObservationUnavailable):
            self.observe("torn", *((READY + RESERVED + b"{") for _ in range(3)))
        self.observer = self.open_observer("with-prefix.json", recover=True)
        with self.assertRaises(RuntimeError):
            self.observe("resume-prefix", READY)
        with self.assertRaises(LedgerPrefixChanged):
            self.reconcile(READY, READY)
        self.assertFalse(self.replies)

    def test_checkpoint_and_active_phone_never_allow_a_follow_up(self):
        native = START + row("checkpoint", elapsedMs=30_000, reason="run-permit-expired",
                             budgetStopReason="run-permit-expired", reservedCount=0)
        self.assertEqual(self.observe("terminal", native).checkpoint, "run-permit-expired")
        self.assertFalse(self.replies)
        with self.assertRaises(RuntimeError):
            self.reconcile(native, native, stopped=lambda _: False)

    def test_a_rewritten_prefix_is_rejected_even_in_a_partial_copy(self):
        self.observe("initial", READY + RESERVED)
        changed = READY + RESERVED.replace(b"owned-key-1", b"other-key-1") + DISPATCH[:10]
        with self.assertRaises(LedgerPrefixChanged):
            self.observe("changed", changed)
        self.assertEqual(self.replies, [TOKEN])

    def test_invalid_or_legacy_token_does_not_renew(self):
        with self.assertRaises(RuntimeError):
            self.observe("legacy", READY, token=b"run\n")
        self.assertFalse(self.replies)

    def test_new_challenge_requires_a_snapshot_that_covers_its_native_row(self):
        self.observe("start", START)
        self.observe("first", READY)
        self.observe("stale", READY, token=NEXT_TOKEN)
        self.observe("covered", READY + RESERVED + challenge(NEXT_TOKEN, issued=26_000), token=NEXT_TOKEN)
        self.assertEqual(self.replies, [TOKEN, NEXT_TOKEN])

    def test_foreign_initial_snapshot_never_becomes_the_verified_prefix(self):
        with self.assertRaises(LedgerObservationUnavailable):
            self.observe("foreign", READY.replace(b"owned-fixture", b"foreign-fixture"))
        self.assertEqual(self.observer.observed_prefix, b"")
        self.assertFalse((self.directory / "foreign").exists())
        self.assertEqual(self.reconcile(READY, READY).remaining_targets(TARGETS), TARGETS)

    def test_invalid_row_after_reservation_preserves_the_valid_prefix(self):
        observed = READY + RESERVED
        with self.assertRaises(LedgerObservationUnavailable):
            self.observe("invalid-tail", observed + b"{bad-json}\n")
        self.assertEqual(self.observer.observed_prefix, observed)
        self.assertFalse((self.directory / "invalid-tail").exists())
        self.assertFalse(self.replies)

    def test_overlarge_snapshot_retains_reservation_and_blocks_shorter_reconciliation(self):
        observed = READY + RESERVED
        with patch("access_campaign_observer.MAX_SNAPSHOT_BYTES", len(observed) + 8):
            with self.assertRaises(LedgerObservationUnavailable):
                self.observe("large", observed + b"{" * 32)
        self.observer = self.open_observer(recover=True)
        self.assertEqual(self.observer.observed_prefix, observed)
        with self.assertRaises(LedgerObservationUnavailable):
            self.reconcile(READY, READY)
        self.assertFalse(self.replies)

    def test_oversized_foreign_prefix_cannot_disprove_an_unread_reservation(self):
        self.observe("bound", READY)
        foreign = READY.replace(b"owned-fixture", b"foreign-fixture")
        with patch("access_campaign_observer.MAX_SNAPSHOT_BYTES", len(foreign)):
            with self.assertRaises(LedgerPrefixChanged):
                self.observe("oversized-mixed", foreign + RESERVED)
        self.observer = self.open_observer(recover=True)
        with self.assertRaises(LedgerObservationUnavailable):
            self.reconcile(READY, READY)
        self.assertEqual(self.replies, [TOKEN])

    def test_report_failure_preserves_the_valid_complete_reservation(self):
        def fail_report(*_):
            raise KeyboardInterrupt()

        observed = READY + RESERVED
        with self.assertRaises(LedgerObservationUnavailable):
            self.observer.observe_and_renew(self.snapshots((observed, 125)), self.directory / "report-error",
                                           fail_report, lambda _: TOKEN, lambda token, _: self.replies.append(token),
                                           deadline=self.deadline)
        self.observer = self.open_observer(recover=True)
        self.assertEqual(self.observer.observed_prefix, observed)
        with self.assertRaises(LedgerPrefixChanged):
            self.reconcile(READY, READY)
        self.assertFalse(self.replies)

    def test_interrupted_transport_preserves_rows_before_exiting(self):
        observed = READY + RESERVED
        with self.assertRaises(LedgerObservationUnavailable):
            self.observe("interrupted", (observed, KeyboardInterrupt()))
        self.observer = self.open_observer(recover=True)
        self.assertEqual(self.observer.observed_prefix, observed)
        self.assertFalse(self.replies)

    def test_same_grant_fork_remains_disputed_after_restart(self):
        old = GRANTED + healthy(elapsedMs=25_000)
        different = GRANTED + healthy(elapsedMs=25_001) + stage("reserved", elapsedMs=25_002)
        self.observe("old", old)
        with self.assertRaises(LedgerPrefixChanged):
            self.observe("different", different)
        self.observer = self.open_observer(recover=True)
        with self.assertRaises(LedgerObservationUnavailable):
            self.reconcile(old, old)
        self.assertEqual(self.replies, [TOKEN])

    def test_crash_with_unexamined_copy_blocks_automatic_recovery(self):
        with patch("access_campaign_observer.bounded_snapshot", side_effect=KeyboardInterrupt()):
            with self.assertRaises(KeyboardInterrupt):
                self.observe("unexamined", READY + RESERVED)
        self.observer = self.open_observer(recover=True)
        with self.assertRaises(LedgerObservationUnavailable):
            self.reconcile(READY, READY)
        self.assertFalse(self.replies)

    def test_foreign_copy_does_not_dispute_the_existing_bound_grant(self):
        self.observe("bound", READY + RESERVED)
        with self.assertRaises(LedgerPrefixChanged):
            self.observe("foreign", READY.replace(b"owned-fixture", b"foreign-fixture"))
        self.observer = self.open_observer(recover=True)
        observed = READY + RESERVED
        self.assertEqual(self.reconcile(observed, observed).remaining_targets(TARGETS), (TARGETS[1],))

    def test_foreign_header_cannot_hide_a_reservation_with_current_identity(self):
        self.observe("bound", READY)
        mixed = READY.replace(b"owned-fixture", b"foreign-fixture") + RESERVED
        with self.assertRaises(LedgerPrefixChanged):
            self.observe("mixed", mixed)
        self.observer = self.open_observer(recover=True)
        with self.assertRaises(LedgerObservationUnavailable):
            self.reconcile(READY, READY)

    def test_pending_copy_is_directory_synced_before_transport(self):
        synced_directories = []
        real_fsync = os.fsync

        def record_sync(fd):
            if stat.S_ISDIR(os.fstat(fd).st_mode):
                synced_directories.append(True)
            real_fsync(fd)

        def transport(destination, _deadline):
            self.assertTrue(synced_directories)
            destination.write_bytes(READY)
            return 0

        with patch("access_campaign_observer.os.fsync", side_effect=record_sync):
            self.observer.observe_and_renew(transport, self.directory / "directory-sync", self.report, lambda _: TOKEN,
                                            lambda value, _: self.replies.append(value), deadline=self.deadline)
        self.assertEqual(self.replies, [TOKEN])

    def test_new_attempt_never_reuses_a_stale_transport_file(self):
        first = READY + RESERVED
        with self.assertRaises(LedgerObservationUnavailable):
            self.observe("cached", (first, 17), 0, 0)
        # A reconstructed observer only reconciles; each attempted copy starts on a fresh path.
        self.observer = self.open_observer(recover=True)
        with self.assertRaises(LedgerObservationUnavailable):
            self.reconcile(0, 0, 0)
        self.assertFalse(self.replies)
        self.assertEqual(sum(1 for file in self.directory.glob("cached-copy-*/device.jsonl") if file.read_bytes() == first), 1)

    def test_cohort_order_and_all_exact_limits_are_required(self):
        with self.assertRaises(ValueError):
            CampaignObserver(tuple(reversed(TARGETS)), IDENTITY, LIMITS, self.directory / "invalid.json")
        for key, value in LIMITS.fields().items():
            fields = LIMITS.fields()
            fields[key] = value + 1
            with self.subTest(key=key), self.assertRaises(ValueError):
                read_campaign_receipt(row("start", **fields), TARGETS, IDENTITY, LIMITS)
            del fields[key]
            with self.subTest(missing=key), self.assertRaises(ValueError):
                read_campaign_receipt(row("start", **fields), TARGETS, IDENTITY, LIMITS)

    def test_canonical_dns_alias_cannot_replay_a_consumed_name(self):
        node = READY + RESERVED
        reconciled = self.reconcile(node, node)
        self.assertEqual(reconciled.remaining_targets(("FIRST.INVALID.", "first.invalid", "second.invalid")),
                         ("second.invalid",))
        for alias in ("first.invalid.", "FIRST.INVALID"):
            targets = (TARGETS[0], alias)
            digest = hashlib.sha256(("\n".join(targets) + "\n").encode()).hexdigest()
            with self.assertRaisesRegex(ValueError, "Invalid frozen cohort"):
                read_campaign_receipt(START, targets, IDENTITY | {"targetsSHA256": digest}, LIMITS)

    def test_stopped_reconciliation_cannot_finish_after_deadline(self):
        self.deadline = 1.0
        current = [0.0]
        status_checks = [True, True]

        def stopped(deadline):
            self.assertEqual(deadline, 1.0)
            result = status_checks.pop()
            if not status_checks:
                current[0] = 2.0
            return result

        with patch("access_campaign_observer.monotonic", side_effect=lambda: current[0]):
            with self.assertRaises(LedgerPollDeferred):
                self.reconcile(READY, READY, stopped=stopped)
        self.assertFalse(self.replies)

    def test_outcome_does_not_create_dispatch_and_repeats_are_rejected(self):
        impossible = stage("result", outcome="finished", navigationIssued=False, documentCommitted=False, documentFinished=False)
        timeout = stage("result", outcome="timeout", navigationIssued=False, documentCommitted=False, documentFinished=False)
        for invalid in (READY + RESERVED + RESULT, READY + RESERVED + impossible, READY + RESERVED + RESERVED,
                        READY + RESERVED + stage("reserved", 2), READY + RESERVED + DISPATCH + RETIRED,
                        READY + RESERVED + timeout):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                read_campaign_receipt(invalid, TARGETS, IDENTITY, LIMITS)

    def test_unbound_result_and_policy_after_finish_keep_independent_fields(self):
        native = READY + RESERVED + stage("result", outcome="failed", navigationIssued=False,
                                          documentCommitted=False, documentFinished=False)
        native += stage("retirement", retirementState="unbound", transportQuiesced=True,
                        retirementRequestedAtMs=100, transportQuiescedAtMs=325, retirementObservedMs=225,
                        retirementFirstPolledAtNs=3_326 * NS_PER_MS)
        summary = read_campaign_receipt(native, TARGETS, IDENTITY, LIMITS).summary()
        self.assertEqual(summary["reservedWithoutDispatchProof"], 1)
        self.assertEqual(summary["withResult"], 1)
        self.assertEqual(summary["byOrdinal"][0]["retirement"], "unbound")
        self.assertEqual(summary["byOrdinal"][0]["actualProtocol"], "unbound")

        native = READY + RESERVED + DISPATCH + stage("result", outcome="policy-blocked", navigationIssued=True,
            documentCommitted=True, documentFinished=True, navigationPolicy="additional-top-level-navigation",
            localPolicyRejection="additional-top-level-navigation",
            serverRedirectCount=1, timelineMs={"loadIssued": 1, "documentCommit": 2, "documentFinish": 200,
                                               "policyRejection": 250},
            observationCutoffMs=20_001, elapsedMs=24_000,
            observedAfterCutoff={"stopReason": "external-stop", "stopAtMs": 20002})
        observed = read_campaign_receipt(native, TARGETS, IDENTITY, LIMITS).summary()["byOrdinal"][0]
        self.assertTrue(observed["documentFinished"])
        self.assertEqual(observed["navigationPolicy"], "additional-top-level-navigation")
        self.assertEqual(observed["serverRedirectCount"], 1)
        self.assertEqual(observed["observationCutoffMs"], 20_001)
        self.assertEqual(observed["timelineMs"]["documentFinish"], 200)
        self.assertEqual(observed["observedAfterCutoff"]["stopAtMs"], 20002)

    def test_bound_load_rejection_cannot_claim_an_unbound_retirement(self):
        result = stage("result", outcome="failed", navigationIssued=False, documentCommitted=False,
                       documentFinished=False, localLoadDisposition="load-not-accepted")
        native = READY + RESERVED + result
        unbound = stage("retirement", retirementState="unbound", transportQuiesced=True, **WITNESSES)
        with self.assertRaisesRegex(ValueError, "Native retirement state disagrees"):
            read_campaign_receipt(native + unbound, TARGETS, IDENTITY, LIMITS)
        retired = stage("retirement", retirementState="confirmed", transportQuiesced=True, **TIMEOUT_WITNESSES)
        receipt = read_campaign_receipt(native + retired + stage("reserved", 2), TARGETS, IDENTITY, LIMITS)
        self.assertFalse(receipt.attempts[0].dispatch_confirmed)
        self.assertEqual(receipt.attempts[0].evidence["localLoadDisposition"], "load-not-accepted")
        self.assertEqual(receipt.attempts[0].retirement, "confirmed")
        fake_original = stage("retirement", retirementState="confirmed", transportQuiesced=True, **WITNESSES,
                              originalNavigationAfterClose={"timelineMs": {"documentCommit": 100}})
        with self.assertRaisesRegex(ValueError, "Invalid original WebKit callbacks"):
            read_campaign_receipt(native + fake_original, TARGETS, IDENTITY, LIMITS)

    def test_native_halt_or_exhausted_budget_closes_renewal_before_checkpoint(self):
        stopped = READY + RESERVED + DISPATCH + stage("result", outcome="stopped", navigationIssued=True,
            documentCommitted=False, documentFinished=False, stopReason="external-stop")
        drained = GRANTED + healthy(chargedBytes=LIMITS.bytes)
        for index, native in enumerate((stopped, drained)):
            self.observer = self.open_observer(f"halted-{index}.json")
            self.assertTrue(self.observe(f"halted-{index}", native).halted)
        self.assertFalse(self.replies)

    def test_native_counters_are_required_monotonic_and_capped(self):
        prefix = GRANTED + healthy(chargedBytes=20)
        self.assertFalse(read_campaign_receipt(prefix, TARGETS, IDENTITY, LIMITS).halted)
        rows = [
            stage("reserved", elapsedMs=999, chargedBytes=20),
            stage("reserved", chargedBytes=19),
            stage("reserved", chargedBytes=20, reservedBytes=LIMITS.bytes - 19),
            stage("reserved", chargedBytes=20).replace(b', "reservedBytes": 0', b""),
        ]
        for invalid in rows:
            with self.subTest(invalid=invalid), self.assertRaisesRegex(ValueError, "Invalid native budget observation"):
                read_campaign_receipt(prefix + invalid, TARGETS, IDENTITY, LIMITS)

    def test_failed_initial_health_or_retirement_never_renews(self):
        failed_health = GRANTED + healthy(outcome="failed", lastHTTPStatus=503,
                                           documentCommitted=False, documentFinished=False)
        failed_retirement = READY + RESERVED + DISPATCH + RESULT + stage(
            "retirement", retirementState="unconfirmed", transportQuiesced=True,
            elapsedMs=13_150, **(WITNESSES | {"retirementCommitAtMs": None, "retirementObservedMs": 10_000}))
        for index, native in enumerate((failed_health, failed_retirement)):
            self.observer = self.open_observer(f"terminal-check-{index}.json")
            self.assertTrue(self.observe(f"terminal-check-{index}", native).halted)
        self.assertFalse(self.replies)

    def test_initial_health_requires_all_three_navigation_stages(self):
        for index, field in enumerate(("navigationIssued", "documentCommitted", "documentFinished")):
            self.observer = self.open_observer(f"missing-health-{index}.json")
            contradictory = GRANTED + healthy(**{field: False})
            with self.assertRaises(LedgerObservationUnavailable):
                self.observe(f"missing-health-{index}", contradictory)
        self.assertFalse(self.replies)

    def test_last_witnessed_grant_does_not_authorize_late_reservation(self):
        expired = GRANTED + healthy(elapsedMs=60_000)
        self.assertTrue(self.observe("expired", expired).halted)
        with self.assertRaises(ValueError):
            read_campaign_receipt(expired + stage("reserved", elapsedMs=60_001), TARGETS, IDENTITY, LIMITS)
        self.assertFalse(self.replies)

    def test_initial_grant_uses_issuance_not_late_ledger_append(self):
        native = (START + challenge(INITIAL_TOKEN, appended=1_000) + challenge(TOKEN, issued=2_000)
                  + healthy(elapsedMs=30_500, pageStartedAtNs=2_001 * NS_PER_MS))
        self.assertTrue(self.observe("initial-expiry", native).halted)
        with self.assertRaises(ValueError):
            read_campaign_receipt(native + stage("reserved", elapsedMs=30_600), TARGETS, IDENTITY, LIMITS)
        self.assertFalse(self.replies)

    def test_initial_health_cannot_claim_observation_before_the_grant_confirmation(self):
        prefix = ARMED + challenge(TOKEN, issued=24_999, appended=25_000)
        before = healthy(elapsedMs=25_001, pageStartedAtNs=24_999 * NS_PER_MS - 200 * NS_PER_MS)
        with self.assertRaisesRegex(ValueError, "Unexpected native health check"):
            read_campaign_receipt(prefix + before, TARGETS, IDENTITY, LIMITS)
        too_short = healthy(elapsedMs=25_001, pageStartedAtNs=25_000 * NS_PER_MS, observationCutoffMs=1,
            observedThroughAtNs=25_001 * NS_PER_MS,
            timelineMs={"loadIssued": 1, "firstVisibleHTTPResponse": 1, "documentCommit": 1, "documentFinish": 1})
        with self.assertRaisesRegex(ValueError, "Missing native retirement start"):
            read_campaign_receipt(prefix + too_short, TARGETS, IDENTITY, LIMITS)
        accepted = healthy(elapsedMs=25_200, pageStartedAtNs=25_000 * NS_PER_MS)
        self.assertFalse(read_campaign_receipt(prefix + accepted, TARGETS, IDENTITY, LIMITS).halted)

    def test_health_admission_requires_a_first_response_witness_for_the_200(self):
        fake = healthy(timelineMs={"loadIssued": 1, "documentCommit": 5, "documentFinish": 7})
        fake = fake.replace(b'"firstVisibleHTTPStatus": 200, ', b"")
        with self.assertRaisesRegex(ValueError, "Frozen HTTP status and response milestone disagree"):
            read_campaign_receipt(GRANTED + fake, TARGETS, IDENTITY, LIMITS)
        reordered = healthy(timelineMs={"loadIssued": 1, "firstVisibleHTTPResponse": 12,
                                        "documentCommit": 5, "documentFinish": 7})
        with self.assertRaisesRegex(ValueError, "Frozen HTTP status and response milestone disagree"):
            read_campaign_receipt(GRANTED + reordered, TARGETS, IDENTITY, LIMITS)

    def test_renewed_window_preserves_submillisecond_admission_precision(self):
        issued_ns = 10_000 * NS_PER_MS + 800_000
        native = (GRANTED + challenge(NEXT_TOKEN, issued_ns=issued_ns)
                  + healthy(elapsedMs=11_000, pageStartedAtNs=10_002 * NS_PER_MS)
                  + challenge(TOKEN.replace(b"f48", b"f28"), issued=20_000))
        before = stage("reserved", admittedAtNs=40_000 * NS_PER_MS + 300_000, elapsedMs=40_001)
        receipt = read_campaign_receipt(native + before, TARGETS, IDENTITY, LIMITS)
        self.assertEqual(len(receipt.attempts), 1)
        self.assertTrue(receipt.halted)
        at_expiry = stage("reserved", admittedAtNs=issued_ns + LIMITS.permit_window_ms * NS_PER_MS, elapsedMs=40_001)
        with self.assertRaisesRegex(ValueError, "Native reservation"):
            read_campaign_receipt(native + at_expiry, TARGETS, IDENTITY, LIMITS)

    def test_renewal_cannot_have_been_issued_before_the_prior_row(self):
        armed = START + challenge(INITIAL_TOKEN, appended=1_000)
        self.assertFalse(read_campaign_receipt(armed, TARGETS, IDENTITY, LIMITS).halted)
        with self.assertRaisesRegex(ValueError, "Native challenge issuance was outside the active window"):
            read_campaign_receipt(armed + challenge(TOKEN, issued=500, appended=2_000), TARGETS, IDENTITY, LIMITS)

    def test_mixed_traffic_rows_never_authorize_a_renewal(self):
        renewal = challenge(NEXT_TOKEN, issued=2_000)
        for label, prefix, valid in (("permit", READY, renewal), ("reserved", READY + renewal, RESERVED),
                                     ("dispatch", READY + renewal + RESERVED, DISPATCH)):
            self.observer = self.open_observer(f"{label}-state.json")
            corrupt = json.loads(valid) | {"stopReason": "external-stop"}
            with self.subTest(event=label), self.assertRaisesRegex(LedgerObservationUnavailable, "Unexpected evidence"):
                self.observe(f"mixed-{label}", prefix + (json.dumps(corrupt) + "\n").encode(), token=NEXT_TOKEN)
        self.assertFalse(self.replies)

    def test_batch_deadline_applies_even_when_the_native_lease_remains_live(self):
        limits = CampaignLimits(LIMITS.targets, 25, LIMITS.bytes, LIMITS.permit_window_ms)
        native = row("start", elapsedMs=1, **limits.fields()) + READY[len(START):]
        on_time = stage("reserved", admittedAtNs=24_999 * NS_PER_MS, elapsedMs=25_001)
        at_deadline = stage("reserved", admittedAtNs=25_000 * NS_PER_MS, elapsedMs=25_001)
        receipt = read_campaign_receipt(native + on_time, TARGETS, IDENTITY, limits)
        self.assertEqual(len(receipt.attempts), 1)
        self.assertTrue(receipt.halted)
        with self.assertRaisesRegex(ValueError, "Native reservation"):
            read_campaign_receipt(native + at_deadline, TARGETS, IDENTITY, limits)

    def test_late_reservation_write_does_not_erase_an_on_time_admission(self):
        native = READY + stage("reserved", admittedAtNs=29_999 * NS_PER_MS, elapsedMs=30_001)
        self.assertTrue(self.observe("late-reservation-write", native).halted)
        self.assertEqual(self.reconcile(native, native).remaining_targets(TARGETS), (TARGETS[1],))
        self.assertFalse(self.replies)

    def test_initial_health_cannot_claim_finish_with_earlier_policy_rejection(self):
        invalid = GRANTED + healthy(localPolicyRejection="download-navigation")
        with self.assertRaises(ValueError):
            read_campaign_receipt(invalid, TARGETS, IDENTITY, LIMITS)

    def test_last_authorized_retirement_without_probe_closes_renewal(self):
        terminal = (READY + RESERVED + DISPATCH + RESULT + RETIRED
            + stage("reserved", 2) + stage("dispatch", 2)
            + stage("result", 2, outcome="finished", navigationIssued=True, documentCommitted=True, documentFinished=True)
            + stage("retirement", 2, retirementState="confirmed", transportQuiesced=True, **WITNESSES))
        self.assertTrue(self.observe("terminal-retirement", terminal).halted)
        self.assertFalse(self.replies)
        complete = row("checkpoint", reason="target-limit", reservedCount=2)
        self.assertEqual(read_campaign_receipt(terminal + complete, TARGETS, IDENTITY, LIMITS).checkpoint, "target-limit")

    def test_checkpoint_poll_stop_requires_a_reachable_native_poll(self):
        active = READY + RESERVED + DISPATCH + RESULT
        unconfirmed = stage("retirement", retirementState="unconfirmed", transportQuiesced=True, elapsedMs=13_102,
                            **(WITNESSES | {"retirementCommitAtMs": None, "retirementObservedMs": 10_000}))
        draining = stage("retirement", retirementState="confirmed", transportQuiesced=False, elapsedMs=13_102,
                         **(WITNESSES | {"transportQuiescedAtMs": None, "retirementObservedMs": 10_000}))
        between_targets = row("checkpoint", reason="external-stop", budgetStopReason="external-stop",
                              reservedCount=1, budgetStopAtNs=3_600 * NS_PER_MS + 1)
        self.assertEqual(read_campaign_receipt(active + RETIRED + between_targets, TARGETS, IDENTITY, LIMITS)
                         .checkpoint, "external-stop")

        one_target, read_one_target = campaign_fixture(TARGETS[:1])
        one_target += RESERVED + DISPATCH + RESULT + RETIRED
        targets = TARGETS + ("third.invalid", "fourth.invalid")
        failed_preparation, read_preparation = campaign_fixture(targets)
        for index, host in enumerate(targets[:3], 1):
            key = {"ordinal": index, "host": host, "attempt": f"owned-key-{index}"}
            failed_preparation += row("reserved", **key)
            failed_preparation += row("result", **key, outcome="failed", navigationIssued=False,
                                      documentCommitted=False, documentFinished=False)
            failed_preparation += row("retirement", **key, retirementState="unbound", transportQuiesced=True,
                                      **(WITNESSES | {"retirementCommitAtMs": None, "transportQuiescedAtMs": 299}))

        def read(raw):
            return read_campaign_receipt(raw, TARGETS, IDENTITY, LIMITS)

        cases = (
            ("health-check-failed", GRANTED + healthy(lastHTTPStatus=503), 0, read),
            ("target-limit", one_target, 1, read_one_target),
            ("retirement-unconfirmed", active + unconfirmed, 1, read),
            ("transport-quiescence-unconfirmed", active + draining, 1, read),
            ("repeated-preparation-failure", failed_preparation, 3, read_preparation),
        )
        for expected, prefix, count, parse in cases:
            with self.subTest(terminal=expected):
                completed = row("checkpoint", reason=expected, reservedCount=count)
                self.assertEqual(parse(prefix + completed).checkpoint, expected)
                for reason in ("external-stop", "node-revision-changed", "transport-lost", "run-control-unavailable"):
                    forged = row("checkpoint", reason=reason, budgetStopReason=reason, reservedCount=count)
                    with self.subTest(stop=reason), self.assertRaisesRegex(ValueError, "unwitnessed poll stop"):
                        parse(prefix + forged)

    def test_contradictory_checkpoint_cannot_clear_a_stopped_cohort(self):
        for reason in ("target-limit", "repeated-preparation-failure", "three-no-http-timeouts",
                       "health-check-failed", "dispatch-ledger-failed", "unknown"):
            recorded = START + row("checkpoint", reason=reason, reservedCount=0)
            with self.subTest(reason=reason), self.assertRaisesRegex(ValueError, "Invalid native checkpoint"):
                read_campaign_receipt(recorded, TARGETS, IDENTITY, LIMITS)
        early_expiry = ARMED + row("checkpoint", reason="run-permit-expired", budgetStopReason="run-permit-expired",
                                   reservedCount=0)
        with self.assertRaisesRegex(ValueError, "Invalid native checkpoint"):
            read_campaign_receipt(early_expiry, TARGETS, IDENTITY, LIMITS)
        failed = GRANTED + healthy(lastHTTPStatus=503) + row("checkpoint", reason="health-check-failed", reservedCount=0)
        self.assertEqual(read_campaign_receipt(failed, TARGETS, IDENTITY, LIMITS).checkpoint, "health-check-failed")

    def test_checkpoint_uses_only_one_guard_before_the_next_reservation(self):
        for count, prefix, start in ((0, READY, 2_000), (1, READY + RESERVED + DISPATCH + RESULT + RETIRED, 3_700)):
            renewal = challenge(NEXT_TOKEN, issued=start, appended=start + 1)
            for reason in ("external-stop", "node-revision-changed", "run-control-unavailable", "transport-lost"):
                with self.subTest(reserved=count, stop=reason):
                    stop = row("checkpoint", reason=reason, budgetStopReason=reason, reservedCount=count,
                               budgetStopAtNs=(start + 1) * NS_PER_MS)
                    for renewed, valid in ((False, reason != "transport-lost"), (True, reason == "run-control-unavailable")):
                        native = prefix + (renewal if renewed else b"") + stop
                        if valid:
                            self.assertEqual(read_campaign_receipt(native, TARGETS, IDENTITY, LIMITS).checkpoint, reason)
                        else:
                            with self.assertRaisesRegex(ValueError, "unwitnessed poll stop"):
                                read_campaign_receipt(native, TARGETS, IDENTITY, LIMITS)
            second = challenge(TOKEN.replace(b"f48", b"f38"), issued=start + 2)
            with self.assertRaisesRegex(ValueError, "No native poll available for challenge renewal"):
                read_campaign_receipt(prefix + renewal + second, TARGETS, IDENTITY, LIMITS)
            reserved = read_campaign_receipt(prefix + renewal + stage("reserved", count + 1), TARGETS, IDENTITY, LIMITS)
            self.assertEqual(len(reserved.attempts), count + 1)
            expired = row("checkpoint", reason="run-permit-expired", budgetStopReason="run-permit-expired",
                          reservedCount=count, budgetStopAtNs=30_005 * NS_PER_MS, elapsedMs=30_006)
            self.assertEqual(read_campaign_receipt(prefix + renewal + expired, TARGETS, IDENTITY, LIMITS)
                             .checkpoint, "run-permit-expired")

    def test_final_guard_poll_stop_follows_the_pause_and_any_permit_row(self):
        native, read = three_timeout_fixture()
        paused = row("dispatch-paused", reason="three-no-http-timeouts", reservedCount=3, elapsedMs=10_005,
                     pausedAtNs=10_000 * NS_PER_MS)
        permit = challenge(NEXT_TOKEN, issued=10_007, appended=10_012)
        for prefix, reason, too_early, earliest in (
                (native + paused, "external-stop", 10_001, 10_005),
                (native + paused, "run-control-unavailable", 10_001, 10_005),
                (native + paused + permit, "run-control-unavailable", 10_008, 10_012)):
            fields = {"reason": "three-no-http-timeouts", "reservedCount": 3, "budgetStopReason": reason}
            with self.subTest(stop=reason):
                with self.assertRaisesRegex(ValueError, "Native poll stop precedes the preceding row"):
                    read(prefix + row("checkpoint", **fields, budgetStopAtNs=too_early * NS_PER_MS))
                result = read(prefix + row("checkpoint", **fields, budgetStopAtNs=earliest * NS_PER_MS))
                self.assertEqual(result.checkpoint, "three-no-http-timeouts")

    def test_third_settled_timeout_has_no_poll_until_the_pause_is_recorded(self):
        native, read = three_timeout_fixture()
        with self.assertRaisesRegex(ValueError, "No native poll available for challenge renewal"):
            read(native + challenge(NEXT_TOKEN, issued=9_000))
        active, retirement, _ = native.rsplit(b"\n", 2)
        during = challenge(NEXT_TOKEN, issued=5_325, appended=5_330)
        after_pause = challenge(TOKEN.replace(b"f48", b"f38"), issued=10_007)
        final = healthy(phase="after-three-no-http-timeouts")
        receipt = read(active + b"\n" + during + retirement + b"\n" + PAUSED + after_pause + final)
        self.assertEqual(len(receipt.attempts), 3)
        expired = row("checkpoint", reason="run-permit-expired", budgetStopReason="run-permit-expired",
                      reservedCount=3, elapsedMs=30_000)
        self.assertEqual(read(native + expired).checkpoint, "run-permit-expired")

    def test_incomplete_attempt_can_be_reconciled_only_without_a_native_checkpoint(self):
        native = READY + RESERVED
        contradictory = native + row("checkpoint", reason="external-stop", budgetStopReason="external-stop", reservedCount=1)
        with self.assertRaisesRegex(ValueError, "Invalid native checkpoint"):
            read_campaign_receipt(contradictory, TARGETS, IDENTITY, LIMITS)
        self.assertEqual(self.reconcile(native, native).remaining_targets(TARGETS), (TARGETS[1],))

    def test_checkpoint_stop_preserves_order_and_preprobe_reachability(self):
        for reason in ("transport-lost", "byte-limit", "metering-failure", "run-control-unavailable",
                       "external-stop", "node-revision-changed"):
            stopped = row("checkpoint", reason=reason, budgetStopReason=reason, reservedCount=0)
            with self.subTest(reason=reason), self.assertRaisesRegex(ValueError, "Invalid native checkpoint stop"):
                read_campaign_receipt(START + stopped, TARGETS, IDENTITY, LIMITS)

        checkpoint = {"reason": "external-stop", "budgetStopReason": "external-stop",
                      "reservedCount": 0, "elapsedMs": 30_001}
        for instant in (None, 20 * NS_PER_MS, 30_000 * NS_PER_MS):
            stopped = row("checkpoint", **checkpoint, budgetStopAtNs=instant)
            with self.subTest(instant=instant), self.assertRaisesRegex(ValueError, "Invalid native checkpoint stop"):
                read_campaign_receipt(READY + stopped, TARGETS, IDENTITY, LIMITS)
        timely = row("checkpoint", **checkpoint, budgetStopAtNs=30_000 * NS_PER_MS - 1)
        self.assertEqual(read_campaign_receipt(READY + timely, TARGETS, IDENTITY, LIMITS).checkpoint, "external-stop")

    def test_two_post_grant_permits_require_initial_probe_evidence(self):
        stop = row("checkpoint", reason="external-stop", budgetStopReason="external-stop",
                   budgetStopAtNs=2_000 * NS_PER_MS, elapsedMs=2_001, reservedCount=0)
        self.assertEqual(read_campaign_receipt(GRANTED + stop, TARGETS, IDENTITY, LIMITS).checkpoint, "external-stop")
        traffic = row("checkpoint", reason="external-stop", budgetStopReason="external-stop",
                      budgetStopAtNs=2_000 * NS_PER_MS, elapsedMs=2_001, reservedCount=0, chargedBytes=100)
        with self.assertRaisesRegex(ValueError, "Invalid native checkpoint"):
            read_campaign_receipt(GRANTED + traffic, TARGETS, IDENTITY, LIMITS)
        entry_guard = GRANTED + challenge(NEXT_TOKEN, issued=7)
        with self.assertRaisesRegex(ValueError, "Invalid native checkpoint"):
            read_campaign_receipt(entry_guard + stop, TARGETS, IDENTITY, LIMITS)
        publish_failed = row("checkpoint", reason="run-control-unavailable", budgetStopReason="run-control-unavailable",
                             budgetStopAtNs=8 * NS_PER_MS, elapsedMs=9, reservedCount=0)
        self.assertEqual(read_campaign_receipt(entry_guard + publish_failed, TARGETS, IDENTITY, LIMITS)
                         .checkpoint, "run-control-unavailable")
        with self.assertRaisesRegex(ValueError, "Invalid native checkpoint"):
            pending_read = GRANTED + challenge(NEXT_TOKEN, issued=7, reservedBytes=64)
            # EOF released the reservation without charging the read.
            read_campaign_receipt(pending_read + publish_failed, TARGETS, IDENTITY, LIMITS)
        running = entry_guard + challenge(TOKEN.replace(b"f48", b"f38"), issued=9)
        with self.assertRaisesRegex(ValueError, "Invalid native checkpoint"):
            read_campaign_receipt(running + stop, TARGETS, IDENTITY, LIMITS)
        with self.assertRaisesRegex(ValueError, "Native challenge renewal is outside the health probe interval"):
            read_campaign_receipt(running + healthy(), TARGETS, IDENTITY, LIMITS)
        receipt = read_campaign_receipt(running + healthy(pageStartedAtNs=8 * NS_PER_MS) + stop,
                                        TARGETS, IDENTITY, LIMITS)
        self.assertEqual(receipt.checkpoint, "external-stop")

    def test_probe_permit_issuance_and_write_must_fit_the_same_interval(self):
        cases = (
            ("entry write at admission", ((7, 8),), True),
            ("opening guard ends at preparation", ((10, 14),), True),
            ("entry write after admission", ((7, 9),), False),
            ("second renewal during entry", ((6, 7), (8, 8)), False),
            ("entry and live retirement", ((7, 8), (125, 140)), True),
            ("page creation", ((9, 11),), False),
            ("preparation", ((13, 15),), False),
            ("load acceptance", ((19, 21),), False),
            ("response callback", ((31, 33),), False),
            ("observed through", ((74, 76),), False),
            ("actual close", ((89, 91),), False),
            ("first retirement poll", ((109, 111),), False),
            ("replacement commit", ((154, 156),), False),
            ("exit poll", ((169, 171),), False),
            ("after exit but before retirement observation", ((171, 172),), False),
        )
        for phase, prefix, origin, read in probe_fixtures():
            health = sequenced_probe(phase, origin)
            for name, times, valid in cases:
                with self.subTest(phase=phase, case=name):
                    tokens = (NEXT_TOKEN, TOKEN.replace(b"f48", b"f38"))
                    permits = b"".join(challenge(token, issued=origin + issued, appended=origin + written)
                                       for token, (issued, written) in zip(tokens, times))
                    if valid:
                        read(prefix + permits + health)
                    else:
                        with self.assertRaisesRegex(ValueError, "Native challenge renewal is outside the health probe interval"):
                            read(prefix + permits + health)

    def test_probe_permit_may_span_a_backdated_preparation_timeout(self):
        for phase, prefix, origin, read in probe_fixtures():
            with self.subTest(phase=phase):
                permit = challenge(NEXT_TOKEN, issued=origin + 15_009, appended=origin + 15_011)
                health = row("health", phase=phase, elapsedMs=origin + 15_200,
                             outcome="failed", navigationIssued=False, documentCommitted=False, documentFinished=False,
                             preparationDeadlineAtNs=(origin + 15_010) * NS_PER_MS,
                             timelineMs={"preparationTimedOut": 15_000}, observationCutoffMs=15_000,
                             localPreparationDisposition="preparation-timeout",
                             observedThroughAtNs=(origin + 15_040) * NS_PER_MS,
                             retirementState="unbound", transportQuiesced=True, retirementRequestedAtMs=15_020,
                             transportQuiescedAtMs=15_030, retirementObservedMs=25)
                self.assertTrue(read(prefix + permit + health).halted)

    def test_unbound_probe_timeout_keeps_the_first_publisher_request(self):
        phase, prefix, _, _ = probe_fixtures()[0]
        page_ns = 10 * NS_PER_MS
        first_ns = 15_040 * NS_PER_MS
        through_ns = 15_045 * NS_PER_MS
        outside = "outside the health probe interval"

        def health(requested_ns, *, quiesced=True, **fields):
            return row(
                "health", **(dict(
                    phase=phase, elapsedMs=15_200, outcome="failed", navigationIssued=False,
                    documentCommitted=False, documentFinished=False, preparationDeadlineAtNs=15_010 * NS_PER_MS,
                    timelineMs={"preparationTimedOut": 15_000}, observationCutoffMs=15_000,
                    localPreparationDisposition="preparation-timeout", observedThroughAtNs=first_ns,
                    retirementState="unbound", transportQuiesced=quiesced, retirementRequestedAtNs=requested_ns,
                    retirementRequestedAtMs=(requested_ns - page_ns) // NS_PER_MS,
                    transportQuiescedAtMs=15_030 if quiesced else None, retirementExitPolledAtNs=first_ns,
                    retirementObservedThroughAtNs=through_ns,
                    retirementObservedMs=(through_ns - requested_ns) // NS_PER_MS,
                ) | fields))

        for requested in (8_000, 15_020):
            native = prefix + health(page_ns + requested * NS_PER_MS)
            self.assert_snapshot_paths(f"owner-timeout-{requested}", native)

        for name, requested, quiesced, error in (
                ("before-publication", page_ns, False, outside),
                ("before-first-watch", 2_010 * NS_PER_MS - 1, False, outside),
                ("first-watch-late-expiry", 2_010 * NS_PER_MS, False, None),
                ("sample-at-expiry", 5_040 * NS_PER_MS, True, None),
                ("sample-after-expiry", 5_040 * NS_PER_MS - 1, True, "outside its observation window")):
            self.assert_snapshot_paths(name, prefix + health(requested, quiesced=quiesced),
                                       verified=prefix, invalid=error)

        self.assert_snapshot_paths("timeout-cannot-bind", prefix + health(
            8_010 * NS_PER_MS, actualProtocol="socks5", port=20080), verified=prefix,
            invalid="failure milestone disagrees with the navigation phase")

        next_watch = permit_series(7_000, ((10, 10), (11, 11), (110, 110)))
        for name, permits, requested, valid in (
                ("next-watch-too-soon", next_watch, 9_010 * NS_PER_MS - 1, False),
                ("next-watch-ready", next_watch, 9_010 * NS_PER_MS, True),
                ("watch-cancelled-before-timeout", permit_series(8_010, ((1, 1), (2, 2))), 8_010 * NS_PER_MS, False),
                ("fence-ready-before-timeout", permit_series(8_010, ((1, 1), (51, 51))), 8_010 * NS_PER_MS, True)):
            active = prefix + permits
            self.assert_snapshot_paths(name, active + health(requested), verified=active,
                                       invalid=None if valid else outside)

    def test_health_entry_renewal_cannot_sample_probe_bytes(self):
        for phase, prefix, origin, read in probe_fixtures():
            admitted = {"phase": phase, "healthAdmittedAtNs": (origin + 9) * NS_PER_MS}
            for counters in ({"chargedBytes": 1}, {"reservedBytes": 64}):
                with self.subTest(phase=phase, counters=counters):
                    permit = challenge(NEXT_TOKEN, issued=origin + 7, appended=origin + 8, **counters)
                    health = healthy(**admitted, chargedBytes=counters.get("chargedBytes", 0))
                    with self.assertRaisesRegex(ValueError, "Native health entry renewal disagrees with byte counters"):
                        read(prefix + permit + health)
            entry = challenge(NEXT_TOKEN, issued=origin + 7, appended=origin + 8)
            in_page = challenge(TOKEN.replace(b"f48", b"f38"), issued=origin + 13, appended=origin + 14,
                                chargedBytes=10, reservedBytes=64)
            health = healthy(**admitted, chargedBytes=10)
            self.assertIsNotNone(read(prefix + entry + in_page + health).challenge_sha256)

    def test_worker_free_rows_preserve_the_quiescent_charge(self):
        retired = READY + RESERVED + DISPATCH + RESULT + change_row(RETIRED, chargedBytes=45)
        guard = challenge(NEXT_TOKEN, issued=3_700, chargedBytes=45)
        stopped = row("checkpoint", reason="run-control-unavailable", budgetStopReason="run-control-unavailable",
                      reservedCount=1, budgetStopAtNs=3_700 * NS_PER_MS, chargedBytes=45)
        native, read_final = three_timeout_fixture()
        prefix, _, _ = native.rsplit(b"\n", 2)
        final_retirement = native[len(prefix) + 1:]
        final_prefix = prefix + b"\n" + change_row(final_retirement, chargedBytes=45)
        pause = change_row(PAUSED, chargedBytes=45)
        final = healthy(phase="after-three-no-http-timeouts", chargedBytes=45)
        checkpoint = row("checkpoint", reason="three-no-http-timeouts", reservedCount=3, chargedBytes=45)

        def read(raw):
            return read_campaign_receipt(raw, TARGETS, IDENTITY, LIMITS)

        cases = (
            (b"", START, 0, read), (START, ARMED[len(START):], 0, read), (ARMED, GRANTED[len(ARMED):], 0, read),
            (retired, guard, 45, read), (retired + guard, stage("reserved", 2, chargedBytes=45), 45, read),
            (retired + guard, stopped, 45, read), (final_prefix, pause, 45, read_final),
            (final_prefix + pause + final, checkpoint, 45, read_final),
        )
        for prefix, valid, baseline, parse in cases:
            parse(prefix + valid)
            for counters in ({"chargedBytes": baseline + 1}, {"reservedBytes": 64}):
                with self.subTest(event=json.loads(valid)["event"], counters=counters):
                    with self.assertRaisesRegex(ValueError, "worker-free interval"):
                        parse(prefix + change_row(valid, **counters))

    def test_open_guard_cannot_sample_bytes_before_preparation(self):
        for phase, prefix, origin, read in probe_fixtures():
            entry = challenge(NEXT_TOKEN, issued=origin + 7, appended=origin + 8)
            opening = challenge(TOKEN.replace(b"f48", b"f38"), issued=origin + 11, appended=origin + 14)
            health = sequenced_probe(phase, origin, chargedBytes=10)
            with self.subTest(phase=phase):
                active = challenge(TOKEN.replace(b"f48", b"f28"), issued=origin + 14, appended=origin + 16,
                                   chargedBytes=10, reservedBytes=64)
                read(prefix + entry + opening + active + health)
                for counters in ({"chargedBytes": 1}, {"reservedBytes": 64}):
                    with self.assertRaisesRegex(ValueError, "worker-free interval"):
                        read(prefix + entry + change_row(opening, **counters) + health)
                unprepared = row("health", phase=phase, outcome="failed", navigationIssued=False,
                                 documentCommitted=False, documentFinished=False, retirementState="unbound",
                                 transportQuiesced=True, retirementRequestedAtMs=100, retirementObservedMs=20,
                                 transportQuiescedAtMs=100)
                read(prefix + entry + opening + unprepared)
                with self.assertRaisesRegex(ValueError, "worker-free interval"):
                    read(prefix + entry + change_row(opening, reservedBytes=64) + unprepared)

        result = stage("result", outcome="failed", navigationIssued=False,
                       documentCommitted=False, documentFinished=False)
        permit = challenge(NEXT_TOKEN, issued=3_010, reservedBytes=64)
        with self.assertRaisesRegex(ValueError, "worker-free interval"):
            read_campaign_receipt(READY + RESERVED + permit + result, TARGETS, IDENTITY, LIMITS)
        permit = challenge(NEXT_TOKEN, issued=3_310, reservedBytes=64)
        with self.assertRaisesRegex(ValueError, "worker-free interval"):
            read_campaign_receipt(READY + RESERVED + result + permit, TARGETS, IDENTITY, LIMITS)

    def test_probe_close_allows_one_healthy_renewal_or_two_with_a_reachable_stop(self):
        for phase, prefix, origin, read in probe_fixtures():
            entry = challenge(NEXT_TOKEN, issued=origin + 7, appended=origin + 8)
            close = challenge(TOKEN.replace(b"f48", b"f38"), issued=origin + 95, appended=origin + 97)
            extra = challenge(TOKEN.replace(b"f48", b"f28"), issued=origin + 101, appended=origin + 102)
            third = challenge(TOKEN.replace(b"f48", b"f68"), issued=origin + 105, appended=origin + 106)
            fence = challenge(TOKEN.replace(b"f48", b"f28"), issued=origin + 126, appended=origin + 127)
            for reason, at, charge, valid in (
                    ("transport-lost", 98, 0, True), ("run-control-unavailable", 98, 0, True),
                    ("metering-failure", 96, 1, True), ("external-stop", 98, 0, True),
                    ("node-revision-changed", 98, 0, True),
                    ("run-control-unavailable", 140, 0, True), (None, 0, 0, True)):
                stop = {"stopReason": reason, "stopAtMs": at - 10} if reason else {}
                health = sequenced_probe(phase, origin, haltDuringRetirement=stop, chargedBytes=charge)
                closing = change_row(close, chargedBytes=charge)
                with self.subTest(phase=phase, stop=reason, at=at):
                    if valid:
                        read(prefix + entry + closing + health)
                        if stop and at < 126:
                            with self.assertRaises(ValueError):
                                read(prefix + entry + closing + fence + health)
                    else:
                        with self.assertRaisesRegex(ValueError, "outside the health probe interval"):
                            read(prefix + entry + closing + health)
            healthy_close = sequenced_probe(phase, origin)
            with self.assertRaisesRegex(ValueError, "outside the health probe interval"):
                read(prefix + entry + close + extra + healthy_close)
            stopping_close = sequenced_probe(phase, origin, haltDuringRetirement={
                "stopReason": "transport-lost", "stopAtMs": 98})
            self.assertTrue(read(prefix + entry + close + extra + stopping_close).halted)
            for reason, valid in (("run-control-unavailable", True), ("node-revision-changed", False),
                                  ("external-stop", False)):
                second_guard = sequenced_probe(phase, origin, haltDuringRetirement={
                    "stopReason": reason, "stopAtMs": 98})
                with self.subTest(phase=phase, second_guard=reason):
                    if valid:
                        self.assertTrue(read(prefix + entry + close + extra + second_guard).halted)
                    else:
                        with self.assertRaisesRegex(ValueError, "outside the health probe interval"):
                            read(prefix + entry + close + extra + second_guard)
            with self.assertRaisesRegex(ValueError, "outside the health probe interval"):
                read(prefix + close + extra + third + stopping_close)
            self.assertEqual(read(prefix + entry + close + fence + healthy_close).halted, origin != 0)
            read(prefix + entry + fence + healthy_close)
            at_first_poll = change_row(healthy_close, haltDuringRetirement={
                "stopReason": "external-stop", "stopAtMs": 100, "stopAtNs": (origin + 110) * NS_PER_MS})
            self.assertTrue(read(prefix + close + at_first_poll).halted)

            failed_navigation = sequenced_probe(
                phase, origin, outcome="failed", documentFinished=False, errorDomain="NSURLErrorDomain", errorCode=-1003,
                timelineMs={"loadIssued": 10, "firstVisibleHTTPResponse": 22, "documentCommit": 30, "navigationFailure": 50},
                retirementRequestedAtMs=51, retirementObservedMs=129)
            finishing_poll = challenge(TOKEN.replace(b"f48", b"f38"), issued=origin + 65, appended=origin + 67)
            read(prefix + entry + finishing_poll + failed_navigation)

    def test_retirement_fence_cadence_starts_after_permit_recording(self):
        for phase, prefix, origin, read in probe_fixtures():
            first = challenge(NEXT_TOKEN, issued=origin + 125, appended=origin + 126)
            health = sequenced_probe(phase, origin, transportQuiescedAtMs=230, retirementObservedMs=160)
            for issued in (128, 175, 176, 177):
                second = challenge(TOKEN.replace(b"f48", b"f38"), issued=origin + issued, appended=origin + issued + 1)
                with self.subTest(phase=phase, next_permit=issued):
                    if issued >= 176:
                        read(prefix + first + second + health)
                    else:
                        with self.assertRaisesRegex(ValueError, "outside the health probe interval"):
                            read(prefix + first + second + health)
            for reason, at, valid in (("external-stop", 130, False), ("external-stop", 176, True),
                                      ("node-revision-changed", 175, False), ("node-revision-changed", 177, True),
                                      ("run-control-unavailable", 126, True), ("run-control-unavailable", 130, True),
                                      ("run-control-unavailable", 170, False), ("metering-failure", 127, True)):
                stopped = change_row(health, chargedBytes=int(reason == "metering-failure"), haltDuringRetirement={
                    "stopReason": reason, "stopAtMs": at - 10, "stopAtNs": (origin + at) * NS_PER_MS})
                with self.subTest(phase=phase, stop=reason, at=at):
                    if valid:
                        self.assertTrue(read(prefix + first + stopped).halted)
                    else:
                        with self.assertRaisesRegex(ValueError, "outside the health probe interval"):
                            read(prefix + first + stopped)

            tied = challenge(NEXT_TOKEN, issued=origin + 110)
            next_poll = challenge(TOKEN.replace(b"f48", b"f38"), issued=origin + 111)
            # The equal stamp allows the first permit to be the close check.
            read(prefix + tied + next_poll + health)
            earlier = challenge(NEXT_TOKEN, issued=origin + 111)
            tied_next = change_row(next_poll, challengeIssuedAtNs=(origin + 111) * NS_PER_MS)
            with self.assertRaisesRegex(ValueError, "outside the health probe interval"):
                read(prefix + earlier + tied_next + health)

        first = challenge(NEXT_TOKEN, issued=3_320, appended=3_322)
        for issued in (3_371, 3_372):
            second = challenge(TOKEN.replace(b"f48", b"f38"), issued=issued)
            retirement = stage("retirement", retirementState="confirmed", transportQuiesced=True,
                               **(WITNESSES | {"transportQuiescedAtMs": 400}))
            native = READY + RESERVED + DISPATCH + RESULT + first + second + retirement
            with self.subTest(target_next_poll=issued):
                if issued == 3_372:
                    read_campaign_receipt(native, TARGETS, IDENTITY, LIMITS)
                else:
                    with self.assertRaisesRegex(ValueError, "outside the target interval"):
                        read_campaign_receipt(native, TARGETS, IDENTITY, LIMITS)

    def test_close_and_wait_renewals_can_precede_independent_deadlines(self):
        for window, permit_at, stop_at in ((100, 95, 105), (130, 125, 135)):
            limits = CampaignLimits(LIMITS.targets, LIMITS.duration_seconds, LIMITS.bytes, window)
            prefix = change_row(START, **limits.fields()) + GRANTED[len(START):]
            permit = challenge(NEXT_TOKEN, issued=permit_at, appended=permit_at + 1)
            phase = "before-first-target"
            health = sequenced_probe(phase, 0, haltDuringRetirement={
                "stopReason": "run-permit-expired", "stopAtMs": stop_at - 10})
            checkpoint = row("checkpoint", reason="run-permit-expired", reservedCount=0,
                             budgetStopReason="run-permit-expired", budgetStopAtNs=stop_at * NS_PER_MS)
            with self.subTest(permit=permit_at):
                self.assertEqual(read_campaign_receipt(prefix + permit + health + checkpoint, TARGETS, IDENTITY, limits)
                                 .checkpoint, "run-permit-expired")

    def test_incomplete_target_drain_applies_cadence_in_observe_and_reconcile(self):
        first = challenge(NEXT_TOKEN, issued=3_320, appended=3_322)
        token = TOKEN.replace(b"f48", b"f38")
        too_soon = challenge(token, issued=3_323)
        later = challenge(token, issued=3_372)
        result = READY + RESERVED + DISPATCH + RESULT
        unprepared = READY + RESERVED + stage("result", outcome="failed", navigationIssued=False,
                                             documentCommitted=False, documentFinished=False)
        for name, verified, valid_token, bad, invalid_token in (
                ("cadence", result + first, NEXT_TOKEN, too_soon, token),
                ("unprepared", unprepared, TOKEN, first, NEXT_TOKEN)):
            for reconcile in (False, True):
                with self.subTest(case=name, reconcile=reconcile):
                    label = f"{name}-stopped" if reconcile else f"{name}-live"
                    state_name = f"{label}.json"
                    destination = self.directory / label
                    second = self.directory / f"{label}-second"
                    self.observer = self.open_observer(state_name)
                    self.replies.clear()
                    self.transport.clear()
                    native = verified + bad
                    reads = []

                    def read_challenge(_):
                        reads.append(invalid_token)
                        return invalid_token

                    if not reconcile:
                        self.observe(f"{label}-verified", verified, token=valid_token)
                        self.assertEqual(self.replies, [valid_token])
                    replies_before = list(self.replies)

                    def observe_invalid():
                        return self.observer.observe_and_renew(
                            self.snapshots(native), destination, self.report, read_challenge,
                            lambda value, _: self.replies.append(value), deadline=self.deadline)

                    with self.assertRaisesRegex(LedgerObservationUnavailable, "outside the target interval"):
                        if reconcile:
                            self.observer.reconcile_stopped(
                                self.snapshots(native, native), destination, second, self.report,
                                lambda _: True, deadline=self.deadline)
                        else:
                            observe_invalid()
                    self.assertEqual(self.observer.observed_prefix, verified)
                    state = json.loads((self.directory / state_name).read_bytes())
                    self.assertTrue(state["disputed"])
                    self.assertFalse(state["pending"])
                    self.assertEqual(base64.b64decode(state["witness"]), native)
                    self.assertEqual(self.transport[-1], (1, "invalid-ledger"))
                    raw_copy, = self.directory.glob(f"{label}-copy-*/device.jsonl")
                    self.assertEqual(raw_copy.read_bytes(), native)
                    self.assertFalse(destination.exists())
                    self.assertFalse(second.exists())
                    with self.assertRaisesRegex(RuntimeError, "Renewal is closed"):
                        observe_invalid()
                    self.observer = self.open_observer(state_name, recover=True)
                    with self.assertRaisesRegex(LedgerObservationUnavailable, "Unresolved native copy evidence"):
                        self.observer.reconcile_stopped(
                            self.snapshots(), destination, second, self.report, lambda _: True, deadline=self.deadline)
                    self.assertEqual(self.replies, replies_before)
                    self.assertEqual(reads, [])
        self.observer = self.open_observer("valid-drain.json")
        self.replies.clear()
        native = result + first + later
        self.observe("valid-drain", native, token=token)
        self.assertEqual(self.replies, [token])
        self.assertEqual(self.reconcile(native, native).remaining_targets(TARGETS), TARGETS[1:])
        retirement = stage("retirement", retirementState="confirmed", transportQuiesced=True,
                           **(WITNESSES | {"transportQuiescedAtMs": 400}))
        self.assertTrue(read_campaign_receipt(native + retirement, TARGETS, IDENTITY, LIMITS).attempts[0].settled)

    def test_first_wait_uses_the_live_fence_timer_in_a_result_prefix(self):
        verified, retirement = target_drain_fixture()
        token = TOKEN.replace(b"f48", b"f38")
        for at in (3_051, 3_070, 3_071):
            waiting = challenge(token, issued=at)
            for complete in (False, True):
                native = verified + waiting + (retirement if complete else b"")
                self.assert_snapshot_paths(
                    f"first-fence-{at}-{complete}", native, token=token, partial=not complete,
                    invalid="outside the target interval" if at < 3_071 else None,
                    verified=verified, renews=at == 3_071)

        # If the live permit can be a final guard or publisher watch, the
        # fence may already be ready when the result becomes durable.
        prefix, result, _ = verified.rsplit(b"\n", 2)
        callback_times = {"loadIssued": 1, "firstVisibleHTTPResponse": 14, "documentCommit": 16, "documentFinish": 18}
        early_callbacks = change_row(result, timelineMs=callback_times,
                                     timelineNs={name: at * NS_PER_MS for name, at in callback_times.items()})
        publisher, later_retirement = target_drain_fixture(offset=2_000)
        for source, result, retired, at in (
                ("final", prefix + b"\n" + early_callbacks, retirement, 3_051),
                ("publisher", publisher, later_retirement, 5_051)):
            waiting = challenge(token, issued=at)
            self.assert_snapshot_paths(f"alternate-{source}-prefix", result + waiting, token=token, renews=True)
            self.assert_snapshot_paths(f"alternate-{source}-complete", result + waiting + retired,
                                       token=token, renews=True)

    def test_stop_only_wait_uses_the_live_fence_timer(self):
        prefix, retirement = target_drain_fixture()
        waiting = challenge(TOKEN.replace(b"f48", b"f38"), issued=3_071)
        for at, reason, permit, valid in (
                (3_051, "external-stop", b"", False), (3_071, "external-stop", b"", True),
                (3_072, "external-stop", waiting, False), (3_072, "run-control-unavailable", waiting, True)):
            stopped = change_row(retirement, haltDuringRetirement={
                "stopReason": reason, "stopAtMs": at - 3_001, "stopAtNs": at * NS_PER_MS})
            latest = prefix + permit
            self.assert_snapshot_paths(f"stop-{reason}-{at}", latest + stopped, verified=latest,
                                       invalid=None if valid else "outside the target interval")

    def test_result_prefix_cannot_renew_close_after_a_live_navigation_failure(self):
        active = READY + RESERVED + DISPATCH
        permit = challenge(NEXT_TOKEN, issued=3_067)
        evidence = dict(elapsedMs=3_090, navigationIssued=True, documentCommitted=False, documentFinished=False,
                        observationCutoffMs=61)
        failed = stage("result", **evidence, outcome="failed", errorDomain="NSURLErrorDomain", errorCode=-1003,
                       timelineMs={"loadIssued": 1, "navigationFailure": 59})
        self.assert_snapshot_paths("closed-result", active + permit + failed, verified=active + permit,
                                   invalid="outside the target interval", partial=True)

        early = active + challenge(NEXT_TOKEN, issued=3_061) + failed
        retirement = stage("retirement", elapsedMs=3_180, retirementState="confirmed", transportQuiesced=True,
                           retirementRequestedAtMs=60, retirementObservedMs=100, retirementCommitAtMs=119,
                           retirementFirstPolledAtNs=3_090 * NS_PER_MS, transportQuiescedAtMs=139)
        self.assert_snapshot_paths("early-close-prefix", early, renews=True, partial=True)
        self.assert_snapshot_paths("early-close-complete", early + retirement, renews=True)

        # Callbacks recorded after close leave the live failure evidence unchanged.
        finished = stage("result", **(evidence | {"documentCommitted": True, "documentFinished": True}),
                         outcome="finished")
        closing = active + permit + finished
        late_callback = change_row(retirement, retirementRequestedAtMs=63, retirementRequestedAtNs=3_064 * NS_PER_MS,
                                   retirementObservedMs=97, originalNavigationAfterClose={
                                       "timelineMs": {"navigationFailure": 109}, "timelineNs": {"navigationFailure": 109 * NS_PER_MS},
                                       "errorDomain": "NSURLErrorDomain", "errorCode": -1003})
        self.assert_snapshot_paths("original-callback-prefix", closing, renews=True)
        self.assert_snapshot_paths("original-callback-complete", closing + late_callback, renews=True)

    def test_only_the_terminal_policy_rejection_closes_before_observation(self):
        active = READY + RESERVED + DISPATCH
        permit = challenge(NEXT_TOKEN, issued=3_067)
        for policy in ("additional-top-level-navigation", "unsupported-mime-type", "non-https-navigation",
                       "download-navigation"):
            closed = policy == "additional-top-level-navigation"
            result = stage("result", outcome="policy-blocked", navigationIssued=True, documentCommitted=False,
                           documentFinished=False, localPolicyRejection=policy, observationCutoffMs=61,
                           elapsedMs=3_090, timelineMs={"loadIssued": 1, "policyRejection": 59})
            self.assert_snapshot_paths(f"target-policy-{policy}", active + permit + result,
                                       verified=active + permit, renews=not closed,
                                       invalid="outside the target interval" if closed else None)
            if closed:
                early = active + challenge(NEXT_TOKEN, issued=3_061) + result
                self.assert_snapshot_paths("target-policy-in-triggers-close", early, renews=True)

        for phase, prefix, origin, _ in probe_fixtures():
            targets = TIMEOUT_TARGETS if origin else TARGETS
            limits = replace(LIMITS, targets=len(targets))
            for policy in ("additional-top-level-navigation", "unsupported-mime-type"):
                health = sequenced_probe(phase, origin, outcome="policy-blocked", documentCommitted=False,
                                         documentFinished=False,
                                         localPolicyRejection=policy,
                                         timelineMs={"loadIssued": 10, "firstVisibleHTTPResponse": 22, "policyRejection": 50})
                before_health = prefix + challenge(NEXT_TOKEN, issued=origin + 95)
                closed = policy == "additional-top-level-navigation"
                self.assert_snapshot_paths(f"probe-policy-{origin}-{policy}", before_health + health,
                                           verified=before_health, targets=targets, limits=limits,
                                           invalid="outside the health probe interval" if closed else None)
                if closed:
                    early = change_row(health, retirementRequestedAtMs=51, retirementObservedMs=129,
                                       retirementRequestedAtNs=(origin + 61) * NS_PER_MS)
                    self.assert_snapshot_paths(f"probe-policy-early-{origin}", prefix + early,
                                               targets=targets, limits=limits)

    def test_terminal_policy_bounds_live_callbacks_and_retirement_request(self):
        active = READY + RESERVED + DISPATCH
        terminal = "additional-top-level-navigation"
        regular = "unsupported-mime-type"
        late_commit = {"timelineMs": {"documentCommit": 20_009}, "documentCommitted": True}
        waiting = challenge(NEXT_TOKEN, issued=23_031)
        for policy in (terminal, regular):
            result = stage("result", outcome="policy-blocked", navigationIssued=True, documentCommitted=False,
                           documentFinished=False, localPolicyRejection=policy, observationCutoffMs=20_001,
                           observedThroughAtNs=23_025 * NS_PER_MS, elapsedMs=23_030,
                           timelineMs={"loadIssued": 1, "policyRejection": 19_998}, observedAfterCutoff=late_commit)
            self.assert_snapshot_paths(f"policy-late-live-{policy}", active + result + waiting, verified=active,
                                       invalid="Live WebKit callbacks cannot follow terminal navigation policy"
                                       if policy == terminal else None, renews=policy == regular)

        result = stage("result", outcome="policy-blocked", navigationIssued=True, documentCommitted=False,
                       documentFinished=False, localPolicyRejection=terminal, observationCutoffMs=61,
                       elapsedMs=3_090, timelineMs={"loadIssued": 1, "policyRejection": 59})
        for requested in (3_059, 3_060, 3_061):
            retirement = stage("retirement", elapsedMs=3_180, retirementState="confirmed", transportQuiesced=True,
                               retirementRequestedAtMs=requested - 3_001, retirementObservedMs=3_170 - requested,
                               retirementFirstPolledAtNs=3_090 * NS_PER_MS, retirementCommitAtMs=119,
                               transportQuiescedAtMs=139)
            self.assert_snapshot_paths(f"policy-request-{requested}", active + result + retirement,
                                       verified=active + result, token=TOKEN, renews=requested >= 3_060,
                                       invalid="retirement request precedes terminal navigation policy"
                                       if requested < 3_060 else None)

        fields = dict(outcome="policy-blocked", navigationIssued=True, documentCommitted=False, documentFinished=False,
                      observationCutoffMs=20_001, elapsedMs=23_030, observedThroughAtNs=23_025 * NS_PER_MS,
                      timelineMs={"loadIssued": 1, "policyRejection": 19_998})
        # The frozen rejection can precede the terminal rejection. A late live
        # commit before that terminal rejection and an original commit after it
        # belong to different timelines.
        for phase, requested, original in (("frozen", 23_003, late_commit), ("late", 23_002, None),
                                            ("late", 23_010, None), ("late", 23_011, None)):
            result = stage("result", **fields, localPolicyRejection=terminal if original else regular,
                           **({} if original else {"observedAfterCutoff": late_commit | {"localPolicyRejection": terminal}}))
            retirement = stage("retirement", elapsedMs=23_100, retirementState="confirmed", transportQuiesced=True,
                               retirementRequestedAtMs=requested - 3_001, retirementObservedMs=23_100 - requested,
                               retirementFirstPolledAtNs=23_030 * NS_PER_MS, retirementCommitAtMs=20_080,
                               transportQuiescedAtMs=20_080, originalNavigationAfterClose=original)
            verified = active + result + waiting
            invalid = "retirement request precedes terminal navigation policy" if requested == 23_002 else None
            self.assert_snapshot_paths(f"policy-{phase}-retired-{requested}", verified + retirement,
                                       verified=verified, invalid=invalid, renews=invalid is None)

    def test_frozen_terminal_policy_permits_bound_first_retirement_wait(self):
        waiting = challenge(NEXT_TOKEN, issued=33_069)
        for name, first_permit, written in (
                ("review", (5, 5), 33_005), ("spans-cutoff", (1, 5), 33_001)):
            verified = policy_wait_prefix(written, first_permit)
            self.assert_snapshot_paths(f"expired-policy-wait-{name}", verified + waiting, verified=verified,
                                       invalid="outside the target interval", partial=True)

        verified = policy_wait_prefix(33_004) + waiting
        retirement = stage("retirement", elapsedMs=33_120, retirementState="unconfirmed", transportQuiesced=False,
                           retirementRequestedAtMs=20_005, retirementObservedMs=10_114,
                           retirementFirstPolledAtNs=33_004 * NS_PER_MS)
        self.assert_snapshot_paths("reported-close-after-permit", verified + retirement, verified=verified,
                                   invalid="outside the target interval")

    def test_terminal_policy_wait_keeps_delayed_close_and_wake_controls(self):
        waiting = challenge(NEXT_TOKEN, issued=33_069)
        terminal = "additional-top-level-navigation"
        regular = {"localPolicyRejection": "unsupported-mime-type"}
        for name, first_permit, written, fields in (
                ("review", (5, 5), 33_004, {}),
                ("spans-cutoff", (1, 5), 33_000, {}),
                ("ties-cutoff", (1, 2), 33_005, {}),
                ("late-policy", (5, 5), 33_005, regular | {"observedAfterCutoff": {"localPolicyRejection": terminal}}),
                ("nonclosing", (5, 5), 33_005, regular)):
            native = policy_wait_prefix(written, first_permit, **fields) + waiting
            self.assert_snapshot_paths(f"possible-policy-wait-{name}", native, renews=True)

        # The first sample was in time. The waiting permit and exit can be later.
        native = policy_wait_prefix(33_004) + waiting
        retirement = stage("retirement", elapsedMs=33_120, retirementState="unconfirmed", transportQuiesced=False,
                           retirementRequestedAtMs=20_004, retirementObservedMs=10_115,
                           retirementFirstPolledAtNs=33_004 * NS_PER_MS)
        self.observe("before-retirement", native, token=NEXT_TOKEN)
        self.observe("before-retirement-again", native, token=NEXT_TOKEN)
        self.assertEqual(self.replies, [NEXT_TOKEN])
        complete = native + retirement
        reconciled = self.reconcile(complete, complete)
        self.assertEqual(self.observer.observed_prefix, complete)
        self.assertEqual(reconciled.remaining_targets(TARGETS), TARGETS[1:])

    def test_pre_cutoff_final_poll_bounds_the_first_retirement_sleep(self):
        # The watch cannot wake yet. Two live fence checks leave the third
        # permit for close or the final direct poll, both after the request.
        active = READY + RESERVED + DISPATCH + permit_series(3_000, ((50, 50), (51, 51), (52, 52)))
        waiting = challenge(NEXT_TOKEN, issued=13_069)
        latest_request = 3_052 * NS_PER_MS
        outside = "outside the target interval"
        for written, valid in ((13_051 * NS_PER_MS, True), (13_052 * NS_PER_MS - 1, True),
                               (13_052 * NS_PER_MS, False)):
            prefix = active + policy_result(elapsedNs=written, elapsedMs=written // NS_PER_MS,
                                            timelineMs={"loadIssued": 1, "policyRejection": 39})
            self.assert_snapshot_paths(f"early-close-sleep-{written}", prefix + waiting, verified=prefix,
                                       renews=valid, invalid=None if valid else outside)
            # On the negative, the supplied clock would admit a sleep on its
            # own, but the final or close permit already followed the request.
            requested = latest_request if valid else latest_request + 1
            retired = policy_retirement(requested, written, 13_120 * NS_PER_MS)
            self.assert_snapshot_paths(f"early-close-sleep-finished-{written}", prefix + waiting + retired,
                                       verified=prefix, invalid=None if valid else outside)
            if valid:
                impossible_request = policy_retirement(latest_request + 1, written, 13_120 * NS_PER_MS)
                self.assert_snapshot_paths(f"early-close-stamped-after-final-{written}",
                                           prefix + waiting + impossible_request, verified=prefix + waiting,
                                           invalid=outside)

    def test_open_guard_must_precede_the_tied_dispatch_append(self):
        dispatch = stage("dispatch", navigationIssuedAtNs=3_050 * NS_PER_MS, elapsedMs=3_050)
        tied = challenge(TOKEN.replace(b"f48", b"f28"), issued=3_050)
        follow = permit_series(3_000, ((51, 51), (52, 52)))
        waiting = challenge(NEXT_TOKEN, issued=13_069)
        for before_dispatch, written, valid in ((False, 13_051, True), (False, 13_052, False), (True, 13_052, True)):
            result = policy_result(
                elapsedMs=written, navigationIssuedAtNs=3_050 * NS_PER_MS,
                preparationStartedAtNs=3_050 * NS_PER_MS, preparationDeadlineAtNs=18_050 * NS_PER_MS,
                timelineMs={"loadIssued": 49, "policyRejection": 49})
            rows = tied + dispatch if before_dispatch else dispatch + tied
            prefix = READY + RESERVED + rows + follow + result
            requested = 3_052 * NS_PER_MS if written == 13_051 else 3_052 * NS_PER_MS + 1
            retired = policy_retirement(requested, written * NS_PER_MS, 13_120 * NS_PER_MS)
            for tail in (b"", retired):
                self.assert_snapshot_paths(f"open-dispatch-tie-{before_dispatch}-{written}-{bool(tail)}",
                                           prefix + waiting + tail, verified=prefix, renews=valid and not tail,
                                           invalid=None if valid else "outside the target interval")
            if not before_dispatch:
                self.assert_snapshot_paths(f"open-without-target-dispatch-{written}",
                                           READY + RESERVED + tied + follow + result,
                                           verified=READY + RESERVED + tied + follow,
                                           invalid="Result disagrees with the independent native navigation stages")

        # A combined health row carries the load clock without a dispatch append.
        health = sequenced_probe("before-first-target", 0, preparationStartedAtNs=20 * NS_PER_MS,
                                 preparationDeadlineAtNs=15_020 * NS_PER_MS)
        token = TOKEN.replace(b"f48", b"002")
        tied_health_permits = permit_series(20, ((0, 0), (0, 0), (0, 0)))
        self.assert_snapshot_paths("health-open-and-load-share-clock", GRANTED + tied_health_permits + health,
                                   token=token, renews=True)
        after_load = GRANTED + b"".join(challenge(TOKEN.replace(b"f48", f"{index:03x}".encode()),
                                                  issued_ns=20 * NS_PER_MS + 1) for index in range(3))
        self.assert_snapshot_paths("health-open-after-load-clock", after_load + health, verified=after_load, token=token,
                                   invalid="outside the health probe interval")

    def test_retirement_quiet_sample_must_be_reachable_and_able_to_sleep(self):
        page, request, first, deadline = (at * NS_PER_MS for at in (3_001, 23_005, 23_040, 33_005))
        next_poll = 23_090 * NS_PER_MS
        sleep = 50 * NS_PER_MS
        first_sleep = "quiescence sample precedes the first completed sleep"
        nonterminal = "exit poll contradicts the quiescence sample"
        prefix = policy_wait_prefix(23_030)
        waiting = challenge(NEXT_TOKEN, issued=23_056)
        for name, quiet, exit_at, error in (
                ("twenty-ms-wake", 23_060 * NS_PER_MS, 23_110 * NS_PER_MS, first_sleep),
                ("before-50-ms", next_poll - 1, next_poll + sleep, first_sleep),
                ("first-50-ms", next_poll, next_poll + sleep, None),
                ("after-50-ms", next_poll + 1, next_poll + 1 + sleep, None),
                ("second-sleep-too-short", next_poll, next_poll + sleep - 1, nonterminal),
                ("second-sleep-late", next_poll, next_poll + sleep + 1, None),
                ("late-wake-from-predeadline-quiet", deadline - 1, 33_060 * NS_PER_MS, None),
                ("cannot-sleep-at-deadline", deadline, 33_060 * NS_PER_MS, nonterminal),
                ("quiet-after-deadline", deadline + 1, 33_060 * NS_PER_MS, "outside its observation window"),
                ("quiet-exits-at-deadline", deadline, deadline, None)):
            retired = policy_retirement(request, first, exit_at, commit_ns=quiet)
            retired = change_row(retired, retirementState="confirmed" if quiet <= deadline else "unconfirmed",
                                 transportQuiescedAtNs=quiet, transportQuiescedAtMs=(quiet - page) // NS_PER_MS)
            self.assert_snapshot_paths(name, prefix + waiting + retired, verified=prefix + waiting,
                                       invalid=error, renews=error is None)

        last_token = TOKEN.replace(b"f48", b"002")
        only_sample = policy_retirement(request, deadline, deadline, commit_ns=23_006 * NS_PER_MS)
        self.assert_snapshot_paths("first-quiet-and-exit-coincide", prefix + only_sample, token=last_token, renews=True)
        # The final isQuiescent read can disagree with the sampler's first idle streak.
        regressed = policy_retirement(request, first, next_poll, commit_ns=first)
        regressed = change_row(regressed, transportQuiescedAtNs=first, transportQuiescedAtMs=(first - page) // NS_PER_MS,
                               transportQuiesced=False)
        self.assert_snapshot_paths("quiescence-regresses-after-sample", prefix + waiting + regressed)

    def test_original_callback_must_fit_final_guard_and_first_yield(self):
        written, first, exit_at = (at * NS_PER_MS for at in (23_030, 23_040, 23_090))
        observed = 23_025 * NS_PER_MS
        prefix = policy_wait_prefix(23_030) + challenge(NEXT_TOKEN, issued=23_056)
        self.assert_snapshot_paths("first-yield-alone-prefix", prefix, renews=True)
        retired = policy_retirement(23_005 * NS_PER_MS, first, exit_at, commit_ns=23_075 * NS_PER_MS)
        for at, error in (
                (23_006 * NS_PER_MS, None),
                (23_007 * NS_PER_MS, None),
                (23_007 * NS_PER_MS + 1, "outside the target interval"),
                (observed, "outside the target interval"),
                (observed + 1, "precedes the first possible yield"),
                (written, "precedes the first possible yield"),
                (23_032 * NS_PER_MS, "precedes the first possible yield"),
                (first - 1, "precedes the first possible yield"),
                (first, None), (first + 1, None), (exit_at, None)):
            stamp = at - 3_001 * NS_PER_MS
            original = {"timelineNs": {"documentCommit": stamp},
                        "timelineMs": {"documentCommit": stamp // NS_PER_MS}, "documentCommitted": True}
            self.assert_snapshot_paths(f"original-first-yield-{at}", prefix + change_row(
                retired, originalNavigationAfterClose=original), verified=prefix, invalid=error, renews=error is None)

        # A prefix can be renewed before the callback arrives as ledger evidence.
        self.observe("before-impossible-callback", prefix, token=NEXT_TOKEN)
        impossible = change_row(retired, originalNavigationAfterClose=add_timeline_instants(
            {"timelineMs": {"documentCommit": 23_032 - 3_001}}))
        with self.assertRaisesRegex(LedgerObservationUnavailable, "precedes the first possible yield"):
            self.observe("after-impossible-callback", prefix + impossible, token=NEXT_TOKEN)
        self.assertEqual(self.replies, [NEXT_TOKEN])
        self.assertEqual(self.observer.observed_prefix, prefix)

    def test_original_redirect_count_requires_an_actor_turn(self):
        active = READY + RESERVED + DISPATCH
        observed = 3_062 * NS_PER_MS
        requested = 3_070 * NS_PER_MS
        result = policy_result(elapsedMs=3_100, localPolicyRejection="unsupported-mime-type")
        prefix = active + result
        no_yield = policy_retirement(requested, 13_070 * NS_PER_MS, 13_070 * NS_PER_MS)
        redirect = {"serverRedirectCount": 1, "timelineMs": {}, "timelineNs": {}}
        self.assert_snapshot_paths("redirect-after-final-without-yield",
                                   prefix + change_row(no_yield, originalNavigationAfterClose=redirect),
                                   verified=prefix, invalid="Original redirect requires a reachable callback turn")
        for name, details, error in (
                ("no-original-payload", None, None),
                ("report-only-original", {"documentCommitted": False, "navigationPolicy": "no-local-rejection-observed"}, None),
                ("no-redirects", {"serverRedirectCount": 0}, None),
                ("invalid-null-count", {"serverRedirectCount": None}, "Invalid native redirect evidence")):
            original = None if details is None else add_timeline_instants({"timelineMs": {}} | details)
            self.assert_snapshot_paths(name, prefix + change_row(
                no_yield, originalNavigationAfterClose=original, retirementEvents=["requested", "replacement-created"]),
                verified=prefix, invalid=error)

        early_result = active + policy_result(elapsedMs=3_100)
        for early in (observed - 1, observed):
            expired = early + 10_000 * NS_PER_MS
            retired = policy_retirement(early, expired, expired)
            self.assert_snapshot_paths(f"redirect-before-final-{early}", early_result + change_row(
                retired, originalNavigationAfterClose=redirect))
            if early == observed:
                original = add_timeline_instants({"timelineMs": {"documentCommit": 61}, "serverRedirectCount": 1})
                self.assert_snapshot_paths("redirect-shares-a-witnessed-turn",
                                           early_result + change_row(retired, originalNavigationAfterClose=original))

        yielded = policy_retirement(requested, 3_100 * NS_PER_MS, 3_150 * NS_PER_MS, commit_ns=3_120 * NS_PER_MS)
        self.assert_snapshot_paths("redirect-after-first-yield", prefix + challenge(NEXT_TOKEN, issued=3_100)
                                   + change_row(yielded, originalNavigationAfterClose=redirect), renews=True)

        # At the observation tie the final close could normally renew after
        # the snapshot. The redirect with no yield requires the other order.
        tied = policy_retirement(observed, 13_062 * NS_PER_MS, 13_062 * NS_PER_MS)
        close_prefix = active + challenge(NEXT_TOKEN, issued=3_063) + result
        self.assert_snapshot_paths("no-callback-final-close-guard", close_prefix + tied)
        self.assert_snapshot_paths("early-redirect-excludes-final-close-guard",
                                   close_prefix + change_row(tied, originalNavigationAfterClose=redirect),
                                   verified=close_prefix, invalid="outside the target interval")

    def test_original_redirect_must_fit_after_the_assigned_early_close_checks(self):
        request, deadline, first = (at * NS_PER_MS for at in (3_050, 13_050, 13_110))
        retired = policy_retirement(request, first, first)
        result = policy_result(elapsedMs=13_110, observationCutoffMs=10_099,
                               timelineMs={"loadIssued": 1, "policyRejection": 48})
        for first_permit, valid in ((deadline, True), (deadline + 1, False)):
            # Three close-spaced permits require one close check, one fence
            # turn and one final guard. The redirect can share the close clock.
            permits = b"".join(challenge(TOKEN.replace(b"f48", f"{index:03x}".encode()),
                                         issued_ns=first_permit + index * NS_PER_MS) for index in range(3))
            prefix = READY + RESERVED + DISPATCH + permits + result
            self.assert_snapshot_paths(f"early-close-without-redirect-{first_permit}", prefix + retired)
            original = add_timeline_instants({"timelineMs": {}, "serverRedirectCount": 1})
            self.assert_snapshot_paths(f"redirect-after-close-check-{first_permit}", prefix + change_row(
                retired, originalNavigationAfterClose=original), verified=prefix,
                invalid=None if valid else "outside the target interval")

    def test_retirement_callback_clock_ties_use_the_actual_sampler_outcome(self):
        early_request = 23_005 * NS_PER_MS

        def original(at):
            return add_timeline_instants({"timelineMs": {"documentCommit": at - 3_001}})

        prefix = policy_wait_prefix(23_030)
        last_token = TOKEN.replace(b"f48", b"002")
        terminal_at = 23_040 * NS_PER_MS
        terminal = policy_retirement(early_request, terminal_at, terminal_at, commit_ns=23_006 * NS_PER_MS)
        self.assert_snapshot_paths("terminal-early-original", prefix + change_row(
            terminal, originalNavigationAfterClose=original(23_007)), token=last_token, renews=True)
        self.assert_snapshot_paths("terminal-original-at-sample", prefix + change_row(
            terminal, originalNavigationAfterClose=original(23_040)), verified=prefix, token=last_token,
            invalid="precedes the first possible yield")
        self.assert_snapshot_paths("terminal-replacement-at-sample", prefix + policy_retirement(
            early_request, terminal_at, terminal_at, commit_ns=terminal_at), verified=prefix, token=last_token,
            invalid="precedes the first possible yield")

        # The tied result is before a callback when the sampler sleeps at
        # that same clock. A quiescence read itself is part of the sampler.
        at_result = policy_retirement(early_request, 23_030 * NS_PER_MS, 23_090 * NS_PER_MS,
                                      commit_ns=23_075 * NS_PER_MS)
        self.assert_snapshot_paths("yield-at-result-original", prefix + challenge(NEXT_TOKEN, issued=23_056)
                                   + change_row(at_result, originalNavigationAfterClose=original(23_030)), renews=True)

        release_tied_to_idle = policy_retirement(early_request, terminal_at, 23_090 * NS_PER_MS,
                                                 commit_ns=terminal_at)
        release_tied_to_idle = change_row(release_tied_to_idle, transportQuiescedAtNs=terminal_at,
                                          transportQuiescedAtMs=23_040 - 3_001)
        self.assert_snapshot_paths("replacement-after-tied-idle-sample",
                                   prefix + challenge(NEXT_TOKEN, issued=23_056) + release_tied_to_idle, renews=True)
        released_earlier = change_row(release_tied_to_idle, retirementCommitAtNs=23_006 * NS_PER_MS,
                                      retirementCommitAtMs=23_006 - 3_001)
        self.assert_snapshot_paths("earlier-replacement-would-exit-at-first-idle-sample", prefix + released_earlier,
                                   verified=prefix, invalid="exit poll contradicts the quiescence sample")

        # With no forced earlier final permit, an observation-clock callback
        # can precede the final guard, including when the terminal poll ties.
        tied_prefix = READY + RESERVED + DISPATCH + policy_wait_prefix(23_025).splitlines(keepends=True)[-1]
        for first_at, exit_at in ((23_025, 23_025), (23_040, 23_090)):
            tied = policy_retirement(early_request, first_at * NS_PER_MS, exit_at * NS_PER_MS,
                                     commit_ns=23_019 * NS_PER_MS)
            self.assert_snapshot_paths(f"original-before-tied-result-{first_at}", tied_prefix + change_row(
                tied, originalNavigationAfterClose=original(23_025)), token=TOKEN, renews=True)

    def test_frozen_policy_wait_uses_the_uncancelled_fence_timer(self):
        prefix = policy_wait_prefix(23_030)
        # The frozen policy forces closure before these three permits. The
        # close check, fence and final poll leave the fence asleep from 23,006.
        retired = policy_retirement(23_005 * NS_PER_MS, 23_030 * NS_PER_MS, 23_090 * NS_PER_MS,
                                    commit_ns=23_075 * NS_PER_MS)
        earliest = 23_056 * NS_PER_MS
        for issued in (23_031 * NS_PER_MS, earliest - 1, earliest, earliest + 1):
            waiting = challenge(NEXT_TOKEN, issued_ns=issued)
            for finish in (b"", retired):
                valid = issued >= earliest
                self.assert_snapshot_paths(f"policy-fence-{issued}-{bool(finish)}", prefix + waiting + finish,
                                           verified=prefix, renews=valid,
                                           invalid=None if valid else "outside the target interval")

        # A delayed retirement sampler can still be in its first sleep when
        # the fence renews after the close window has expired.
        waiting = challenge(NEXT_TOKEN, issued=33_069)
        delayed = policy_wait_prefix(33_004) + waiting
        self.assert_snapshot_paths("policy-fence-delayed", delayed, renews=True)
        self.assert_snapshot_paths("policy-fence-delayed-finished", delayed + policy_retirement(
            23_004 * NS_PER_MS + 1, 33_004 * NS_PER_MS, 33_120 * NS_PER_MS))

    def test_stamped_policy_request_must_preserve_the_wait_schedule(self):
        # The first publication ends at the phase boundary. It can be a live
        # watch with a later request, or belong to close with an earlier request.
        prefix = policy_wait_prefix(23_030, first_permit=(1, 2))
        early_wait = prefix + challenge(NEXT_TOKEN, issued=23_031)
        self.assert_snapshot_paths("tied-policy-live-watch", early_wait, renews=True)
        for requested, valid in ((23_001 * NS_PER_MS, False), (23_002 * NS_PER_MS - 1, False),
                                 (23_002 * NS_PER_MS, True), (23_002 * NS_PER_MS + 1, True),
                                 (23_006 * NS_PER_MS, True), (23_006 * NS_PER_MS + 1, False)):
            retired = policy_retirement(requested, 23_030 * NS_PER_MS, 23_090 * NS_PER_MS,
                                        commit_ns=23_075 * NS_PER_MS)
            self.assert_snapshot_paths(f"tied-policy-request-{requested}", early_wait + retired, verified=early_wait,
                                       renews=valid, invalid=None if valid else "outside the target interval")
        earlier_close = policy_retirement(23_001 * NS_PER_MS, 23_030 * NS_PER_MS, 23_090 * NS_PER_MS,
                                          commit_ns=23_075 * NS_PER_MS)
        self.assert_snapshot_paths("tied-policy-later-fence",
                                   prefix + challenge(NEXT_TOKEN, issued=23_056) + earlier_close, renews=True)

    def test_pending_policy_close_can_follow_a_ready_live_watch(self):
        # The first rejection can be nonterminal. If the watch is ready for
        # the third publication, all three permits can precede the true close.
        dispatch = stage("dispatch", navigationIssuedAtNs=5_002 * NS_PER_MS, elapsedMs=5_003)
        active = READY + RESERVED + dispatch + permit_series(5_000, ((50, 50), (51, 51), (52, 52)))
        waiting = challenge(NEXT_TOKEN, issued=15_119)
        first = 15_052 * NS_PER_MS
        for prep, valid in ((3_052 * NS_PER_MS, True), (3_052 * NS_PER_MS + 1, False)):
            result = policy_result(elapsedMs=15_052, navigationIssuedAtNs=5_002 * NS_PER_MS,
                                   preparationStartedAtNs=prep, preparationDeadlineAtNs=prep + 15_000 * NS_PER_MS,
                                   observationCutoffMs=2_061, timelineMs={"loadIssued": 2_001, "policyRejection": 2_039})
            prefix = active + result
            invalid = None if valid else "outside the target interval"
            self.assert_snapshot_paths(f"policy-watch-ready-{prep}", prefix + waiting, verified=prefix,
                                       renews=valid, invalid=invalid)
            for requested in (5_052 * NS_PER_MS + 1, 5_054 * NS_PER_MS):
                retired = policy_retirement(requested, first, 15_120 * NS_PER_MS)
                self.assert_snapshot_paths(f"policy-watch-finished-{prep}-{requested}", prefix + waiting + retired,
                                           verified=prefix, invalid=invalid)

    def test_terminal_policy_and_live_failure_cannot_share_a_timeline(self):
        active = READY + RESERVED + DISPATCH
        failure = {"errorDomain": "NSURLErrorDomain", "errorCode": -1003}
        waiting = challenge(NEXT_TOKEN, issued=3_091)
        # The first rejection can be nonclosing. Neither callback order,
        # including equal clocks, permits both terminal events while live.
        for failed_at in (59, 48, 49):
            result = policy_result(timelineMs={"loadIssued": 1, "policyRejection": 49, "navigationFailure": failed_at},
                                   **failure)
            self.assert_snapshot_paths(f"closing-callbacks-frozen-{failed_at}", active + result + waiting,
                                       verified=active, invalid="Terminal navigation policy conflicts with live navigation failure")

        terminal = "additional-top-level-navigation"
        frozen = {"loadIssued": 1, "policyRejection": 19_998}
        window = {"observationCutoffMs": 20_001, "observedThroughAtNs": 23_025 * NS_PER_MS, "elapsedMs": 23_030}
        waiting = challenge(NEXT_TOKEN, issued=23_031)
        for name, fields in (
                ("late-failure", {"timelineMs": frozen, "observedAfterCutoff": failure | {
                    "timelineMs": {"navigationFailure": 20_009}}}),
                ("late-policy", {"timelineMs": frozen | {"navigationFailure": 19_999}, **failure,
                                 "localPolicyRejection": "unsupported-mime-type",
                                 "observedAfterCutoff": {"localPolicyRejection": terminal}}),
                ("late-tie", {"timelineMs": {"loadIssued": 1}, "outcome": "timeout", "errorDomain": None,
                              "errorCode": None, "localPolicyRejection": None, "observedAfterCutoff": failure | {
                                  "localPolicyRejection": terminal,
                                  "timelineMs": {"policyRejection": 20_009, "navigationFailure": 20_009}}})):
            result = policy_result(**window, **fields)
            invalid = ("Live WebKit callbacks cannot follow terminal navigation policy" if name == "late-failure"
                       else "Terminal navigation policy conflicts with live navigation failure")
            self.assert_snapshot_paths(f"closing-callbacks-{name}", active + result + waiting, verified=active,
                                       invalid=invalid)

    def test_policy_and_failure_keep_nonclosing_and_original_callback_controls(self):
        active = READY + RESERVED + DISPATCH
        waiting = challenge(NEXT_TOKEN, issued=3_091)
        terminal = active + policy_result() + waiting
        self.assert_snapshot_paths("terminal-policy-alone", terminal, renews=True)
        failure = {"errorDomain": "NSURLErrorDomain", "errorCode": -1003}
        retirement = stage("retirement", elapsedMs=3_180, retirementState="confirmed", transportQuiesced=True,
                           retirementRequestedAtMs=60, retirementObservedMs=109,
                           retirementFirstPolledAtNs=3_090 * NS_PER_MS, retirementCommitAtMs=119,
                           transportQuiescedAtMs=139, originalNavigationAfterClose={
                               "timelineMs": {"navigationFailure": 109}, **failure})
        self.assert_snapshot_paths("terminal-policy-original-failure", terminal + retirement, renews=True)

        regular = policy_result(localPolicyRejection="unsupported-mime-type", **failure,
                                timelineMs={"loadIssued": 1, "policyRejection": 49, "navigationFailure": 59})
        self.assert_snapshot_paths("nonclosing-policy-live-failure", active + regular + waiting, renews=True)

    def test_first_retirement_sample_cannot_wait_past_the_original_close_window(self):
        active = READY + RESERVED + DISPATCH
        token = TOKEN.replace(b"f48", b"f38")
        waiting = challenge(token, issued=13_064)
        for written, prior_close_permit, valid in ((13_061, False, True), (13_062, False, False),
                                                   (13_063, False, False), (13_061, True, False)):
            result = stage("result", outcome="failed", documentCommitted=False, documentFinished=False,
                           navigationIssued=True, observationCutoffMs=61, elapsedMs=written,
                           errorDomain="NSURLErrorDomain", errorCode=-1003,
                           timelineMs={"loadIssued": 1, "navigationFailure": 59})
            closing = challenge(NEXT_TOKEN, issued=3_061) if prior_close_permit else b""
            verified = active + closing + result
            self.assert_snapshot_paths(f"original-close-{written}-{prior_close_permit}", verified + waiting,
                                       verified=verified, token=token, renews=valid,
                                       invalid=None if valid else "outside the target interval")
            if valid:
                retirement = stage("retirement", elapsedMs=13_120, retirementState="unconfirmed",
                                   transportQuiesced=False, retirementRequestedAtMs=61, retirementObservedMs=10_050,
                                   retirementFirstPolledAtNs=13_061 * NS_PER_MS)
                self.assert_snapshot_paths("already-sleeping-at-deadline", verified + waiting + retirement)

    def test_proven_close_renewal_bounds_the_first_retirement_sample_in_a_prefix(self):
        sample, _ = target_drain_fixture()
        result = sample.splitlines(keepends=True)[-1]
        active = READY + RESERVED + DISPATCH
        token = TOKEN.replace(b"f48", b"f38")
        waiting = challenge(token, issued=13_069)
        for issued, written, requested, valid in ((3_067, 13_066, 3_067, True), (3_067, 13_067, 3_067, False),
                                                  (3_067, 13_068, 3_067, False), (3_048, 13_048, 3_067, True)):
            # At the observation clock, the permit also fits a final live check.
            closing = challenge(NEXT_TOKEN, issued=issued)
            verified = active + closing + change_row(result, elapsedMs=written, elapsedNs=written * NS_PER_MS)
            self.assert_snapshot_paths(f"close-bound-prefix-{written}", verified + waiting, verified=verified,
                                       token=token, renews=valid, invalid=None if valid else "outside the target interval")
            retirement = stage("retirement", elapsedMs=13_200, retirementState="unconfirmed", transportQuiesced=False,
                               retirementRequestedAtMs=requested - 3_001, retirementObservedMs=10_060,
                               retirementFirstPolledAtNs=written * NS_PER_MS)
            self.assert_snapshot_paths(f"close-bound-retired-{written}", verified + waiting + retirement, token=token,
                                       verified=verified, invalid=None if valid else "outside the target interval")

    def test_preparation_failure_cannot_reach_a_load_attempt_or_binding(self):
        active = READY + RESERVED
        waiting = challenge(NEXT_TOKEN, issued=3_061)
        for failed_preparation in (False, True):
            timeline = {"loadNotAccepted": 50}
            failure = {}
            if failed_preparation:
                timeline["preparationFailure"] = 5
                failure = {"errorDomain": "Aegis", "errorCode": 1}
            result = stage("result", outcome="failed", navigationIssued=False, documentCommitted=False,
                           documentFinished=False, actualProtocol="socks5", localLoadDisposition="load-not-accepted",
                           observationCutoffMs=55, elapsedMs=3_060, timelineMs=timeline, **failure)
            self.assert_snapshot_paths(f"preparation-load-{failed_preparation}", active + result + waiting,
                                       verified=active, renews=not failed_preparation,
                                       invalid="failure milestone disagrees with the navigation phase"
                                       if failed_preparation else None)

        for bound in (False, True):
            result = stage("result", outcome="stopped", stopReason="external-stop", navigationIssued=False,
                           documentCommitted=False, documentFinished=False, actualProtocol="socks5" if bound else "unbound",
                           preparationDeadlineAtNs=18_001 * NS_PER_MS, observationCutoffMs=55, elapsedMs=3_060,
                           errorDomain="Aegis", errorCode=1, timelineMs={"preparationFailure": 5})
            self.assert_snapshot_paths(f"preparation-binding-{bound}", active + result, verified=active,
                                       invalid="failure milestone disagrees with the navigation phase" if bound else None)

    def test_published_unbound_page_can_retire_before_the_preparation_catch(self):
        active = READY + RESERVED
        evidence = dict(outcome="failed", navigationIssued=False, documentCommitted=False, documentFinished=False,
                        errorDomain="Aegis", errorCode=1, timelineMs={"preparationFailure": 2_999},
                        observationCutoffMs=3_004, elapsedMs=6_006)
        first = 6_006 * NS_PER_MS
        for prep, requested, valid in (
                (3_001, 5_501 * NS_PER_MS, True),
                (3_001, 4_999 * NS_PER_MS, False),
                (3_001, 5_001 * NS_PER_MS - 1, False),
                (3_001, 5_001 * NS_PER_MS, True),
                (3_001, 5_001 * NS_PER_MS + 1, True),
                (3_001, 6_000 * NS_PER_MS, True),
                (3_001, 6_000 * NS_PER_MS + 1, True),
                (None, 5_501 * NS_PER_MS, False),
                (None, 6_000 * NS_PER_MS, True)):
            preparation = {} if prep is None else {"preparationDeadlineAtNs": (prep + 15_000) * NS_PER_MS}
            prefix = active + stage("result", **evidence, **preparation)
            if requested == 5_501 * NS_PER_MS:
                self.assert_snapshot_paths(f"publisher-catch-prefix-{prep}", prefix, token=TOKEN, renews=True)
            retired = unbound_retirement(requested, first)
            self.assert_snapshot_paths(f"publisher-catch-{prep}-{requested}", prefix + retired,
                                       verified=prefix, token=TOKEN, renews=valid,
                                       invalid=None if valid else "outside the target interval")
            if valid:
                attempt = read_campaign_receipt(prefix + retired, TARGETS, IDENTITY, LIMITS).attempts[0]
                self.assertFalse(attempt.dispatch_confirmed)
                self.assertEqual(attempt.evidence["actualProtocol"], "unbound")

        twice_failed = stage(
            "result", **(evidence | {
                "elapsedMs": 18_003, "observationCutoffMs": 15_000, "preparationDeadlineAtNs": 18_001 * NS_PER_MS,
                "localPreparationDisposition": "preparation-timeout",
                "timelineMs": {"preparationFailure": 2_999, "preparationTimedOut": 15_000},
            }))
        self.assert_snapshot_paths("catch-and-timeout-cannot-both-close", active + twice_failed, verified=active,
                                   invalid="failure milestone disagrees with the navigation phase")

    def test_publisher_request_before_preparation_failure_has_an_exclusive_deadline(self):
        deadline = 18_001 * NS_PER_MS
        failure = 18_002 * NS_PER_MS
        first = 18_006 * NS_PER_MS
        active = READY + RESERVED
        fields = dict(outcome="failed", navigationIssued=False, documentCommitted=False, documentFinished=False,
                      observationCutoffMs=15_000, observedThroughAtNs=18_005 * NS_PER_MS, elapsedMs=18_006,
                      preparationDeadlineAtNs=deadline)
        result = stage("result", **fields, observedAfterCutoff={
            "timelineMs": {"preparationFailure": 15_001}, "errorDomain": "Aegis", "errorCode": 1})
        prefix = active + result
        self.assert_snapshot_paths("late-failure-prefix", prefix, token=TOKEN, renews=True)
        for name, requested, valid in (("before-deadline", deadline - 1, True), ("at-deadline", deadline, False),
                                       ("past-deadline", deadline + 1, False), ("catch-stamp-tie", failure, True),
                                       ("catch-records-then-closes", failure + 1, True)):
            self.assert_snapshot_paths(name, prefix + unbound_retirement(requested, first), verified=prefix,
                                       token=TOKEN, renews=valid, invalid=None if valid else "outside the target interval")

        timed_out = stage("result", **fields, timelineMs={"preparationTimedOut": 15_000},
                          localPreparationDisposition="preparation-timeout")
        self.assert_snapshot_paths("timeout-request-at-deadline", active + timed_out + unbound_retirement(deadline, first),
                                   token=TOKEN, renews=True)

    def test_late_preparation_failure_orders_the_whole_permit_publication(self):
        request, deadline, failure, first = (at * NS_PER_MS for at in (17_999, 18_001, 18_002, 18_006))
        fields = dict(outcome="failed", navigationIssued=False, documentCommitted=False, documentFinished=False,
                      observationCutoffMs=15_000, observedThroughAtNs=18_005 * NS_PER_MS,
                      elapsedMs=18_006, preparationDeadlineAtNs=deadline)
        error = {"errorDomain": "Aegis", "errorCode": 1}
        result = stage("result", **fields, observedAfterCutoff=error | {"timelineMs": {"preparationFailure": 15_001}})
        outside = "outside the target interval"
        for name, issued, written, requested, prefix_valid, complete_valid in (
                ("poll-at-deadline", deadline, deadline, request, False, False),
                ("poll-before-deadline", deadline - 1, deadline - 1, request, True, True),
                ("append-at-deadline", deadline - 1, deadline, request, False, False),
                ("append-ties-failure", deadline - 1, failure, request, False, False),
                ("issued-at-failure-after-earlier-request", failure, failure + 1, request, True, True),
                ("poll-ties-failure-and-catch-close", failure, failure, failure, True, True),
                ("poll-ties-failure-before-catch-close", failure, failure, failure + 1, True, False),
                ("poll-after-catch-close", failure + 2, failure + 2, failure + 1, True, True)):
            permit = change_row(challenge(NEXT_TOKEN, issued_ns=issued),
                                elapsedNs=written, elapsedMs=written // NS_PER_MS)
            active = READY + RESERVED + permit
            prefix = active + result
            self.assert_snapshot_paths(f"{name}-prefix", prefix, verified=active, renews=prefix_valid,
                                       invalid=None if prefix_valid else outside)
            retired = unbound_retirement(requested, first)
            self.assert_snapshot_paths(name, prefix + retired, verified=prefix if prefix_valid else active,
                                       renews=complete_valid, invalid=None if complete_valid else outside)

        tied_failure = stage("result", **fields, **error, timelineMs={"preparationFailure": 15_000})
        for issued, valid in ((deadline - 1, False), (deadline, True)):
            permit = change_row(challenge(NEXT_TOKEN, issued_ns=issued), elapsedNs=deadline, elapsedMs=18_001)
            active = READY + RESERVED + permit
            prefix = active + tied_failure
            for tail in (b"", unbound_retirement(request, first)):
                self.assert_snapshot_paths(f"failure-ties-deadline-{issued}-{bool(tail)}", prefix + tail,
                                           verified=active, renews=valid, invalid=None if valid else outside)

        health = row(
            "health", phase="before-first-target", outcome="failed", navigationIssued=False,
            documentCommitted=False, documentFinished=False, preparationDeadlineAtNs=15_010 * NS_PER_MS,
            observationCutoffMs=15_000, observedThroughAtNs=15_014 * NS_PER_MS, elapsedMs=15_016,
            observedAfterCutoff=error | {"timelineMs": {"preparationFailure": 15_001}},
            retirementState="unbound", retirementRequestedAtMs=14_998, retirementObservedMs=7,
            retirementFirstPolledAtNs=15_015 * NS_PER_MS, transportQuiesced=True, transportQuiescedAtMs=15_005)
        for delta in (-1, 0):
            active = GRANTED + challenge(NEXT_TOKEN, issued_ns=15_010 * NS_PER_MS + delta)
            self.assert_snapshot_paths(f"health-poll-at-catch-cutoff-{delta}", active + health, verified=active,
                                       invalid=None if delta < 0 else "outside the health probe interval")

    def test_late_preparation_failure_distinguishes_actor_and_worker_stops(self):
        page, deadline, failure, first = (at * NS_PER_MS for at in (3_001, 18_001, 18_002, 18_006))
        evidence = {"errorDomain": "Aegis", "errorCode": 1, "timelineMs": {"preparationFailure": 15_001}}
        active = READY + RESERVED
        outside = "outside the target interval"
        for name, reason, stop_at, requested, prefix_valid, complete_valid in (
                ("watch-stop-before-deadline", "external-stop", deadline - 1, deadline - 1, True, True),
                ("watch-stop-at-deadline", "external-stop", deadline, 17_999 * NS_PER_MS, False, False),
                ("actor-stop-inside-catch", "external-stop", deadline + 1, 17_999 * NS_PER_MS, False, False),
                ("final-stop-ties-catch-close", "external-stop", failure, failure, True, True),
                ("final-stop-cannot-precede-catch-close", "external-stop", failure, failure + 1, True, False),
                ("worker-stop-inside-catch", "metering-failure", deadline + 1, failure + 1, True, True)):
            cutoff = min(stop_at, deadline)
            late = dict(evidence)
            if stop_at > cutoff:
                late |= {"stopReason": reason, "stopAtNs": stop_at, "stopAtMs": (stop_at - page) // NS_PER_MS}
            charged = int(reason == "metering-failure")
            result = stage(
                "result", outcome="stopped" if stop_at == cutoff else "failed",
                stopReason=reason if stop_at == cutoff else None,
                navigationIssued=False, documentCommitted=False, documentFinished=False,
                preparationDeadlineAtNs=deadline, observationCutoffAtNs=cutoff,
                observationCutoffMs=(cutoff - page) // NS_PER_MS, observedThroughAtNs=18_005 * NS_PER_MS,
                elapsedMs=18_006, chargedBytes=charged, observedAfterCutoff=late)
            prefix = active + result
            self.assert_snapshot_paths(f"{name}-prefix", prefix, verified=active,
                                       invalid=None if prefix_valid else outside)
            retired = change_row(unbound_retirement(requested, first), chargedBytes=charged)
            self.assert_snapshot_paths(name, prefix + retired, verified=prefix if prefix_valid else active,
                                       invalid=None if complete_valid else outside)

    def test_unbound_publisher_request_respects_watch_and_fence_readiness(self):
        failure = stage(
            "result", outcome="failed", navigationIssued=False, documentCommitted=False, documentFinished=False,
            errorDomain="Aegis", errorCode=1, timelineMs={"preparationFailure": 4_999}, observationCutoffMs=5_000,
            preparationDeadlineAtNs=18_001 * NS_PER_MS, elapsedMs=8_002)
        for name, times, request_ns, valid in (
                ("retiring-turn-publishes", ((1, 1), (2, 2)), 5_501 * NS_PER_MS, True),
                ("next-watch-too-early", ((1, 1), (2, 2), (100, 100)), 7_001 * NS_PER_MS - 1, False),
                ("next-watch-is-ready", ((1, 1), (2, 2), (100, 100)), 7_001 * NS_PER_MS, True),
                ("cancelled-watch", ((502, 502), (503, 503)), 5_501 * NS_PER_MS, False),
                ("next-fence-is-ready", ((502, 502), (552, 552)), 5_501 * NS_PER_MS, True)):
            prefix = READY + RESERVED + permit_series(5_000, times) + failure
            token = TOKEN.replace(b"f48", f"{len(times) - 1:03x}".encode())
            self.assert_snapshot_paths(f"before-watch-request-{name}", prefix, token=token, renews=True)
            retired = unbound_retirement(request_ns, 8_002 * NS_PER_MS)
            self.assert_snapshot_paths(name, prefix + retired, verified=prefix, token=token, renews=valid,
                                       invalid=None if valid else "outside the target interval")

    def test_unbound_publisher_stop_can_precede_the_request_but_not_follow_it(self):
        active = READY + RESERVED
        for stop_at, request_at, prefix_valid, complete_valid in (
                (5_000, 5_501, False, False),
                (5_500, 5_501, True, True),
                (5_501, 5_501, True, True),
                (5_502, 5_501, True, False),
                (5_500, 6_000, True, True)):
            result = stage(
                "result", outcome="stopped", stopReason="external-stop", navigationIssued=False,
                documentCommitted=False, documentFinished=False, elapsedMs=6_006,
                preparationDeadlineAtNs=18_001 * NS_PER_MS, observationCutoffMs=stop_at - 3_001,
                observedThroughAtNs=6_005 * NS_PER_MS,
                observedAfterCutoff={"errorDomain": "Aegis", "errorCode": 1, "timelineMs": {"preparationFailure": 2_999}})
            prefix = active + result
            retired = unbound_retirement(request_at * NS_PER_MS, 6_006 * NS_PER_MS)
            for tail, valid in ((b"", prefix_valid), (retired, complete_valid)):
                self.assert_snapshot_paths(f"unbound-watch-stop-{stop_at}-{request_at}-{bool(tail)}", prefix + tail,
                                           verified=prefix if prefix_valid else active, token=TOKEN,
                                           invalid=None if valid else "outside the target interval")

        for reason, valid in (("run-control-unavailable", True), ("external-stop", False)):
            permits = permit_series(5_000, ((1, 1), (2, 2)))
            stopped = stage(
                "result", outcome="stopped", stopReason=reason, navigationIssued=False,
                documentCommitted=False, documentFinished=False, elapsedMs=6_006,
                preparationDeadlineAtNs=18_001 * NS_PER_MS, observationCutoffMs=2_499,
                observedThroughAtNs=6_005 * NS_PER_MS,
                observedAfterCutoff={"errorDomain": "Aegis", "errorCode": 1, "timelineMs": {"preparationFailure": 2_999}})
            retired = unbound_retirement(5_501 * NS_PER_MS, 6_006 * NS_PER_MS)
            active_with_permits = active + permits
            for tail in (b"", retired):
                self.assert_snapshot_paths(f"watch-permit-then-{reason}-{bool(tail)}", active_with_permits + stopped + tail,
                                           verified=active_with_permits, invalid=None if valid else "outside the target interval")

    def test_unbound_watch_can_retire_after_backdated_timeout_but_before_its_handler(self):
        page, deadline, observed, written = 3_001, 18_001, 18_200, 18_210
        timeout = dict(timelineMs={"preparationTimedOut": 15_000}, localPreparationDisposition="preparation-timeout")
        earlier_watch = permit_series(17_000, ((0, 0), (1, 1), (100, 100)))
        outside = "outside the target interval"
        for name, stop_at, requested, permits, prefix_valid, complete_valid in (
                ("watch-early-stop-late-request", 17_990, 18_030, b"", True, True),
                ("watch-after-deadline", 18_020, 18_030, b"", True, True),
                ("watch-request-ties-observation", 18_020, observed, b"", True, True),
                ("watch-after-deadline-still-asleep", 18_020, 18_030, earlier_watch, True, False),
                ("fence-closed-before-timeout", 17_990, 12_001, b"", True, False),
                ("fence-or-final-after-timeout", 18_020, 12_001, b"", True, True),
                ("stop-before-first-watch", 5_000, 12_001, b"", False, False)):
            stop = dict(stopReason="external-stop", stopAtMs=stop_at - page)
            evidence = (dict(outcome="stopped", stopReason="external-stop", timelineMs={}, observedAfterCutoff=timeout)
                        if stop_at < deadline else dict(outcome="failed", observedAfterCutoff=stop) | timeout)
            result = stage(
                "result", navigationIssued=False, documentCommitted=False, documentFinished=False,
                preparationDeadlineAtNs=deadline * NS_PER_MS, observationCutoffMs=min(stop_at, deadline) - page,
                observedThroughAtNs=observed * NS_PER_MS, elapsedMs=written, **evidence)
            active = READY + RESERVED + permits
            prefix = active + result
            retired = unbound_retirement(requested * NS_PER_MS, written * NS_PER_MS)
            self.assert_snapshot_paths(f"{name}-prefix", prefix, verified=active, invalid=None if prefix_valid else outside)
            self.assert_snapshot_paths(name, prefix + retired, verified=prefix if prefix_valid else active,
                                       invalid=None if complete_valid else outside)

    def test_missing_load_on_a_bound_page_requires_the_winning_stop_in_the_result(self):
        active = READY + RESERVED
        result = stage("result", outcome="failed", navigationIssued=False, documentCommitted=False,
                       documentFinished=False, actualProtocol="socks5")
        waiting = challenge(NEXT_TOKEN, issued=3_301)
        for tail in (b"", waiting):
            self.assert_snapshot_paths(f"bound-without-stop-{bool(tail)}", active + result + tail, verified=active,
                                       invalid="bound page without a load attempt requires a stop")
        stopped = stage("result", outcome="stopped", navigationIssued=False, documentCommitted=False,
                        documentFinished=False, actualProtocol="socks5", stopReason="node-revision-changed")
        self.assert_snapshot_paths("bound-with-pin-stop", active + stopped)
        unbound = stage("result", outcome="failed", navigationIssued=False, documentCommitted=False,
                        documentFinished=False, preparationDeadlineAtNs=18_001 * NS_PER_MS)
        self.assert_snapshot_paths("unbound-preparation-can-wait", active + unbound + waiting, renews=True)

    def test_retirement_request_cannot_interrupt_the_dispatch_append(self):
        page, written, first, exit_at = (at * NS_PER_MS for at in (3_001, 23_002, 23_004, 23_054))
        dispatch = stage("dispatch", elapsedNs=written)
        result = stage("result", elapsedNs=first, outcome="timeout", navigationIssued=True,
                       documentCommitted=False, documentFinished=False, errorDomain=None, errorCode=None,
                       observationCutoffMs=20_001, observedThroughAtNs=23_003 * NS_PER_MS)
        prefix = READY + RESERVED + dispatch + result
        self.assert_snapshot_paths("slow-dispatch-result-only", prefix, token=TOKEN, renews=True)

        def original_commit(at):
            return {"timelineNs": {"documentCommit": at - page},
                    "timelineMs": {"documentCommit": (at - page) // NS_PER_MS}}

        def retirement(requested, original):
            retired = policy_retirement(requested, first, exit_at, commit_ns=23_024 * NS_PER_MS)
            return change_row(retired, originalNavigationAfterClose=original)

        early = original_commit(23_001 * NS_PER_MS) | {"serverRedirectCount": 0}
        self.assert_snapshot_paths("retirement-during-slow-dispatch",
                                   prefix + retirement(23_000 * NS_PER_MS, early), verified=prefix, token=TOKEN,
                                   invalid="Missing native retirement start")

        for adjustment in (-1, 0, 1):
            for name, original in (
                    ("no-callback", None),
                    ("redirect-only", add_timeline_instants({"timelineMs": {}, "serverRedirectCount": 1})),
                    ("timestamp-only", original_commit(23_005 * NS_PER_MS))):
                valid = adjustment >= 0
                self.assert_snapshot_paths(f"dispatch-request-{adjustment}-{name}",
                                           prefix + retirement(written + adjustment, original),
                                           verified=prefix, token=TOKEN, renews=valid,
                                           invalid=None if valid else "Missing native retirement start")

        self.assert_snapshot_paths("original-callback-before-valid-request",
                                   prefix + retirement(written, original_commit(written - 1)),
                                   verified=prefix, token=TOKEN, invalid="outside their observation interval")

    def test_dispatch_append_order_disambiguates_load_polls_on_clock_ties(self):
        sample, retirement = target_drain_fixture()
        _, result, _ = sample.rsplit(b"\n", 2)
        result += b"\n"
        dispatch = stage("dispatch", elapsedMs=3_002)
        permit = challenge(NEXT_TOKEN, issued=3_002)
        token = TOKEN.replace(b"f48", b"f38")
        for before_dispatch, at, valid in ((False, 3_051, False), (False, 3_052, True), (True, 3_051, True)):
            rows = permit + dispatch if before_dispatch else dispatch + permit
            prefix = READY + RESERVED + rows + result
            for retired in (b"", retirement):
                self.assert_snapshot_paths(f"dispatch-tie-{before_dispatch}-{at}-{bool(retired)}",
                                           prefix + challenge(token, issued=at) + retired, verified=prefix,
                                           token=token, renews=valid,
                                           invalid=None if valid else "outside the target interval")
        tied_fence_pair = READY + RESERVED + dispatch + permit_series(3_002, ((0, 0), (0, 0))) + result
        self.assert_snapshot_paths("dispatch-tied-live-control", tied_fence_pair + challenge(token, issued=3_052),
                                   token=token, renews=True)

        tied_result = stage("result", elapsedMs=3_050, outcome="finished", navigationIssued=True,
                            documentCommitted=True, documentFinished=True, observationCutoffMs=1,
                            timelineMs={"loadIssued": 1, "documentCommit": 1, "documentFinish": 1})
        for count in (3, 4):
            before_result = READY + RESERVED + permit_series(3_002, ((0, 0),) * count) + dispatch
            self.assert_snapshot_paths(f"dispatch-before-final-{count}", before_result + tied_result,
                                       verified=before_result, token=TOKEN.replace(b"f48", b"002"), renews=count == 3,
                                       invalid="outside the target interval" if count == 4 else None)

    def test_observation_tie_can_place_a_close_poll_without_delaying_the_first_wait(self):
        sample, retirement = target_drain_fixture()
        _, result, _ = sample.rsplit(b"\n", 2)
        result += b"\n"
        retirement = change_row(retirement, retirementRequestedAtMs=47,
                                retirementRequestedAtNs=3_048 * NS_PER_MS, retirementObservedMs=112)
        waiting = challenge(NEXT_TOKEN, issued=3_051)
        final = ((46, 46), (47, 47))
        for close, valid in ((((48, 48),), True), (((47, 48),), False), (((48, 48), (48, 48)), False)):
            prefix = READY + RESERVED + DISPATCH + permit_series(3_000, final + close) + result
            for retired in (b"", retirement):
                self.assert_snapshot_paths(f"observation-tie-{len(close)}-{close[0][0]}-{bool(retired)}",
                                           prefix + waiting + retired, verified=prefix, renews=valid,
                                           invalid=None if valid else "outside the target interval")

        failed = stage("result", elapsedMs=3_050, observationCutoffMs=47, outcome="failed", navigationIssued=True,
                       documentCommitted=False, documentFinished=False, errorDomain="WKErrorDomain", errorCode=2,
                       timelineMs={"loadIssued": 1, "navigationFailure": 44})
        already_closed = READY + RESERVED + DISPATCH + permit_series(3_000, final + ((48, 48),)) + failed
        self.assert_snapshot_paths("observation-tie-already-closed", already_closed + waiting, verified=already_closed,
                                   invalid="outside the target interval")
        self.assert_snapshot_paths("observation-tie-later-fence", already_closed + challenge(NEXT_TOKEN, issued=3_097),
                                   renews=True)

        for phase, prefix, origin, _ in probe_fixtures():
            targets = TIMEOUT_TARGETS if origin else TARGETS
            limits = replace(LIMITS, targets=len(targets))
            health = sequenced_probe(phase, origin, retirementRequestedAtMs=65,
                                     retirementFirstPolledAtNs=(origin + 75) * NS_PER_MS, retirementObservedMs=115)
            # The final checks, close and the first waiting poll share a clock.
            token = TOKEN.replace(b"f48", b"004")
            for next_poll in (124, 125):
                rows = prefix + permit_series(origin, ((75, 75),) * 4 + ((next_poll, next_poll),))
                self.assert_snapshot_paths(f"all-probe-boundaries-tie-{origin}-{next_poll}", rows + health,
                                           verified=rows, targets=targets, limits=limits, token=token,
                                           renews=next_poll == 125 and not origin,
                                           invalid="outside the health probe interval" if next_poll == 124 else None)

    def test_same_clock_retirement_callback_orders_the_wait_publication(self):
        for phase, prefix, origin, read in probe_fixtures():
            for issued, at, valid in ((125, 130, False), (126, 130, True), (125, 176, True)):
                permit = challenge(NEXT_TOKEN, issued=origin + issued, appended=origin + 126)
                health = sequenced_probe(
                    phase, origin, retirementCommitAtMs=116, transportQuiescedAtMs=230,
                    retirementObservedMs=160, haltDuringRetirement={
                        "stopReason": "run-control-unavailable", "stopAtMs": at - 10})
                with self.subTest(phase=phase, issued=issued, stop=at):
                    if valid:
                        self.assertTrue(read(prefix + permit + health).halted)
                    else:
                        with self.assertRaisesRegex(ValueError, "outside the health probe interval"):
                            read(prefix + permit + health)

    def test_prepared_probe_permits_fit_fence_publisher_and_final_calls(self):
        for phase, prefix, origin, read in probe_fixtures():
            health = sequenced_probe(phase, origin)
            failed = sequenced_probe(
                phase, origin, outcome="failed", documentFinished=False, errorDomain="NSURLErrorDomain", errorCode=-1003,
                timelineMs={"loadIssued": 10, "firstVisibleHTTPResponse": 22, "documentCommit": 30, "navigationFailure": 50},
                retirementRequestedAtMs=55, retirementObservedMs=125)
            delayed = sequenced_probe(
                phase, origin, elapsedMs=origin + 4_400, observationCutoffMs=4_200,
                timelineMs={"loadIssued": 10, "firstVisibleHTTPResponse": 4_100,
                            "documentCommit": 4_110, "documentFinish": 4_120},
                retirementRequestedAtMs=4_210, retirementFirstPolledAtNs=(origin + 4_220) * NS_PER_MS,
                retirementCommitAtMs=4_255, transportQuiescedAtMs=4_260, retirementObservedMs=60)
            late_load = change_row(
                delayed, navigationIssuedAtNs=(origin + 4_050) * NS_PER_MS,
                timelineMs=json.loads(delayed)["timelineMs"] | {"loadIssued": 4_040},
                timelineNs=json.loads(delayed)["timelineNs"] | {"loadIssued": 4_040 * NS_PER_MS})
            finish_at_observation = sequenced_probe(phase, origin, observationCutoffMs=40)
            first_watch = ((2_050, 2_051), (2_052, 2_052), (2_053, 2_053))
            for sample, times, valid in (
                    (health, ((21, 21), (22, 22)), True),
                    (health, ((21, 21), (22, 22), (23, 23)), False),
                    (health, ((21, 21), (51, 51), (52, 52)), True),
                    (health, ((11, 12), (16, 16), (17, 17), (18, 18)), True),
                    (health, ((11, 12), (16, 16), (17, 17), (18, 18), (19, 19)), False),
                    (failed, ((65, 65), (66, 66), (67, 67)), True),
                    (failed, ((65, 65), (66, 66), (67, 67), (68, 68)), False),
                    (finish_at_observation, ((41, 41), (42, 42), (43, 43)), False),
                    (finish_at_observation, ((41, 41), (42, 42), (50, 50)), True),
                    (delayed, first_watch, True),
                    (delayed, first_watch + ((2_103, 2_103), (2_104, 2_104), (2_105, 2_105)), False),
                    (delayed, first_watch + ((4_053, 4_053), (4_054, 4_054), (4_055, 4_055)), True),
                    (late_load, first_watch[:2] + ((4_047, 4_047), (4_048, 4_048)), True),
                    (late_load, first_watch + ((4_047, 4_047), (4_048, 4_048)), False)):
                with self.subTest(phase=phase, times=times):
                    native = prefix + permit_series(origin, times) + sample
                    if valid:
                        read(native)
                    else:
                        with self.assertRaisesRegex(ValueError, "outside the health probe interval"):
                            read(native)

        result = stage("result", outcome="finished", navigationIssued=True, documentCommitted=True,
                       documentFinished=True, firstVisibleHTTPStatus=200, lastHTTPStatus=200,
                       timelineMs={"loadIssued": 1, "firstVisibleHTTPResponse": 31,
                                   "documentCommit": 35, "documentFinish": 38}, observationCutoffMs=74)
        target = READY + RESERVED + DISPATCH
        pair = ((21, 21), (22, 22))
        self.observe("two-fence-calls", target + permit_series(3_000, pair) + result)
        self.observer = self.open_observer("impossible-live-polls.json")
        bad = target + permit_series(3_000, pair + ((23, 23),))
        with self.assertRaisesRegex(LedgerObservationUnavailable, "outside the target interval"):
            self.reconcile(bad + result, bad + result)
        self.assertEqual(self.observer.observed_prefix, bad)

    def test_early_close_renewal_allows_a_later_fence_and_final_direct_call(self):
        result = stage("result", outcome="failed", navigationIssued=True, documentCommitted=False,
                       documentFinished=False, observationCutoffMs=99, timelineMs={"loadIssued": 1, "navigationFailure": 49},
                       errorDomain="NSURLErrorDomain", errorCode=-1003)
        permits = ((40, 40), (42, 42), (52, 52), (92, 92), (93, 93))
        prefix = READY + RESERVED + DISPATCH + permit_series(3_000, permits) + result
        retirement = stage("retirement", retirementState="confirmed", transportQuiesced=True,
                           **(WITNESSES | {"retirementRequestedAtMs": 50}))
        self.observe("early-close-drain", prefix)
        self.assertEqual(self.reconcile(prefix + retirement, prefix + retirement).remaining_targets(TARGETS), TARGETS[1:])

    def test_live_poll_can_make_one_terminal_transport_loss_call(self):
        for phase, prefix, origin, read in probe_fixtures():
            for poll, stamps, stopped, observed in (
                    ("fence", (51, 52, 53), 54, 150),
                    ("watch", (2_050, 2_051, 2_052, 2_053), 2_054, 2_150)):
                permits = permit_series(origin, tuple((at, at) for at in stamps))
                health = row(
                    "health", phase=phase, elapsedMs=origin + observed + 30, outcome="stopped",
                    navigationIssued=True, navigationIssuedAtNs=(origin + 20) * NS_PER_MS,
                    documentCommitted=False, documentFinished=False, timelineMs={"loadIssued": 10},
                    preparationStartedAtNs=(origin + 14) * NS_PER_MS, preparationDeadlineAtNs=(origin + 15_014) * NS_PER_MS,
                    stopReason="transport-lost", observationCutoffMs=stopped - 10,
                    observedThroughAtNs=(origin + observed) * NS_PER_MS,
                    retirementState="confirmed", retirementRequestedAtMs=stopped - 9, retirementCommitAtMs=observed - 20,
                    retirementObservedMs=observed - stopped + 9, transportQuiescedAtMs=observed - 10,
                    transportQuiesced=True,
                )
                with self.subTest(phase=phase, poll=poll):
                    self.assertTrue(read(prefix + permits + health).halted)
                    with self.assertRaisesRegex(ValueError, "outside the health probe interval"):
                        read(prefix + permits + change_row(health, stopReason="node-revision-changed"))

    def test_synchronous_failure_gap_applies_to_permits_and_actor_stops(self):
        for phase, prefix, origin, read in probe_fixtures():
            for marker in ("navigationFailure", "loadNotAccepted", "preparationFailure"):
                dispatched = marker == "navigationFailure"
                bound = marker != "preparationFailure"
                milestones = ({"loadIssued": 10} if dispatched else {}) | {marker: 50}
                binding = ({"navigationIssuedAtNs": (origin + 20) * NS_PER_MS} if dispatched else {})
                failure = ({"localLoadDisposition": "load-not-accepted"} if marker == "loadNotAccepted"
                           else {"errorDomain": "NSURLErrorDomain", "errorCode": -1003})
                retirement = ({"retirementCommitAtMs": 145, "retirementObservedMs": 125,
                               "retirementFirstPolledAtNs": (origin + 110) * NS_PER_MS,
                               "transportQuiescedAtMs": 160} if bound else
                              {"retirementObservedMs": 20, "transportQuiescedAtMs": 65})
                fields = dict(phase=phase, outcome="failed", elapsedMs=origin + 200,
                              navigationIssued=dispatched, documentCommitted=False, documentFinished=False,
                              pageStartedAtNs=(origin + 10) * NS_PER_MS,
                              preparationStartedAtNs=(origin + 14) * NS_PER_MS,
                              preparationDeadlineAtNs=(origin + 15_014) * NS_PER_MS,
                              actualProtocol="socks5" if bound else "unbound", timelineMs=milestones,
                              retirementState="confirmed" if bound else "unbound", retirementRequestedAtMs=55,
                              transportQuiesced=True, observationCutoffMs=65) | failure | binding | retirement
                health = row("health", **fields)
                with self.subTest(phase=phase, marker=marker):
                    read(prefix + health)
                    for issued, appended in ((60, 64), (62, 64)):
                        permit = challenge(NEXT_TOKEN, issued=origin + issued, appended=origin + appended)
                        with self.assertRaisesRegex(ValueError, "outside the health probe interval"):
                            read(prefix + permit + health)
                    stopped = fields | {"outcome": "stopped", "observationCutoffMs": 52,
                                        "observedThroughAtNs": (origin + 75) * NS_PER_MS}
                    poll = row("health", **stopped, stopReason="external-stop")
                    with self.assertRaisesRegex(ValueError, "inside the synchronous health probe close"):
                        read(prefix + poll)
                    worker = row("health", **stopped, stopReason="metering-failure", chargedBytes=1)
                    self.assertTrue(read(prefix + worker).halted)

        result = stage("result", outcome="stopped", navigationIssued=False, documentCommitted=False,
                       documentFinished=False, localLoadDisposition="load-not-accepted",
                       stopReason="external-stop", timelineMs={"loadNotAccepted": 59}, observationCutoffMs=61,
                       observedThroughAtNs=3_075 * NS_PER_MS)
        retirement = stage("retirement", retirementState="confirmed", transportQuiesced=True,
                           **(WITNESSES | {"retirementRequestedAtMs": 64}))
        native = READY + RESERVED + result
        self.observe("result-without-close-anchor", native)
        with self.assertRaisesRegex(LedgerObservationUnavailable, "inside the synchronous target close"):
            self.reconcile(native + retirement, native + retirement)

    def test_deadline_can_win_during_the_synchronous_close_gap(self):
        for phase, prefix, _, read in probe_fixtures():
            origin = 29_938
            with self.subTest(phase=phase):
                health = row("health", phase=phase, elapsedMs=origin + 200, outcome="stopped",
                             navigationIssued=False, documentCommitted=False, documentFinished=False,
                             pageStartedAtNs=(origin + 10) * NS_PER_MS,
                             preparationStartedAtNs=(origin + 14) * NS_PER_MS,
                             preparationDeadlineAtNs=(origin + 15_014) * NS_PER_MS,
                             localLoadDisposition="load-not-accepted", timelineMs={"loadNotAccepted": 50},
                             stopReason="run-permit-expired", observationCutoffMs=52,
                             observedThroughAtNs=(origin + 75) * NS_PER_MS,
                             retirementState="confirmed", transportQuiesced=True, retirementRequestedAtMs=55,
                             retirementObservedMs=125, retirementCommitAtMs=145, transportQuiescedAtMs=160,
                             retirementFirstPolledAtNs=(origin + 110) * NS_PER_MS)
                self.assertTrue(read(prefix + health).halted)

    def test_live_navigation_failure_closes_without_an_intervening_permit(self):
        cases = ((60, 60, True), (60, 64, False), (62, 64, False), (62, 65, False),
                 (60, 65, False), (65, 65, True), (65, 67, True))
        for phase, prefix, origin, read in probe_fixtures():
            health = sequenced_probe(
                phase, origin, outcome="failed", documentFinished=False, errorDomain="NSURLErrorDomain", errorCode=-1003,
                timelineMs={"loadIssued": 10, "firstVisibleHTTPResponse": 22, "documentCommit": 30, "navigationFailure": 50},
                retirementRequestedAtMs=55, retirementObservedMs=125)
            for issued, written, valid in cases:
                permit = challenge(NEXT_TOKEN, issued=origin + issued, appended=origin + written)
                with self.subTest(phase=phase, issued=issued, written=written):
                    if valid:
                        read(prefix + permit + health)
                    else:
                        with self.assertRaisesRegex(ValueError, "outside the health probe interval"):
                            read(prefix + permit + health)
        result = stage("result", outcome="failed", navigationIssued=True, errorDomain="NSURLErrorDomain", errorCode=-1003,
                       documentCommitted=False, documentFinished=False, observationCutoffMs=74,
                       timelineMs={"loadIssued": 1, "navigationFailure": 59})
        retirement = stage("retirement", retirementState="confirmed", transportQuiesced=True,
                           **(WITNESSES | {"retirementRequestedAtMs": 64}))
        for issued, written, valid in cases:
            permit = challenge(NEXT_TOKEN, issued=3_000 + issued, appended=3_000 + written)
            native = READY + RESERVED + DISPATCH + permit + result
            with self.subTest(target_permit=(issued, written)):
                read_campaign_receipt(native, TARGETS, IDENTITY, LIMITS)
                if valid:
                    read_campaign_receipt(native + retirement, TARGETS, IDENTITY, LIMITS)
                else:
                    with self.assertRaisesRegex(ValueError, "outside the target interval"):
                        read_campaign_receipt(native + retirement, TARGETS, IDENTITY, LIMITS)

    def test_unprepared_probe_renewals_are_bounded_by_synchronous_polls_and_fence(self):
        for phase, prefix, origin, read in probe_fixtures():
            for observed, stamps, valid in ((30, (11, 12), True), (30, (11, 12, 16), True),
                                            (30, (11, 12, 16, 18), False), (80, (11, 12, 16, 18), False),
                                            (59, (10, 10, 59, 59), False), (60, (10, 10, 60, 60), True),
                                            (75, (11, 12, 13, 65), False), (75, (11, 12, 65, 66), True)):
                permits = b"".join(challenge(NEXT_TOKEN + bytes([index]), issued=origin + stamp)
                                   for index, stamp in enumerate(stamps))
                health = row("health", phase=phase, outcome="failed", navigationIssued=False,
                             documentCommitted=False, documentFinished=False, retirementState="unbound",
                             retirementRequestedAtMs=80, retirementObservedMs=10, transportQuiesced=True,
                             transportQuiescedAtMs=80, observationCutoffMs=observed - 10)
                with self.subTest(phase=phase, observed=observed, permits=stamps):
                    if valid:
                        read(prefix + permits + health)
                    else:
                        with self.assertRaisesRegex(ValueError, "outside the health probe interval"):
                            read(prefix + permits + health)

    def test_target_permits_are_bound_to_result_and_retirement_actor_events(self):
        native, read = three_timeout_fixture()
        active, retirement, _ = native.rsplit(b"\n", 2)
        active += b"\n"
        retirement += b"\n"
        final = healthy(phase="after-three-no-http-timeouts")
        checkpoint = row("checkpoint", reason="three-no-http-timeouts", reservedCount=3)
        for issued, appended, valid in ((5_310, 5_312, False), (5_310, 5_311, True), (5_311, 5_312, True)):
            permit = challenge(NEXT_TOKEN, issued=issued, appended=appended)
            with self.subTest(issued=issued, appended=appended):
                self.assertIsNotNone(read(active + permit).challenge_sha256)
                complete = active + permit + retirement + PAUSED + final + checkpoint
                if valid:
                    self.assertEqual(read(complete).checkpoint, "three-no-http-timeouts")
                else:
                    with self.assertRaisesRegex(ValueError, "outside the target interval"):
                        read(complete)
        delayed_poll = change_row(retirement, retirementFirstPolledAtNs=5_305 * NS_PER_MS,
                                  transportQuiescedAtNs=5_355 * NS_PER_MS, transportQuiescedAtMs=354,
                                  retirementExitPolledAtNs=5_355 * NS_PER_MS)
        for issued in (5_301, 5_305):
            permit = challenge(NEXT_TOKEN, issued=issued)
            with self.subTest(first_poll=issued):
                if issued == 5_305:
                    read(active + permit + delayed_poll)
                else:
                    with self.assertRaisesRegex(ValueError, "outside the target interval"):
                        read(active + permit + delayed_poll)

        missed_deadline = change_row(retirement, elapsedNs=15_160 * NS_PER_MS, elapsedMs=15_160,
                                     retirementState="unconfirmed", transportQuiesced=False,
                                     retirementCommitAtNs=None, retirementCommitAtMs=None,
                                     transportQuiescedAtNs=None, transportQuiescedAtMs=None,
                                     retirementFirstPolledAtNs=15_102 * NS_PER_MS,
                                     retirementExitPolledAtNs=15_102 * NS_PER_MS,
                                              retirementObservedThroughAtNs=15_160 * NS_PER_MS, retirementObservedMs=10_148)
        read(active + missed_deadline)
        contradicted = change_row(missed_deadline, retirementExitPolledAtNs=15_152 * NS_PER_MS)
        unreachable = challenge(NEXT_TOKEN, issued=15_120)
        with self.assertRaisesRegex(ValueError, "first expired poll"):
            read(active + unreachable + contradicted)

        live = READY + RESERVED + DISPATCH
        for issued, appended, valid in ((3_011, 3_014, True), (3_019, 3_022, False), (3_105, 3_108, True)):
            permit = challenge(NEXT_TOKEN, issued=issued, appended=appended)
            with self.subTest(issued=issued, appended=appended):
                read_campaign_receipt(live + permit, TARGETS, IDENTITY, LIMITS)
                if not valid:
                    with self.assertRaisesRegex(ValueError, "outside the target interval"):
                        read_campaign_receipt(live + permit + RESULT, TARGETS, IDENTITY, LIMITS)
                elif issued < 3_021:
                    read_campaign_receipt(live + permit + RESULT + RETIRED, TARGETS, IDENTITY, LIMITS)
                else:
                    partial = live + permit + RESULT
                    self.assertFalse(read_campaign_receipt(partial, TARGETS, IDENTITY, LIMITS).halted)
                    fence = challenge(TOKEN.replace(b"f48", b"f38"), issued=3_320, appended=3_321)
                    self.assertTrue(read_campaign_receipt(partial + fence + RETIRED, TARGETS, IDENTITY, LIMITS)
                                    .attempts[0].settled)
                    stopped = change_row(RETIRED, haltDuringRetirement={
                        "stopReason": "transport-lost", "stopAtMs": 107, "stopAtNs": 3_108 * NS_PER_MS,
                    })
                    self.assertTrue(read_campaign_receipt(partial + stopped, TARGETS, IDENTITY, LIMITS).halted)

    def test_probe_poll_stop_needs_a_page_but_deadline_can_predate_it(self):
        for phase, prefix, origin, read in probe_fixtures():
            for reason, admitted, started, stopped, valid in (
                    ("external-stop", origin + 8, origin + 20, origin + 16, False),
                    ("external-stop", origin + 8, origin + 20, origin + 20, True),
                    ("transport-lost", origin + 8, origin + 20, origin + 21, False),
                    ("run-permit-expired", 29_999, 30_001, 30_000, True)):
                health = row("health", phase=phase, outcome="stopped", navigationIssued=False,
                             documentCommitted=False, documentFinished=False, retirementState="unbound",
                             healthAdmittedAtNs=admitted * NS_PER_MS, pageStartedAtNs=started * NS_PER_MS,
                             observationCutoffMs=stopped - started, observedThroughAtNs=(started + 5) * NS_PER_MS,
                             stopReason=reason, elapsedMs=started + 30, transportQuiesced=True,
                             retirementRequestedAtMs=10, transportQuiescedAtMs=10, retirementObservedMs=5)
                with self.subTest(phase=phase, stop=reason, stopped=stopped):
                    if valid:
                        self.assertTrue(read(prefix + health).halted)
                    else:
                        with self.assertRaisesRegex(ValueError, "page creation|live binding"):
                            read(prefix + health)

    def test_dispatch_cannot_follow_a_synchronous_page_poll_stop(self):
        for phase, prefix, origin, read in probe_fixtures():
            for reason, at, valid in (("transport-lost", 16, False), ("external-stop", 16, False),
                                      ("transport-lost", 20, True), ("metering-failure", 16, True)):
                timeline = {"loadIssued": 10}
                health = row(
                    "health", phase=phase, outcome="stopped", documentCommitted=False, documentFinished=False,
                    navigationIssued=True, navigationIssuedAtNs=(origin + 20) * NS_PER_MS, stopReason=reason,
                    observationCutoffMs=at - 10, observedThroughAtNs=(origin + 75) * NS_PER_MS,
                    timelineMs=timeline if at == 20 else {},
                    observedAfterCutoff={"timelineMs": timeline} if at != 20 else {},
                    chargedBytes=int(reason == "metering-failure"), retirementState="confirmed",
                    transportQuiesced=True, **HEALTH_WITNESSES)
                with self.subTest(phase=phase, reason=reason, at=at):
                    if valid:
                        self.assertTrue(read(prefix + health).halted)
                    else:
                        with self.assertRaisesRegex(ValueError, "dispatch follows a synchronous page poll stop"):
                            read(prefix + health)

        for reason, at, valid in (("transport-lost", 3_016, False), ("transport-lost", 3_020, True),
                                  ("metering-failure", 3_016, True), ("run-permit-expired", 3_016, True)):
            limits = CampaignLimits(LIMITS.targets, LIMITS.duration_seconds, LIMITS.bytes,
                                    at if reason == "run-permit-expired" else LIMITS.permit_window_ms)
            prefix = change_row(START, **limits.fields()) + READY[len(START):] + RESERVED
            charged = int(reason == "metering-failure")
            dispatched = stage("dispatch", elapsedMs=3_020, navigationIssuedAtNs=3_020 * NS_PER_MS, chargedBytes=charged)
            timeline = {"loadIssued": 19}
            result = stage("result", outcome="stopped", documentCommitted=False, documentFinished=False,
                           navigationIssued=True, navigationIssuedAtNs=3_020 * NS_PER_MS,
                           stopReason=reason, observationCutoffMs=at - 3_001, observedThroughAtNs=3_075 * NS_PER_MS,
                           timelineMs=timeline if at == 3_020 else {},
                           observedAfterCutoff={"timelineMs": timeline} if at != 3_020 else {},
                           chargedBytes=charged)
            with self.subTest(target=reason, at=at):
                if valid:
                    self.assertTrue(read_campaign_receipt(prefix + dispatched + result, TARGETS, IDENTITY, limits).halted)
                else:
                    with self.assertRaisesRegex(ValueError, "dispatch follows a synchronous page poll stop"):
                        read_campaign_receipt(prefix + dispatched + result, TARGETS, IDENTITY, limits)

    def test_preparation_and_rejected_load_follow_their_direct_guards(self):
        phase_cases = (
            ("external-stop", 12, None, False),
            ("external-stop", 14, None, True),
            ("external-stop", 16, "loadNotAccepted", False),
            ("external-stop", 20, "loadNotAccepted", True),
            ("run-permit-expired", 12, None, True),
            ("run-permit-expired", 12, "loadNotAccepted", False),
            ("run-permit-expired", 16, "loadNotAccepted", True),
            ("run-permit-expired", 12, "loadIssued", False),
            ("run-permit-expired", 16, "loadIssued", True),
            ("byte-limit", 16, "loadNotAccepted", True),
        )
        for phase, prefix, origin, read in probe_fixtures():
            for reason, stopped, load, valid in phase_cases:
                page = 30_000 - stopped if reason == "run-permit-expired" else origin
                bound = load is not None
                accepted = load == "loadIssued"
                fields = {
                    "phase": phase, "outcome": "stopped", "elapsedMs": page + 280,
                    "navigationIssued": accepted, "documentCommitted": False, "documentFinished": False,
                    "healthAdmittedAtNs": (page + 8) * NS_PER_MS, "pageStartedAtNs": (page + 10) * NS_PER_MS,
                    "preparationStartedAtNs": (page + 14) * NS_PER_MS,
                    "preparationDeadlineAtNs": (page + 15_014) * NS_PER_MS,
                    "stopReason": reason, "observationCutoffMs": stopped - 10,
                    "observedThroughAtNs": (page + 75) * NS_PER_MS, "transportQuiesced": True,
                }
                witnesses = HEALTH_WITNESSES if bound else {
                    "retirementRequestedAtMs": 80, "retirementObservedMs": 20, "transportQuiescedAtMs": 80,
                }
                if load == "loadNotAccepted" and stopped == 20:
                    witnesses |= {"retirementRequestedAtMs": 10, "retirementObservedMs": 150}
                if bound:
                    load_evidence = {"timelineMs": {load: 10}}
                    if accepted:
                        fields["navigationIssuedAtNs"] = (page + 20) * NS_PER_MS
                    else:
                        load_evidence["localLoadDisposition"] = "load-not-accepted"
                    fields.update(load_evidence if stopped == 20 else {"timelineMs": {}, "observedAfterCutoff": load_evidence})
                native = prefix + row("health", **fields, **witnesses, actualProtocol="socks5" if bound else "unbound",
                                      retirementState="confirmed" if bound else "unbound")
                with self.subTest(phase=phase, reason=reason, stopped=stopped, load=load):
                    if valid:
                        self.assertTrue(read(native).halted)
                    else:
                        with self.assertRaisesRegex(ValueError, "preparation follows|dispatch follows|expiry before preparation"):
                            read(native)

    def test_bound_probe_can_renew_twice_in_load_predicates_that_abort(self):
        for phase, prefix, origin, _ in probe_fixtures():
            targets = TIMEOUT_TARGETS if origin else TARGETS
            limits = replace(LIMITS, targets=len(targets))
            fence = ((15, 15),)
            guard_pair = ((20, 20), (21, 21))
            permits = permit_series(origin, fence + guard_pair)
            for reason in ("external-stop", "node-revision-changed"):
                bound = stopped_load_probe(phase, origin, reason=reason, stopped=22)
                self.assert_snapshot_paths(f"aborted-load-{origin}-{reason}", prefix + permits + bound,
                                           targets=targets, limits=limits)

            unbound = stopped_load_probe(phase, origin, reason="external-stop", stopped=22, bound=False)
            self.assert_snapshot_paths(f"unbound-control-{origin}", prefix + permit_series(origin, fence) + unbound,
                                       targets=targets, limits=limits)
            for label, rows, health in (
                    ("unbound", permits, unbound),
                    ("surplus", permit_series(origin, fence + ((19, 19),) + guard_pair), bound)):
                self.assert_snapshot_paths(f"aborted-load-{label}-{origin}", prefix + rows + health,
                                           verified=prefix + rows, targets=targets, limits=limits,
                                           invalid="outside the health probe interval")

    def test_aborted_bound_load_can_renew_in_the_terminal_transport_loss_guard(self):
        for phase, prefix, origin, _ in probe_fixtures():
            targets = TIMEOUT_TARGETS if origin else TARGETS
            limits = replace(LIMITS, targets=len(targets))
            before_health = prefix + permit_series(origin, ((15, 15), (19, 19), (20, 20), (21, 21)))
            for reason, marker, valid in (("transport-lost", None, True), ("run-control-unavailable", None, True),
                                          ("node-revision-changed", None, False), ("external-stop", None, False),
                                          ("transport-lost", "loadIssued", False),
                                          ("transport-lost", "loadNotAccepted", False)):
                health = stopped_load_probe(phase, origin, reason=reason, stopped=22,
                                            load=22 if marker else None, accepted=marker == "loadIssued")
                self.assert_snapshot_paths(f"third-load-guard-{origin}-{reason}-{marker}", before_health + health,
                                           verified=before_health, targets=targets, limits=limits,
                                           invalid=None if valid else "outside the health probe interval")
            stop = stopped_load_probe(phase, origin, reason="transport-lost", stopped=22)
            early_close = change_row(stop, retirementRequestedAtMs=11,
                                     retirementRequestedAtNs=(origin + 21) * NS_PER_MS, retirementObservedMs=79)
            self.assert_snapshot_paths(f"bound-abort-already-closed-{origin}", before_health + early_close,
                                       verified=before_health, targets=targets, limits=limits,
                                       invalid="outside the health probe interval")

    def test_live_poll_stop_and_renewals_need_a_common_assignment(self):
        for phase, prefix, origin, _ in probe_fixtures():
            targets = TIMEOUT_TARGETS if origin else TARGETS
            limits = replace(LIMITS, targets=len(targets))
            for issued, response, stopped, commit, reason, valid in (
                    (21, 23, 25, 30, "external-stop", False),
                    (21, 23, 25, 30, "metering-failure", True),
                    (21, None, 25, 30, "external-stop", False),
                    (21, 23, 70, 74, "node-revision-changed", False),
                    (21, 23, 71, 74, "node-revision-changed", False),
                    (2_013, 2_015, 2_016, 2_018, "external-stop", False),
                    (2_050, 2_052, 2_054, 2_056, "external-stop", False)):
                permit = challenge(NEXT_TOKEN, issued=origin + issued)
                http = {"firstVisibleHTTPStatus": 200, "lastHTTPStatus": 200}
                timeline = {"loadIssued": 10} | ({"firstVisibleHTTPResponse": response - 10} if response else {})
                late = {"timelineMs": {"documentCommit": commit - 10}, "documentCommitted": True}
                if response is None:
                    late["timelineMs"]["firstVisibleHTTPResponse"] = 17
                    late.update(http)
                observed = commit + 5
                health = row(
                    "health", phase=phase, outcome="stopped", documentCommitted=False, documentFinished=False,
                    navigationIssued=True, navigationIssuedAtNs=(origin + 20) * NS_PER_MS,
                    pageStartedAtNs=(origin + 10) * NS_PER_MS, healthAdmittedAtNs=(origin + 8) * NS_PER_MS,
                    preparationStartedAtNs=(origin + 14) * NS_PER_MS,
                    preparationDeadlineAtNs=(origin + 15_014) * NS_PER_MS,
                    stopReason=reason, timelineMs=timeline, observationCutoffMs=stopped - 10,
                    observedThroughAtNs=(origin + observed) * NS_PER_MS, observedAfterCutoff=late,
                    retirementState="confirmed", transportQuiesced=True,
                    retirementRequestedAtMs=observed - 9, retirementFirstPolledAtNs=(origin + observed + 5) * NS_PER_MS,
                    retirementCommitAtMs=observed + 44, transportQuiescedAtMs=observed + 45,
                    retirementObservedMs=59, elapsedMs=origin + observed + 60,
                    chargedBytes=int(reason == "metering-failure"), **(http if response else {}))
                before_health = prefix + permit
                self.assert_snapshot_paths(f"live-stop-{origin}-{issued}-{response}-{stopped}-{reason}",
                                           before_health + health, verified=before_health, targets=targets,
                                           limits=limits, invalid=None if valid else "outside the health probe interval")
                if stopped in (71, 2_054):
                    # The stopping fence or publisher retires before this commit.
                    retired = change_row(health, observedAfterCutoff={},
                                         retirementRequestedAtNs=(origin + stopped + 1) * NS_PER_MS,
                                         retirementRequestedAtMs=stopped - 9, retirementObservedMs=observed + 59 - stopped,
                                         originalNavigationAfterClose=add_timeline_instants(late))
                    self.assert_snapshot_paths(f"stop-with-retired-commit-{origin}-{stopped}", before_health + retired,
                                               targets=targets, limits=limits)
                if stopped == 71:
                    tied = add_timeline_instants({"timelineMs": timeline | {"documentCommit": stopped - 10}})
                    committed = change_row(health, **tied, documentCommitted=True, observedAfterCutoff={})
                    self.assert_snapshot_paths(f"stop-with-tied-commit-{origin}", before_health + committed,
                                               targets=targets, limits=limits)

        dispatch = stage("dispatch", elapsedMs=3_020, navigationIssuedAtNs=3_020 * NS_PER_MS)
        active = READY + RESERVED + dispatch + challenge(NEXT_TOKEN, issued=3_021)
        result = stage("result", outcome="stopped", documentCommitted=False, documentFinished=False,
                       navigationIssued=True, navigationIssuedAtNs=3_020 * NS_PER_MS, observationCutoffMs=24,
                       observedThroughAtNs=3_075 * NS_PER_MS, stopReason="external-stop",
                       firstVisibleHTTPStatus=200, lastHTTPStatus=200,
                       timelineMs={"loadIssued": 19, "firstVisibleHTTPResponse": 22},
                       observedAfterCutoff={"timelineMs": {"documentCommit": 29}, "documentCommitted": True})
        self.assert_snapshot_paths("target-live-stop-between-callbacks", active + result, verified=active,
                                   invalid="outside the target interval")

    def test_load_follows_the_post_publication_stop_check_even_below_cap(self):
        for phase, prefix, origin, _ in probe_fixtures():
            targets = TIMEOUT_TARGETS if origin else TARGETS
            limits = replace(LIMITS, targets=len(targets))
            lease = replace(limits, permit_window_ms=origin + 16)
            header, tail = prefix.split(b"\n", 1)
            leased = change_row(header, **lease.fields()) + tail
            for accepted in (False, True):
                for wrote, valid in ((15, True), (16, True), (17, False), (20, False)):
                    permit = challenge(NEXT_TOKEN, issued=origin + 15, appended=origin + wrote,
                                       chargedBytes=int(not valid))
                    health = stopped_load_probe(phase, origin, reason="metering-failure", stopped=16,
                                                load=20, accepted=accepted, charged=1)
                    self.assert_snapshot_paths(f"worker-load-{origin}-{accepted}-{wrote}", prefix + permit + health,
                                               verified=prefix + permit, targets=targets, limits=limits,
                                               invalid=None if valid else "load follows a permit published at or after the stop")

                for wrote in (20, 21, 22):
                    permit = challenge(NEXT_TOKEN, issued=origin + 15, appended=origin + wrote)
                    health = stopped_load_probe(phase, origin, reason="run-permit-expired", stopped=21,
                                                load=25, accepted=accepted)
                    self.assert_snapshot_paths(f"deadline-load-{origin}-{accepted}-{wrote}", leased + permit + health,
                                               verified=leased + permit, targets=targets, limits=lease,
                                               invalid=None if wrote == 20 else "load follows a permit published at or after the stop")

        # Dispatch serializes the accepted load with the permit. A worker
        # stop at the same clock can still race the permit's counter read.
        for stopped in (3_016, 3_020):
            issued = 3_015 if stopped == 3_016 else 3_020
            permit = challenge(NEXT_TOKEN, issued=issued, appended=3_020, chargedBytes=int(stopped == 3_016))
            dispatch = stage("dispatch", elapsedMs=3_020, navigationIssuedAtNs=3_020 * NS_PER_MS, chargedBytes=1)
            evidence = {"timelineMs": {"loadIssued": 19}}
            if stopped < 3_020:
                evidence = {"timelineMs": {}, "observedAfterCutoff": evidence}
            result = stage("result", **evidence, outcome="stopped", navigationIssued=True, documentCommitted=False,
                           documentFinished=False, stopReason="metering-failure", navigationIssuedAtNs=3_020 * NS_PER_MS,
                           observationCutoffMs=stopped - 3_001, observedThroughAtNs=3_075 * NS_PER_MS, chargedBytes=1)
            before_result = READY + RESERVED + permit + dispatch
            self.assert_snapshot_paths(f"target-load-{stopped}", before_result + result, verified=before_result,
                                       invalid="load follows a permit published at or after the stop" if stopped < 3_020 else None)

    def test_preparation_at_the_deadline_cannot_bind(self):
        for phase, prefix, origin, _ in probe_fixtures():
            targets = TIMEOUT_TARGETS if origin else TARGETS
            header, tail = prefix.split(b"\n", 1)
            for stopped, bound, accepted, valid in (
                    (13, True, True, False), (14, True, True, False), (14, True, False, False),
                    (14, False, False, True), (15, True, True, True)):
                limits = replace(LIMITS, targets=len(targets), permit_window_ms=origin + stopped)
                leased = change_row(header, **limits.fields()) + tail
                health = stopped_load_probe(phase, origin, reason="run-permit-expired", stopped=stopped,
                                            load=20 if bound else None, accepted=accepted, bound=bound)
                self.assert_snapshot_paths(f"preparation-{origin}-{stopped}-{bound}-{accepted}", leased + health,
                                           verified=leased, targets=targets, limits=limits,
                                           invalid=None if valid else "expiry before preparation")

    def test_cap_sample_before_a_load_guard_blocks_both_load_outcomes(self):
        cap = LIMITS.bytes
        for phase, prefix, origin, read in probe_fixtures():
            for accepted in (False, True):
                for issued, wrote, before_load in ((15, 17, True), (18, 20, True), (20, 20, False)):
                    permit = challenge(NEXT_TOKEN, issued=origin + issued, appended=origin + wrote, chargedBytes=cap)
                    load = {"timelineMs": {"loadIssued": 10}} if accepted else {
                        "timelineMs": {"loadNotAccepted": 10}, "localLoadDisposition": "load-not-accepted",
                    }
                    stopped = 16 if issued == 15 else 20
                    fields = load if stopped == 20 else {"timelineMs": {}, "observedAfterCutoff": load}
                    witnesses = HEALTH_WITNESSES
                    if not accepted:
                        witnesses |= {"retirementRequestedAtMs": 10, "retirementObservedMs": 150}
                    health = row(
                        "health", phase=phase, outcome="stopped", navigationIssued=accepted, documentCommitted=False,
                        documentFinished=False, actualProtocol="socks5", **fields, pageStartedAtNs=(origin + 10) * NS_PER_MS,
                        preparationStartedAtNs=(origin + 14) * NS_PER_MS, preparationDeadlineAtNs=(origin + 15_014) * NS_PER_MS,
                        **({"navigationIssuedAtNs": (origin + 20) * NS_PER_MS} if accepted else {}),
                        stopReason="byte-limit", observationCutoffMs=stopped - 10, observedThroughAtNs=(origin + 75) * NS_PER_MS,
                        chargedBytes=cap, retirementState="confirmed", transportQuiesced=True, **witnesses,
                    )
                    with self.subTest(phase=phase, accepted=accepted, issued=issued, wrote=wrote):
                        if before_load:
                            with self.assertRaisesRegex(ValueError, "load follows a permit that sampled the byte cap"):
                                read(prefix + permit + health)
                        else:
                            self.assertTrue(read(prefix + permit + health).halted)

    def test_unprepared_retirement_exits_at_its_only_sample_even_when_late(self):
        for phase, prefix, origin, read in probe_fixtures():
            for first, exit_at, through, quiesced, valid in (
                    (110, 110, 111, True, True), (110, 170, 180, True, False),
                    (10_090, 10_090, 10_091, True, True),
                    (10_091, 10_091, 10_092, False, True)):
                health = row("health", phase=phase, outcome="failed", navigationIssued=False, elapsedMs=origin + through,
                             documentCommitted=False, documentFinished=False, retirementState="unbound",
                             retirementRequestedAtMs=80, retirementObservedMs=through - 90,
                             transportQuiesced=quiesced, transportQuiescedAtMs=exit_at - 10 if quiesced else None,
                             retirementFirstPolledAtNs=(origin + first) * NS_PER_MS,
                             retirementExitPolledAtNs=(origin + exit_at) * NS_PER_MS,
                             haltDuringRetirement={} if valid else {"stopReason": "external-stop", "stopAtMs": 120})
                with self.subTest(phase=phase, first=first, exit=exit_at):
                    if valid:
                        self.assertTrue(read(prefix + health).halted)
                    else:
                        with self.assertRaisesRegex(ValueError, "must exit retirement at its first poll"):
                            read(prefix + health)

        result = stage("result", outcome="failed", navigationIssued=False, documentCommitted=False, documentFinished=False)
        native = READY + RESERVED + result
        retirement = stage("retirement", retirementState="unbound", transportQuiesced=True, retirementRequestedAtMs=100,
                           transportQuiescedAtMs=299, retirementObservedMs=220)
        self.assertTrue(read_campaign_receipt(native + retirement, TARGETS, IDENTITY, LIMITS).attempts[0].settled)
        forged = change_row(retirement, retirementExitPolledAtNs=3_360 * NS_PER_MS,
                            transportQuiescedAtNs=3_360 * NS_PER_MS, transportQuiescedAtMs=359,
                            retirementObservedThroughAtNs=3_370 * NS_PER_MS, retirementObservedMs=269)
        with self.assertRaisesRegex(ValueError, "must exit retirement at its first poll"):
            read_campaign_receipt(native + forged, TARGETS, IDENTITY, LIMITS)

    def test_first_transport_loss_can_come_from_close_but_not_the_waiting_fence(self):
        for phase, prefix, origin, read in probe_fixtures():
            for reason, at, valid in (("transport-lost", 105, True), ("transport-lost", 110, True),
                                      ("transport-lost", 140, False), ("external-stop", 140, True),
                                      ("node-revision-changed", 140, True), ("run-control-unavailable", 140, True)):
                health = sequenced_probe(phase, origin, haltDuringRetirement={"stopReason": reason, "stopAtMs": at - 10})
                count = 0 if origin == 0 else 3
                checkpoint = row("checkpoint", reason=reason if count == 0 else "three-no-http-timeouts",
                                 reservedCount=count, budgetStopReason=reason, budgetStopAtNs=(origin + at) * NS_PER_MS)
                with self.subTest(phase=phase, stop=reason, at=at):
                    if valid:
                        self.assertTrue(read(prefix + health + checkpoint).halted)
                    else:
                        with self.assertRaisesRegex(ValueError, "transport loss requires a live binding"):
                            read(prefix + health)

        for reason in ("transport-lost", "external-stop"):
            retirement = stage("retirement", retirementState="confirmed", transportQuiesced=True, **WITNESSES,
                               haltDuringRetirement={"stopReason": reason, "stopAtMs": 320})
            native = READY + RESERVED + DISPATCH + RESULT + retirement
            with self.subTest(target_stop=reason):
                if reason == "transport-lost":
                    with self.assertRaisesRegex(ValueError, "transport loss requires a live binding"):
                        read_campaign_receipt(native, TARGETS, IDENTITY, LIMITS)
                else:
                    self.assertTrue(read_campaign_receipt(native, TARGETS, IDENTITY, LIMITS).halted)

    def test_null_retirement_callbacks_and_invalid_payload_use_normal_copy_path(self):
        native = GRANTED + healthy(originalNavigationAfterClose=None)
        self.assertEqual(len(self.observe("null-callbacks", native).attempts), 0)
        self.assertEqual(self.observer.observed_prefix, native)
        self.assertEqual(self.transport[-1], (1, "complete"))

        self.observer = self.open_observer("invalid-callbacks.json")
        invalid = healthy(originalNavigationAfterClose=[])
        with self.assertRaisesRegex(LedgerObservationUnavailable, "Invalid original WebKit callbacks"):
            self.observe("invalid-callbacks", GRANTED + invalid)
        self.assertEqual(self.observer.observed_prefix, GRANTED)
        self.assertEqual(self.transport[-1], (1, "invalid-ledger"))
        persisted = json.loads((self.directory / "invalid-callbacks.json").read_bytes())
        self.assertFalse(persisted["pending"])
        self.assertTrue(persisted["disputed"])

    def test_stopped_retirement_cannot_be_reported_as_target_limit(self):
        prefix = READY + RESERVED + DISPATCH + RESULT + RETIRED + stage("reserved", 2) + stage("dispatch", 2)
        result = stage("result", 2, outcome="finished", navigationIssued=True, documentCommitted=True, documentFinished=True)
        retirement = stage("retirement", 2, retirementState="confirmed", transportQuiesced=True, **WITNESSES,
                           haltDuringRetirement={"stopReason": "external-stop", "stopAtMs": 349})
        checkpoint = {"budgetStopReason": "external-stop", "budgetStopAtNs": 4_350 * NS_PER_MS, "reservedCount": 2}
        with self.assertRaisesRegex(ValueError, "Invalid native checkpoint"):
            read_campaign_receipt(prefix + result + retirement + row("checkpoint", reason="target-limit", **checkpoint),
                                  TARGETS, IDENTITY, LIMITS)
        correct = row("checkpoint", reason="external-stop", **checkpoint)
        self.assertEqual(read_campaign_receipt(prefix + result + retirement + correct, TARGETS, IDENTITY, LIMITS)
                         .checkpoint, "external-stop")

    def test_callback_before_final_guard_excludes_a_binding_stop_in_final_close(self):
        active = READY + RESERVED + DISPATCH
        prefix = active + RESULT
        page, observed, first, stopped_at = (at * NS_PER_MS for at in (3_001, 3_021, 3_300, 3_045))

        def stop(reason, at=stopped_at):
            return {"stopReason": reason, "stopAtNs": at, "stopAtMs": (at - page) // NS_PER_MS}

        early = policy_retirement(observed, first, first, commit_ns=observed)
        self.assert_snapshot_paths("early-replacement-no-sleep-poll-stop",
                                   prefix + change_row(early, haltDuringRetirement=stop("external-stop")),
                                   verified=prefix, invalid="precedes the first reachable poll")
        no_callback = policy_retirement(observed, 13_021 * NS_PER_MS, 13_021 * NS_PER_MS)
        self.assert_snapshot_paths("request-tie-allows-final-close-stop",
                                   prefix + change_row(no_callback, haltDuringRetirement=stop("external-stop")))

        yielded = policy_retirement(observed, first, 3_350 * NS_PER_MS, commit_ns=observed)
        self.assert_snapshot_paths("early-replacement-allows-waiting-fence",
                                   prefix + change_row(yielded, haltDuringRetirement=stop("external-stop", 3_320 * NS_PER_MS)))
        ambiguous = policy_retirement(observed, observed, 3_071 * NS_PER_MS, commit_ns=observed)
        tied_prefix = active + change_row(RESULT, elapsedNs=observed, elapsedMs=3_021)
        self.assert_snapshot_paths("replacement-tie-allows-waiting-fence", tied_prefix + change_row(
            ambiguous, haltDuringRetirement=stop("external-stop")))

        metered = active + change_row(RESULT, chargedBytes=1)
        self.assert_snapshot_paths("early-replacement-allows-worker-stop", metered + change_row(
            early, chargedBytes=1, haltDuringRetirement=stop("metering-failure")))
        limits = replace(LIMITS, permit_window_ms=3_045)
        expiring = change_row(START, **limits.fields()) + prefix[len(START):]
        self.assert_snapshot_paths("early-replacement-allows-independent-deadline", expiring + change_row(
            early, haltDuringRetirement=stop("run-permit-expired")), limits=limits)

        # The same clock can hold a close stop before the result counter or
        # a waiting stop after it. A capped result demands a feasible close.
        cap = LIMITS.bytes
        capped = active + change_row(RESULT, chargedBytes=cap)
        for name, replacement, error in (("cap-close-still-possible", first, None),
                                         ("cap-excludes-only-reachable-waiting-stop", observed, "earlier byte-cap sample")):
            retired = policy_retirement(observed, first, 3_350 * NS_PER_MS, commit_ns=replacement)
            self.assert_snapshot_paths(name, capped + change_row(
                retired, chargedBytes=cap, haltDuringRetirement=stop("external-stop", first)),
                verified=capped, invalid=error)

    def test_late_poll_stop_can_come_from_close_before_result_append(self):
        prefix = READY + RESERVED + DISPATCH + RESULT
        for reason, at, valid in (("transport-lost", 120, True), ("external-stop", 320, True),
                                  ("external-stop", 352, False)):
            stop = {"stopReason": reason, "stopAtMs": at}
            retirement = stage("retirement", retirementState="confirmed", transportQuiesced=True,
                               haltDuringRetirement=stop, **WITNESSES)
            with self.subTest(stop_at=at):
                if valid:
                    checkpoint = row("checkpoint", reason=reason, reservedCount=1,
                                     budgetStopReason=reason, budgetStopAtNs=(3_001 + at) * NS_PER_MS)
                    self.assertEqual(read_campaign_receipt(prefix + retirement + checkpoint, TARGETS, IDENTITY, LIMITS)
                                     .checkpoint, reason)
                else:
                    with self.assertRaisesRegex(ValueError, "poll stop follows the exit poll"):
                        read_campaign_receipt(prefix + retirement, TARGETS, IDENTITY, LIMITS)

    def test_checkpoint_stop_is_required_if_a_preceding_row_was_already_expired(self):
        prefix = READY + RESERVED + DISPATCH + RESULT + RETIRED + stage("reserved", 2) + stage("dispatch", 2)
        result = stage("result", 2, outcome="finished", navigationIssued=True, documentCommitted=True, documentFinished=True)
        retired = {"retirementState": "confirmed", "transportQuiesced": True} | WITNESSES
        checkpoint = row("checkpoint", elapsedMs=30_010, reason="target-limit", reservedCount=2)
        on_time = prefix + result + stage("retirement", 2, **retired)
        self.assertEqual(read_campaign_receipt(on_time + checkpoint, TARGETS, IDENTITY, LIMITS).checkpoint, "target-limit")
        late = prefix + result + stage("retirement", 2, **retired, elapsedMs=30_001)
        with self.assertRaisesRegex(ValueError, "Expired native checkpoint requires the stop witness"):
            read_campaign_receipt(late + checkpoint, TARGETS, IDENTITY, LIMITS)
        expired = row("checkpoint", elapsedMs=30_010, reason="run-permit-expired", budgetStopReason="run-permit-expired",
                      budgetStopAtNs=30_000 * NS_PER_MS, reservedCount=2)
        self.assertEqual(read_campaign_receipt(late + expired, TARGETS, IDENTITY, LIMITS).checkpoint, "run-permit-expired")

    def test_late_meter_stop_uses_target_result_charge_and_retirement_quiescence(self):
        baseline = 45

        def target(entry_charge, result_charge):
            return (GRANTED + healthy(chargedBytes=entry_charge) + stage("reserved", chargedBytes=entry_charge)
                    + stage("dispatch", chargedBytes=entry_charge)
                    + stage("result", outcome="finished", navigationIssued=True, documentCommitted=True,
                            documentFinished=True, chargedBytes=result_charge))

        cases = (
            ("metering-failure", False, baseline, baseline + 1, baseline + 2, True),
            ("metering-failure", False, baseline, baseline + 1, baseline + 1, False),
            ("metering-failure", True, baseline, baseline, baseline + 1, False),
            ("byte-limit", False, 0, 0, 0, True),  # An oversized whole chunk can be rejected without charging it.
            ("byte-limit", True, baseline, baseline, baseline + 1, False),
        )
        for reason, quiesced, entry_charge, result_charge, charge, valid in cases:
            with self.subTest(stop=reason, quiesced=quiesced, entry_charge=entry_charge, charged=charge):
                witnesses = WITNESSES if quiesced else WITNESSES | {
                    "retirementObservedMs": 10_000, "transportQuiescedAtMs": None,
                }
                observed_ms = 3_001 + witnesses["retirementRequestedAtMs"] + witnesses["retirementObservedMs"]
                retirement = stage("retirement", retirementState="confirmed", transportQuiesced=quiesced,
                                   elapsedMs=observed_ms + 1, chargedBytes=charge, **witnesses)
                checkpoint = row("checkpoint", reason=reason, reservedCount=1, budgetStopReason=reason,
                                 budgetStopAtNs=(observed_ms + 1) * NS_PER_MS + 1, chargedBytes=charge)
                native = target(entry_charge, result_charge) + retirement + checkpoint
                # Even after the retirement row clock is read, the worker can win the counter lock.
                if valid:
                    receipt = read_campaign_receipt(native, TARGETS, IDENTITY, LIMITS)
                    self.assertEqual(receipt.checkpoint, reason)
                else:
                    with self.assertRaisesRegex(ValueError, "unwitnessed meter stop"):
                        read_campaign_receipt(native, TARGETS, IDENTITY, LIMITS)

        witnessed = stage("retirement", retirementState="confirmed", transportQuiesced=True, **WITNESSES,
                          haltDuringRetirement={"stopReason": "metering-failure", "stopAtMs": 349},
                          chargedBytes=baseline + 1)
        checkpoint = row("checkpoint", reason="metering-failure", budgetStopReason="metering-failure",
                         budgetStopAtNs=3_350 * NS_PER_MS, reservedCount=1, chargedBytes=baseline + 1)
        self.assertEqual(read_campaign_receipt(target(baseline, baseline) + witnessed + checkpoint, TARGETS, IDENTITY, LIMITS)
                         .checkpoint, "metering-failure")

    def test_first_probe_meter_witness_needs_preparation_and_new_charge(self):
        for phase, prefix, origin, read in probe_fixtures():
            permit = challenge(NEXT_TOKEN, issued=origin + 60, appended=origin + 65, chargedBytes=46)
            for evidence, charged, valid in (
                    ({"stopReason": "metering-failure", "stopAtMs": 95}, 46, False),
                    ({"stopReason": "metering-failure", "stopAtMs": 95}, 47, True),
                    ({"stopReason": "byte-limit", "stopAtMs": 95}, 46, True),
                    ({"stopReason": "metering-failure", "stopAtMs": 162}, 47, False)):
                health = sequenced_probe(phase, origin, chargedBytes=charged, haltDuringRetirement=evidence)
                count = 0 if origin == 0 else 3
                reason = evidence["stopReason"]
                checkpoint = row("checkpoint", reason=reason if not count else "three-no-http-timeouts",
                                 reservedCount=count, budgetStopReason=reason, chargedBytes=charged,
                                 budgetStopAtNs=(origin + 10 + evidence["stopAtMs"]) * NS_PER_MS)
                with self.subTest(phase=phase, reason=reason, charged=charged, at=evidence["stopAtMs"]):
                    if valid:
                        read(prefix + permit + health + checkpoint)
                    else:
                        with self.assertRaisesRegex(ValueError, "unwitnessed meter stop"):
                            read(prefix + permit + health)

            for reason, charge in (("metering-failure", 0), ("byte-limit", 0)):
                unprepared = row("health", phase=phase, outcome="failed", navigationIssued=False,
                                 documentCommitted=False, documentFinished=False, retirementState="unbound",
                                 transportQuiesced=True, retirementRequestedAtMs=100, retirementObservedMs=20,
                                 transportQuiescedAtMs=100, chargedBytes=charge,
                                 haltDuringRetirement={"stopReason": reason, "stopAtMs": 50})
                with self.subTest(unprepared=phase, reason=reason):
                    with self.assertRaisesRegex(ValueError, "unwitnessed meter stop"):
                        read(prefix + unprepared)
            premature = row("health", phase=phase, outcome="stopped", navigationIssued=False, documentCommitted=False,
                            documentFinished=False, preparationStartedAtNs=(origin + 14) * NS_PER_MS,
                            preparationDeadlineAtNs=(origin + 15_014) * NS_PER_MS,
                            stopReason="metering-failure", observationCutoffMs=3,
                            observedThroughAtNs=(origin + 75) * NS_PER_MS, chargedBytes=1, retirementState="unbound",
                            transportQuiesced=True, retirementRequestedAtMs=80, retirementObservedMs=20,
                            transportQuiescedAtMs=80)
            with self.subTest(before_preparation=phase), self.assertRaisesRegex(ValueError, "unwitnessed meter stop"):
                read(prefix + premature)

    def test_meter_stop_can_win_the_counter_lock_after_the_row_clock(self):
        for phase, prefix, origin, read in probe_fixtures():
            permit = challenge(NEXT_TOKEN, issued=origin + 140, appended=origin + 141, chargedBytes=46)
            for reason in ("metering-failure", "byte-limit"):
                charged = 46 if reason == "metering-failure" else LIMITS.bytes
                stop_at = (origin + 141) * NS_PER_MS + 1
                permit_with_settlement = change_row(permit, chargedBytes=charged)
                health = sequenced_probe(phase, origin, chargedBytes=charged,
                                         haltDuringRetirement={"stopReason": reason, "stopAtMs": 131,
                                                               "stopAtNs": stop_at})
                with self.subTest(phase=phase, reason=reason):
                    self.assertTrue(read(prefix + permit_with_settlement + health).halted)

        # A result's clock can precede the stop even when its counters include the settlement.
        result = change_row(RESULT, chargedBytes=LIMITS.bytes)
        stopped = stage("retirement", retirementState="confirmed", transportQuiesced=True, **WITNESSES,
                        retirementFirstPolledAtNs=3_301 * NS_PER_MS,
                        chargedBytes=LIMITS.bytes, haltDuringRetirement={"stopReason": "byte-limit", "stopAtMs": 299,
                                                                       "stopAtNs": 3_300 * NS_PER_MS + 1})
        self.assertTrue(read_campaign_receipt(READY + RESERVED + DISPATCH + result + stopped,
                                              TARGETS, IDENTITY, LIMITS).halted)

    def test_first_target_meter_stop_uses_result_and_serialized_samples(self):
        prefix = READY + RESERVED + change_row(DISPATCH, chargedBytes=46)
        result_fields = {"outcome": "stopped", "navigationIssued": True, "documentCommitted": False,
                         "documentFinished": False, "stopReason": "metering-failure",
                         "timelineMs": {"loadIssued": 1, "provisionalStart": 10}}
        for charged in (46, 47):
            result = stage("result", **result_fields, chargedBytes=charged)
            with self.subTest(first_result_charge=charged):
                if charged == 46:
                    with self.assertRaisesRegex(ValueError, "unwitnessed meter stop"):
                        read_campaign_receipt(prefix + result, TARGETS, IDENTITY, LIMITS)
                else:
                    self.assertTrue(read_campaign_receipt(prefix + result, TARGETS, IDENTITY, LIMITS).halted)

        for close_witness, at, charged, valid in (
                (False, 320, 46, False), (False, 320, 47, True), (True, 120, 46, True),
                (True, 305, 46, True)):
            result = change_row(RESULT, chargedBytes=46)
            active = READY + RESERVED + DISPATCH
            witnesses = WITNESSES
            if close_witness:
                active += challenge(NEXT_TOKEN, issued=3_105, appended=3_108)
                witnesses = WITNESSES | {"retirementFirstPolledAtNs": 3_308 * NS_PER_MS, "transportQuiescedAtMs": 357}
            retirement = stage("retirement", retirementState="confirmed", transportQuiesced=True, **witnesses,
                               chargedBytes=charged, haltDuringRetirement={"stopReason": "metering-failure",
                                                                         "stopAtMs": at})
            checkpoint = row("checkpoint", reason="metering-failure", reservedCount=1, chargedBytes=charged,
                             budgetStopReason="metering-failure", budgetStopAtNs=(3_001 + at) * NS_PER_MS)
            with self.subTest(close_witness=close_witness, at=at, charged=charged):
                if valid:
                    receipt = read_campaign_receipt(active + result + retirement + checkpoint, TARGETS, IDENTITY, LIMITS)
                    self.assertEqual(receipt.checkpoint, "metering-failure")
                else:
                    with self.assertRaisesRegex(ValueError, "unwitnessed meter stop|outside the target interval"):
                        read_campaign_receipt(active + result + retirement, TARGETS, IDENTITY, LIMITS)

    def test_meter_failure_charge_must_appear_in_the_first_proven_post_stop_sample(self):
        prefix = READY + RESERVED + DISPATCH
        for at, result_charge, valid in ((3_121, 0, False), (3_121, 1, True),
                                         (3_300, 0, True), (3_301, 0, True)):
            result = change_row(RESULT, chargedBytes=result_charge)
            retirement = stage("retirement", retirementState="confirmed", transportQuiesced=True,
                               chargedBytes=1, haltDuringRetirement={"stopReason": "metering-failure",
                                                                    "stopAtMs": at - 3_001}, **WITNESSES)
            native = prefix + result + retirement
            with self.subTest(at=at, result_charge=result_charge):
                if valid:
                    self.assertTrue(read_campaign_receipt(native, TARGETS, IDENTITY, LIMITS).halted)
                else:
                    with self.assertRaisesRegex(ValueError, "unwitnessed meter stop"):
                        read_campaign_receipt(native, TARGETS, IDENTITY, LIMITS)

    def test_synchronous_close_can_order_a_tied_stop_before_the_result_counter(self):
        sample, retirement = target_drain_fixture()
        result = sample.splitlines(keepends=True)[-1]
        active = READY + RESERVED + DISPATCH
        meter = {"stopReason": "metering-failure", "stopAtNs": 3_050 * NS_PER_MS, "stopAtMs": 49}
        for times, charged, pending, retired_charge, invalid in (
                (((49, 49), (50, 50)), 0, 0, 1, "unwitnessed meter stop"),
                (((49, 49), (50, 50)), 1, 0, 1, None),
                (((49, 49),), 0, 0, 1, None),
                (((48, 48), (50, 50)), 0, 0, 1, None),
                (((49, 49), (50, 50)), 1, 1, 2, None),
                (((49, 49), (50, 50)), 1, 0, 2, "grew beyond reservations outstanding after stop")):
            verified = active + permit_series(3_000, times) + change_row(result, chargedBytes=charged,
                                                                       reservedBytes=pending)
            stopped = change_row(retirement, haltDuringRetirement=meter, chargedBytes=retired_charge)
            self.assert_snapshot_paths(f"tie-meter-{times[0][0]}-{len(times)}-{charged}-{pending}-{retired_charge}",
                                       verified + stopped, verified=verified, invalid=invalid)

        # The existing live renewal keeps the fence asleep until 3,071 ms.
        # A tied stop at 3,050 ms can only be from close's own binding checks.
        for at, pending, valid in ((3_049, 0, False), (3_050, 0, False), (3_050, 1, True), (3_071, 0, True)):
            stopped = stage("retirement", elapsedMs=13_100, retirementState="confirmed", transportQuiesced=False,
                            retirementRequestedAtMs=48, retirementObservedMs=10_020,
                            retirementFirstPolledAtNs=3_050 * NS_PER_MS, retirementCommitAtMs=99,
                            haltDuringRetirement={"stopReason": "node-revision-changed", "stopAtMs": at - 3_001},
                            reservedBytes=1)
            verified = sample[:-len(result)] + change_row(result, reservedBytes=pending)
            self.assert_snapshot_paths(f"tie-close-counter-{at}-{pending}", verified + stopped, verified=verified,
                                       invalid=None if valid else "grew beyond reservations outstanding after stop")

    def test_checkpoint_can_only_charge_reservations_pending_after_stop(self):
        draining = stage("retirement", retirementState="confirmed", transportQuiesced=False, elapsedMs=13_200,
                         **(WITNESSES | {"transportQuiescedAtMs": None, "retirementObservedMs": 10_000}),
                         chargedBytes=1)
        active = READY + RESERVED + DISPATCH + RESULT
        for stopped, pending, charged, still_pending, valid in (
                (13_150, 0, 2, 0, False), (13_150, 1, 2, 0, True),
                (13_150, 1, 1, 0, True), (13_150, 1, 1, 2, False),
                (13_150, 1, 2, 1, False), (13_200, 0, 2, 0, True)):
            checkpoint = row("checkpoint", reason="metering-failure", reservedCount=1, budgetStopReason="metering-failure",
                             budgetStopAtNs=stopped * NS_PER_MS, chargedBytes=charged, reservedBytes=still_pending)
            native = active + change_row(draining, reservedBytes=pending) + checkpoint
            with self.subTest(stopped=stopped, pending=pending, charged=charged, still_pending=still_pending):
                if valid:
                    self.assertEqual(read_campaign_receipt(native, TARGETS, IDENTITY, LIMITS).checkpoint, "metering-failure")
                else:
                    with self.assertRaisesRegex(ValueError, "grew beyond reservations outstanding after stop"):
                        read_campaign_receipt(native, TARGETS, IDENTITY, LIMITS)

        for phase, prefix, origin, read in probe_fixtures():
            permit = challenge(NEXT_TOKEN, issued=origin + 125, appended=origin + 126)
            health = sequenced_probe(phase, origin, chargedBytes=1, haltDuringRetirement={
                "stopReason": "metering-failure", "stopAtMs": 115,
            })
            with self.subTest(phase=phase):
                with self.assertRaisesRegex(ValueError, "unwitnessed meter stop"):
                    read(prefix + permit + health)
                read(prefix + change_row(permit, chargedBytes=1) + health)

        draining = stage("retirement", retirementState="confirmed", transportQuiesced=False, elapsedMs=13_200,
                         **(WITNESSES | {"transportQuiescedAtMs": None, "retirementObservedMs": 10_000}))
        active = READY + RESERVED + DISPATCH + RESULT
        for at, retirement_charge, valid in ((13_150, 0, False), (13_150, 1, True), (13_200, 0, True)):
            checkpoint = row("checkpoint", reason="metering-failure", reservedCount=1, chargedBytes=1,
                             budgetStopReason="metering-failure", budgetStopAtNs=at * NS_PER_MS)
            native = active + change_row(draining, chargedBytes=retirement_charge) + checkpoint
            with self.subTest(checkpoint_meter_stop=at, retirement_charge=retirement_charge):
                if valid:
                    self.assertEqual(read_campaign_receipt(native, TARGETS, IDENTITY, LIMITS).checkpoint,
                                     "metering-failure")
                else:
                    with self.assertRaisesRegex(ValueError, "unwitnessed meter stop"):
                        read_campaign_receipt(native, TARGETS, IDENTITY, LIMITS)

    def test_meter_failure_charge_orders_ambiguous_permit_and_retirement_counter_reads(self):
        for phase, prefix, origin, _ in probe_fixtures():
            targets = TIMEOUT_TARGETS if origin else TARGETS
            limits = replace(LIMITS, targets=len(targets))
            for accepted in (False, True):
                for permit_charge, witnessed in ((1, 1), (0, 1), (1, 2)):
                    permit = challenge(NEXT_TOKEN, issued=origin + 15, chargedBytes=permit_charge)
                    health = stopped_load_probe(phase, origin, reason="metering-failure", stopped=16,
                                                load=20, accepted=accepted, charged=witnessed)
                    verified = prefix + permit
                    self.assert_snapshot_paths(f"load-meter-charge-{origin}-{accepted}-{permit_charge}-{witnessed}",
                                               verified + health, verified=verified, targets=targets, limits=limits,
                                               invalid="load follows a permit published at or after the stop"
                                               if permit_charge == witnessed else None)

        entry_charge = 45
        prior = GRANTED + healthy(chargedBytes=entry_charge)
        dispatched = stage("dispatch", elapsedMs=3_020, navigationIssuedAtNs=3_020 * NS_PER_MS,
                           chargedBytes=entry_charge + 1)
        stopped = stage("result", outcome="stopped", stopReason="metering-failure", observationCutoffMs=15,
                        observedThroughAtNs=3_075 * NS_PER_MS, navigationIssued=True,
                        navigationIssuedAtNs=3_020 * NS_PER_MS, documentCommitted=False, documentFinished=False,
                        timelineMs={}, observedAfterCutoff={"timelineMs": {"loadIssued": 19}},
                        chargedBytes=entry_charge + 1)
        for charged in (entry_charge, entry_charge + 1):
            permit = challenge(NEXT_TOKEN, issued=3_015, chargedBytes=charged)
            verified = prior + change_row(RESERVED, chargedBytes=entry_charge) + permit + dispatched
            self.assert_snapshot_paths(f"target-load-meter-charge-{charged}", verified + stopped, verified=verified,
                                       invalid="load follows a permit published at or after the stop"
                                       if charged > entry_charge else None)

        active = prior + b"".join(change_row(item, chargedBytes=entry_charge) for item in (RESERVED, DISPATCH, RESULT))
        for at, pending, charge, after_pending, valid in (
                (13_200, 0, 46, 1, False), (13_201, 0, 46, 1, False),
                (13_200, 0, 46, 0, True), (13_201, 2, 46, 1, True), (13_199, 1, 47, 0, True)):
            draining = stage("retirement", retirementState="confirmed", transportQuiesced=False, elapsedMs=13_200,
                             **(WITNESSES | {"transportQuiescedAtMs": None, "retirementObservedMs": 10_000}),
                             chargedBytes=entry_charge + 1, reservedBytes=pending)
            checkpoint = row("checkpoint", reason="metering-failure", reservedCount=1, budgetStopReason="metering-failure",
                             budgetStopAtNs=at * NS_PER_MS, chargedBytes=charge, reservedBytes=after_pending)
            self.assert_snapshot_paths(f"checkpoint-meter-charge-{at}-{pending}-{after_pending}",
                                       active + draining + checkpoint, verified=active + draining,
                                       invalid=None if valid else "grew beyond reservations outstanding after stop")

    def test_retirement_counter_sample_at_expiry_bounds_later_charges(self):
        limits = replace(LIMITS, permit_window_ms=13_200)
        prefix = change_row(START, **limits.fields()) + (READY + RESERVED + DISPATCH + RESULT)[len(START):]
        checkpoint = row("checkpoint", reason="run-permit-expired", reservedCount=1, chargedBytes=2,
                         budgetStopReason="run-permit-expired", budgetStopAtNs=13_200 * NS_PER_MS)
        for at, pending, valid in ((13_199, 0, True), (13_200, 0, False), (13_200, 1, True), (13_201, 0, False)):
            retirement = stage("retirement", elapsedMs=at, retirementState="confirmed", transportQuiesced=False,
                               **(WITNESSES | {"transportQuiescedAtMs": None, "retirementObservedMs": 10_000}),
                               chargedBytes=1, reservedBytes=pending)
            self.assert_snapshot_paths(f"counter-drain-{at}-{pending}", prefix + retirement + checkpoint,
                                       verified=prefix + retirement, limits=limits,
                                       invalid=None if valid else "grew beyond reservations outstanding after stop")

    def test_retirement_callbacks_refine_the_pre_stop_sample_for_a_result_witness(self):
        permit = challenge(NEXT_TOKEN, issued=3_030, appended=3_031, chargedBytes=1, reservedBytes=1)
        prefix = READY + RESERVED + DISPATCH + permit
        result = stage("result", outcome="stopped", navigationIssued=True, stopReason="metering-failure",
                       observationCutoffMs=39, observedThroughAtNs=3_045 * NS_PER_MS,
                       documentCommitted=False, documentFinished=False, chargedBytes=1)
        for callback, result_charge, valid in ((None, 1, True), (30, 1, False), (30, 2, True),
                                               (34, 1, False), (34, 2, True)):
            original = None if callback is None else {"timelineMs": {"provisionalStart": callback}}
            retirement = stage("retirement", retirementState="confirmed", transportQuiesced=True,
                               originalNavigationAfterClose=original, chargedBytes=2,
                               **(WITNESSES | {"retirementRequestedAtMs": 28, "retirementObservedMs": 340}))
            active = prefix + change_row(result, chargedBytes=result_charge, reservedBytes=2 - result_charge)
            with self.subTest(callback=callback, result_charge=result_charge):
                self.assertTrue(read_campaign_receipt(active, TARGETS, IDENTITY, LIMITS).halted)
                if valid:
                    self.assertTrue(read_campaign_receipt(active + retirement, TARGETS, IDENTITY, LIMITS).halted)
                else:
                    with self.assertRaisesRegex(ValueError, "unwitnessed meter stop"):
                        read_campaign_receipt(active + retirement, TARGETS, IDENTITY, LIMITS)
        tied = change_row(permit, challengeIssuedAtNs=3_031 * NS_PER_MS)
        retirement = stage("retirement", retirementState="confirmed", transportQuiesced=True,
                           originalNavigationAfterClose={"timelineMs": {"provisionalStart": 30}},
                           **(WITNESSES | {"retirementRequestedAtMs": 28, "retirementObservedMs": 340}),
                           chargedBytes=1)
        self.assertTrue(read_campaign_receipt(READY + RESERVED + DISPATCH + tied + result + retirement,
                                              TARGETS, IDENTITY, LIMITS).halted)

    def test_byte_cap_carries_first_stop_requirements_through_retirement_and_checkpoint(self):
        cap = LIMITS.bytes
        draining = stage("retirement", retirementState="confirmed", transportQuiesced=False, elapsedMs=13_102,
                         **(WITNESSES | {"transportQuiescedAtMs": None, "retirementObservedMs": 10_000}),
                         chargedBytes=cap)
        prefix = READY + RESERVED + DISPATCH
        capped = prefix + change_row(RESULT, chargedBytes=cap)
        absent = row("checkpoint", reason="transport-quiescence-unconfirmed", reservedCount=1, chargedBytes=cap)
        for reason, at in (("byte-limit", 14_000), ("run-permit-expired", 30_000)):
            stop = row("checkpoint", elapsedMs=30_001, reason=reason, reservedCount=1, chargedBytes=cap,
                       budgetStopReason=reason, budgetStopAtNs=at * NS_PER_MS)
            with self.subTest(stop=reason), self.assertRaisesRegex(ValueError, "earlier byte-cap sample"):
                read_campaign_receipt(capped + draining + stop, TARGETS, IDENTITY, LIMITS)
        with self.assertRaisesRegex(ValueError, "earlier byte-cap sample"):
            read_campaign_receipt(capped + draining + absent, TARGETS, IDENTITY, LIMITS)
        with self.assertRaisesRegex(ValueError, "earlier byte-cap sample"):
            read_campaign_receipt(prefix + RESULT + draining + absent, TARGETS, IDENTITY, LIMITS)
        # The checkpoint reads the stop before its own counter lock.
        self.assertEqual(read_campaign_receipt(prefix + RESULT + change_row(draining, chargedBytes=0) + absent,
                                               TARGETS, IDENTITY, LIMITS).checkpoint, "transport-quiescence-unconfirmed")

        first_sample = change_row(draining, retirementFirstPolledAtNs=3_310 * NS_PER_MS)
        for reason, at, valid in (("external-stop", 3_120, True), ("metering-failure", 3_310, True),
                                  ("byte-limit", 3_311, False), ("external-stop", 3_320, False)):
            stopped = change_row(first_sample, haltDuringRetirement={
                "stopReason": reason, "stopAtMs": at - 3_001, "stopAtNs": at * NS_PER_MS})
            checkpoint = row("checkpoint", reason=reason, reservedCount=1, chargedBytes=cap,
                             budgetStopReason=reason, budgetStopAtNs=at * NS_PER_MS)
            with self.subTest(stop=reason, at=at):
                if valid:
                    self.assertEqual(read_campaign_receipt(capped + stopped + checkpoint, TARGETS, IDENTITY, LIMITS)
                                     .checkpoint, reason)
                else:
                    with self.assertRaisesRegex(ValueError, "earlier byte-cap sample"):
                        read_campaign_receipt(capped + stopped, TARGETS, IDENTITY, LIMITS)

        for window, valid in ((3_309, True), (3_311, False)):
            limits = CampaignLimits(LIMITS.targets, LIMITS.duration_seconds, cap, window)
            stopped = change_row(first_sample, haltDuringRetirement={
                "stopReason": "run-permit-expired", "stopAtMs": window - 3_001, "stopAtNs": window * NS_PER_MS})
            checkpoint = row("checkpoint", reason="run-permit-expired", reservedCount=1, chargedBytes=cap,
                             budgetStopReason="run-permit-expired", budgetStopAtNs=window * NS_PER_MS)
            native = change_row(START, **limits.fields()) + capped[len(START):] + stopped + checkpoint
            with self.subTest(lease=window):
                if valid:
                    self.assertEqual(read_campaign_receipt(native, TARGETS, IDENTITY, limits).checkpoint,
                                     "run-permit-expired")
                else:
                    with self.assertRaisesRegex(ValueError, "earlier byte-cap sample"):
                        read_campaign_receipt(native, TARGETS, IDENTITY, limits)

        for phase, prefix, origin, read in probe_fixtures():
            permit = challenge(NEXT_TOKEN, issued=origin + 400, chargedBytes=cap)
            health = healthy(phase=phase, transportQuiesced=False, retirementObservedMs=10_000,
                             transportQuiescedAtMs=None, elapsedMs=origin + 10_111, chargedBytes=cap)
            count = 0 if not origin else 3
            stop = row("checkpoint", reason="byte-limit" if not count else "three-no-http-timeouts",
                       reservedCount=count, chargedBytes=cap, budgetStopReason="byte-limit",
                       budgetStopAtNs=(origin + 10_112) * NS_PER_MS)
            with self.subTest(phase=phase):
                with self.assertRaisesRegex(ValueError, "earlier byte-cap sample"):
                    read(prefix + permit + health + stop)
                absent = change_row(stop, reason="three-no-http-timeouts" if count else "health-check-failed",
                                    budgetStopReason=None, budgetStopAtNs=None)
                with self.assertRaisesRegex(ValueError, "earlier byte-cap sample"):
                    read(prefix + health + absent)
                self.assertEqual(read(prefix + change_row(health, chargedBytes=0) + absent).checkpoint,
                                 json.loads(absent)["reason"])

    def test_capped_counter_read_precedes_a_later_main_actor_poll_stop(self):
        cap = LIMITS.bytes
        for phase, prefix, origin, read in probe_fixtures():
            close = challenge(NEXT_TOKEN, issued=origin + 95, appended=origin + 97)
            unavailable = {"stopReason": "run-control-unavailable", "stopAtMs": 87}
            health = sequenced_probe(phase, origin, haltDuringRetirement=unavailable)
            with self.subTest(phase=phase):
                self.assertTrue(read(prefix + close + health).halted)
                with self.assertRaisesRegex(ValueError, "earlier byte-cap sample"):
                    read(prefix + change_row(close, chargedBytes=cap) + change_row(health, chargedBytes=cap))
                prior = sequenced_probe(phase, origin, chargedBytes=cap, haltDuringRetirement={
                    "stopReason": "metering-failure", "stopAtMs": 86,
                })
                self.assertTrue(read(prefix + change_row(close, chargedBytes=cap) + prior).halted)

        target = READY + RESERVED + DISPATCH + RESULT
        checkpoint = row("checkpoint", reason="external-stop", reservedCount=1, budgetStopReason="external-stop",
                         budgetStopAtNs=3_600 * NS_PER_MS)
        self.assertEqual(read_campaign_receipt(target + RETIRED + checkpoint, TARGETS, IDENTITY, LIMITS)
                         .checkpoint, "external-stop")
        with self.assertRaisesRegex(ValueError, "earlier byte-cap sample"):
            read_campaign_receipt(target + change_row(RETIRED, chargedBytes=cap)
                                  + change_row(checkpoint, chargedBytes=cap), TARGETS, IDENTITY, LIMITS)

    def test_same_clock_original_callback_can_bound_the_earlier_cap(self):
        cap = LIMITS.bytes
        result = stage("result", outcome="stopped", navigationIssued=True, stopReason="byte-limit",
                       observationCutoffMs=39, observedThroughAtNs=3_045 * NS_PER_MS,
                       documentCommitted=False, documentFinished=False, chargedBytes=cap)
        retirement = stage("retirement", retirementState="confirmed", transportQuiesced=True,
                           originalNavigationAfterClose={"timelineMs": {"provisionalStart": 30}},
                           **(WITNESSES | {"retirementRequestedAtMs": 28, "retirementObservedMs": 340}),
                           chargedBytes=cap)
        for issued in (3_030, 3_031):
            permit = challenge(NEXT_TOKEN, issued=issued, appended=3_031, chargedBytes=cap)
            active = READY + RESERVED + DISPATCH + permit + result
            with self.subTest(issued=issued):
                self.assertTrue(read_campaign_receipt(active, TARGETS, IDENTITY, LIMITS).halted)
                if issued == 3_030:
                    with self.assertRaisesRegex(ValueError, "earlier byte-cap sample"):
                        read_campaign_receipt(active + retirement, TARGETS, IDENTITY, LIMITS)
                else:
                    self.assertTrue(read_campaign_receipt(active + retirement, TARGETS, IDENTITY, LIMITS).halted)

    def test_late_metering_failure_must_add_to_a_valid_retirement_permit_sample(self):
        draining = stage("retirement", retirementState="confirmed", transportQuiesced=False, elapsedMs=13_102,
                         **(WITNESSES | {"transportQuiescedAtMs": None, "retirementObservedMs": 10_000}),
                         chargedBytes=46)
        permit = challenge(NEXT_TOKEN, issued=4_000, chargedBytes=46, reservedBytes=2)
        target = READY + RESERVED + DISPATCH + RESULT + permit + draining
        for charge, valid in ((46, False), (47, True)):
            checkpoint = row("checkpoint", reason="metering-failure", budgetStopReason="metering-failure",
                             budgetStopAtNs=14_000 * NS_PER_MS, reservedCount=1, chargedBytes=charge)
            with self.subTest(page="target", charged=charge):
                if valid:
                    self.assertEqual(read_campaign_receipt(target + checkpoint, TARGETS, IDENTITY, LIMITS)
                                     .checkpoint, "metering-failure")
                else:
                    with self.assertRaisesRegex(ValueError, "unwitnessed meter stop"):
                        read_campaign_receipt(target + checkpoint, TARGETS, IDENTITY, LIMITS)

        for phase, prefix, origin, read in probe_fixtures():
            permit = challenge(NEXT_TOKEN, issued=origin + 400, chargedBytes=46, reservedBytes=2)
            for charge, valid in ((46, False), (47, True)):
                with self.subTest(page=phase, charged=charge):
                    health = healthy(phase=phase, transportQuiesced=False, retirementObservedMs=10_000,
                                     transportQuiescedAtMs=None, elapsedMs=origin + 10_111, chargedBytes=charge)
                    reason, count = ("metering-failure", 0) if origin == 0 else ("three-no-http-timeouts", 3)
                    stop = row("checkpoint", reason=reason, reservedCount=count, chargedBytes=charge,
                               budgetStopReason="metering-failure", budgetStopAtNs=(origin + 10_112) * NS_PER_MS)
                    if valid:
                        self.assertEqual(read(prefix + permit + health + stop).checkpoint, reason)
                    else:
                        with self.assertRaisesRegex(ValueError, "unwitnessed meter stop"):
                            read(prefix + permit + health + stop)

    def test_late_meter_stop_requires_a_page_that_could_have_started_stream_work(self):
        for prepared in (False, True):
            prep = {"preparationDeadlineAtNs": 18_001 * NS_PER_MS} if prepared else {}
            result = stage("result", outcome="failed", navigationIssued=False, documentCommitted=False,
                           documentFinished=False, **prep)
            late_sample = stage("retirement", retirementState="unbound", transportQuiesced=False, elapsedMs=13_103,
                                retirementRequestedAtMs=100, retirementFirstPolledAtNs=13_102 * NS_PER_MS,
                                retirementObservedMs=10_001)
            for reason, charge in (("byte-limit", 0), ("metering-failure", 1)):
                with self.subTest(stop=reason, prepared=prepared):
                    checkpoint = row("checkpoint", reason=reason, budgetStopReason=reason, reservedCount=1,
                                     budgetStopAtNs=14_000 * NS_PER_MS, chargedBytes=charge)
                    native = READY + RESERVED + result + late_sample + checkpoint
                    if prepared:
                        self.assertEqual(read_campaign_receipt(native, TARGETS, IDENTITY, LIMITS).checkpoint, reason)
                    else:
                        with self.assertRaisesRegex(ValueError, "unwitnessed meter stop"):
                            read_campaign_receipt(native, TARGETS, IDENTITY, LIMITS)

    def test_final_health_checkpoint_preserves_witnessed_meter_and_deadline_stops(self):
        timeout, read = three_timeout_fixture()
        prefix = timeout + PAUSED
        phase = "after-three-no-http-timeouts"
        final = healthy(phase=phase)
        fields = {"reason": "three-no-http-timeouts", "reservedCount": 3}
        for reason in ("metering-failure", "byte-limit"):
            with self.subTest(stop=reason), self.assertRaisesRegex(ValueError, "unwitnessed meter stop"):
                read(prefix + final + row("checkpoint", **fields, budgetStopReason=reason))
        stopped = healthy(phase=phase, outcome="stopped", documentFinished=False, chargedBytes=1,
                          observationCutoffMs=6, stopReason="metering-failure")
        witnessed = row("checkpoint", **fields, budgetStopReason="metering-failure",
                        budgetStopAtNs=10_016 * NS_PER_MS, chargedBytes=1)
        expired = row("checkpoint", **fields, budgetStopReason="run-permit-expired", elapsedMs=30_000)
        self.assertEqual(read(prefix + stopped + witnessed).checkpoint, "three-no-http-timeouts")
        self.assertEqual(read(prefix + final + expired).checkpoint, "three-no-http-timeouts")

    def test_issued_challenge_without_consumption_cannot_prove_traffic(self):
        self.observe("initial-grant", ARMED, token=INITIAL_TOKEN)
        with self.assertRaises(LedgerObservationUnavailable):
            self.observe("before-grant", ARMED + RESERVED + DISPATCH, token=INITIAL_TOKEN)
        self.observer = self.open_observer(recover=True)
        with self.assertRaises(LedgerObservationUnavailable):
            self.reconcile(ARMED, ARMED)
        self.assertEqual(self.replies, [INITIAL_TOKEN])

    def test_timeout_cannot_include_an_in_window_finish(self):
        timeout = stage("result", outcome="timeout", navigationIssued=True, documentCommitted=True, documentFinished=True)
        with self.assertRaises(ValueError):
            read_campaign_receipt(READY + RESERVED + DISPATCH + timeout, TARGETS, IDENTITY, LIMITS)

    def test_timeout_does_not_accept_malformed_http_or_earlier_policy_and_stop(self):
        for conflict in ({"firstVisibleHTTPStatus": False}, {"firstVisibleHTTPStatus": 700},
                         {"localPolicyRejection": "download-navigation"},
                         {"stopReason": "run-permit-expired"}, {"errorDomain": "NSURLErrorDomain", "errorCode": -1202}):
            result = stage("result", outcome="timeout", navigationIssued=True, documentCommitted=False,
                           documentFinished=False, **conflict)
            with self.subTest(conflict=conflict), self.assertRaises(ValueError):
                read_campaign_receipt(READY + RESERVED + DISPATCH + result, TARGETS, IDENTITY, LIMITS)

    def test_frozen_finish_and_error_free_timeout_require_matching_clock_evidence(self):
        late_finish = stage("result", outcome="finished", navigationIssued=True, documentCommitted=True,
            documentFinished=True, timelineMs={"loadIssued": 1, "documentCommit": 150, "documentFinish": 20_002},
            observationCutoffMs=20_001, elapsedMs=24_000)
        early_timeout = stage("result", outcome="timeout", navigationIssued=True, documentCommitted=False,
            documentFinished=False, timelineMs={"loadIssued": 1}, observationCutoffMs=200,
            errorDomain=None, errorCode=None)
        for result in (late_finish, early_timeout):
            with self.subTest(result=result), self.assertRaises(ValueError):
                read_campaign_receipt(READY + RESERVED + DISPATCH + result, TARGETS, IDENTITY, LIMITS)

    def test_cutoff_cannot_extend_past_the_target_or_health_navigation_window(self):
        target = stage("result", outcome="finished", navigationIssued=True, documentCommitted=True,
            documentFinished=True, timelineMs={"loadIssued": 1, "documentCommit": 150, "documentFinish": 20_002},
            observationCutoffMs=20_003, elapsedMs=24_000)
        health = healthy(elapsedMs=9_000, observationCutoffMs=8_002)
        for native in (READY + RESERVED + DISPATCH + target, GRANTED + health):
            with self.assertRaisesRegex(ValueError, "Frozen observation extends beyond"):
                read_campaign_receipt(native, TARGETS, IDENTITY, LIMITS)

    def test_result_written_after_expiry_is_valid_only_for_an_in_window_cutoff(self):
        prefix = (READY + stage("reserved", elapsedMs=29_000)
                  + stage("dispatch", elapsedMs=29_003, navigationIssuedAtNs=29_002 * NS_PER_MS))
        fields = {"outcome": "finished", "navigationIssued": True, "documentCommitted": True, "documentFinished": True,
                  "pageStartedAtNs": 29_001 * NS_PER_MS, "elapsedMs": 30_600}
        accepted = stage("result", **fields, observationCutoffMs=998, observedThroughAtNs=29_999 * NS_PER_MS)
        receipt = read_campaign_receipt(prefix + accepted, TARGETS, IDENTITY, LIMITS)
        self.assertEqual(receipt.attempts[0].result, "finished")
        self.assertTrue(receipt.halted)
        forged = stage("result", **fields, observationCutoffMs=1_500,
                       timelineMs={"loadIssued": 1, "documentCommit": 5, "documentFinish": 1_499})
        with self.assertRaisesRegex(ValueError, "Native observation clocks exceed the admission"):
            read_campaign_receipt(prefix + forged, TARGETS, IDENTITY, LIMITS)

    def test_hard_cutoffs_keep_the_winning_reason_in_frozen_late_and_checkpoint_evidence(self):
        prefix = (READY + stage("reserved", elapsedMs=29_000)
                  + stage("dispatch", elapsedMs=29_003, navigationIssuedAtNs=29_002 * NS_PER_MS))
        fields = {"outcome": "stopped", "navigationIssued": True, "documentCommitted": False, "documentFinished": False,
                  "pageStartedAtNs": 29_001 * NS_PER_MS, "elapsedMs": 30_030, "observationCutoffMs": 999}
        correct = stage("result", **fields, stopReason="run-permit-expired")
        self.assertTrue(read_campaign_receipt(prefix + correct, TARGETS, IDENTITY, LIMITS).halted)
        with self.assertRaisesRegex(ValueError, "Frozen observation does not match"):
            read_campaign_receipt(prefix + stage("result", **fields, stopReason="time-limit"), TARGETS, IDENTITY, LIMITS)

        late_fields = {"outcome": "finished", "navigationIssued": True, "documentCommitted": True,
                       "documentFinished": True, "elapsedMs": 30_030, "observationCutoffMs": 20_001,
                       "observedThroughAtNs": 30_000 * NS_PER_MS}
        for reason in ("run-permit-expired", "time-limit"):
            late = stage("result", **late_fields, observedAfterCutoff={"stopReason": reason, "stopAtMs": 26_999})
            if reason == "run-permit-expired":
                self.assertTrue(read_campaign_receipt(READY + RESERVED + DISPATCH + late, TARGETS, IDENTITY, LIMITS).halted)
            else:
                with self.assertRaisesRegex(ValueError, "Late stop lies outside"):
                    read_campaign_receipt(READY + RESERVED + DISPATCH + late, TARGETS, IDENTITY, LIMITS)

        tied = CampaignLimits(LIMITS.targets, 30, LIMITS.bytes, LIMITS.permit_window_ms)
        tied_native = row("start", **tied.fields()) + challenge(INITIAL_TOKEN, appended=2)
        correct = row("checkpoint", reason="time-limit", budgetStopReason="time-limit", reservedCount=0, elapsedMs=30_000)
        wrong = row("checkpoint", reason="run-permit-expired", budgetStopReason="run-permit-expired",
                    reservedCount=0, elapsedMs=30_000)
        self.assertEqual(read_campaign_receipt(tied_native + correct, TARGETS, IDENTITY, tied).checkpoint, "time-limit")
        with self.assertRaisesRegex(ValueError, "Invalid native checkpoint"):
            read_campaign_receipt(tied_native + wrong, TARGETS, IDENTITY, tied)

    def test_cutoff_for_a_stop_can_precede_page_creation_but_not_native_admission(self):
        limits = CampaignLimits(LIMITS.targets, LIMITS.duration_seconds, LIMITS.bytes, 3_000)
        prefix = row("start", elapsedMs=1, **limits.fields()) + READY[len(START):] + stage("reserved", elapsedMs=2_999)
        fields = {"outcome": "stopped", "navigationIssued": False, "documentCommitted": False,
                  "documentFinished": False, "stopReason": "run-permit-expired", "observedThroughAtNs": 3_002 * NS_PER_MS}
        late_write = stage("result", **fields, observationCutoffMs=-1)
        receipt = read_campaign_receipt(prefix + late_write, TARGETS, IDENTITY, limits)
        self.assertEqual(receipt.attempts[0].result, "stopped")
        early = stage("result", **fields, observationCutoffMs=-3)
        with self.assertRaisesRegex(ValueError, "Native observation clocks exceed the admission"):
            read_campaign_receipt(prefix + early, TARGETS, IDENTITY, limits)
        impossible_page = stage("result", **(fields | {"navigationIssued": True, "observedThroughAtNs": 3_004 * NS_PER_MS}),
                                observationCutoffMs=-1,
                                observedAfterCutoff={"timelineMs": {"loadIssued": 1}}, timelineMs={})
        with self.assertRaisesRegex(ValueError, "A stop before page creation cannot carry page activity"):
            read_campaign_receipt(prefix + DISPATCH + impossible_page, TARGETS, IDENTITY, limits)

    def test_stop_cannot_precede_a_completed_renewal_or_change_after_latching(self):
        renewed = READY + RESERVED + challenge(NEXT_TOKEN, issued=9_000)
        fields = {"outcome": "stopped", "navigationIssued": False, "documentCommitted": False, "documentFinished": False,
                  "stopReason": "external-stop", "elapsedMs": 10_000, "observedThroughAtNs": 9_002 * NS_PER_MS}
        with self.assertRaisesRegex(ValueError, "Frozen observation does not match"):
            read_campaign_receipt(renewed + stage("result", **fields, observationCutoffMs=999), TARGETS, IDENTITY, LIMITS)
        self.assertTrue(read_campaign_receipt(renewed + stage("result", **fields, observationCutoffMs=6_000),
                                             TARGETS, IDENTITY, LIMITS).halted)

        stopped = READY + RESERVED + DISPATCH + stage("result", outcome="stopped", navigationIssued=True,
            documentCommitted=False, documentFinished=False, stopReason="external-stop")
        second_stop = stage("retirement", retirementState="confirmed", transportQuiesced=True, **WITNESSES,
            haltDuringRetirement={"stopReason": "transport-lost", "stopAtMs": 340})
        with self.assertRaisesRegex(ValueError, "cannot latch a second"):
            read_campaign_receipt(stopped + second_stop, TARGETS, IDENTITY, LIMITS)
        settled = stopped + RETIRED
        wrong = row("checkpoint", elapsedMs=30_001, reason="run-permit-expired",
                    budgetStopReason="run-permit-expired", reservedCount=1)
        with self.assertRaisesRegex(ValueError, "Invalid native checkpoint"):
            read_campaign_receipt(settled + wrong, TARGETS, IDENTITY, LIMITS)
        correct = row("checkpoint", elapsedMs=30_001, reason="external-stop", budgetStopReason="external-stop",
                      budgetStopAtNs=3_021 * NS_PER_MS, reservedCount=1)
        self.assertEqual(read_campaign_receipt(settled + correct, TARGETS, IDENTITY, LIMITS).checkpoint, "external-stop")

    def test_hard_stop_is_exact_and_cannot_be_masked_or_omitted(self):
        native = (READY + stage("reserved", elapsedMs=29_000)
                  + stage("dispatch", elapsedMs=29_003, navigationIssuedAtNs=29_002 * NS_PER_MS))
        invalid = stage("result", outcome="stopped", navigationIssued=True, documentCommitted=False,
                        documentFinished=False, pageStartedAtNs=29_001 * NS_PER_MS, elapsedMs=30_010,
                        observationCutoffMs=999, stopReason="external-stop")
        with self.assertRaisesRegex(ValueError, "Frozen observation does not match"):
            read_campaign_receipt(native + invalid, TARGETS, IDENTITY, LIMITS)

        native = READY + RESERVED + DISPATCH
        late = {"outcome": "finished", "navigationIssued": True, "documentCommitted": True, "documentFinished": True,
                "elapsedMs": 30_010, "observationCutoffMs": 20_001, "observedThroughAtNs": 30_000 * NS_PER_MS}
        with self.assertRaisesRegex(ValueError, "Frozen observation does not match"):
            read_campaign_receipt(native + stage("result", **late), TARGETS, IDENTITY, LIMITS)
        hard_stop = {"stopReason": "run-permit-expired", "stopAtMs": 26_999}
        before_expiry = late | {"observedThroughAtNs": 30_000 * NS_PER_MS - 1}
        for changed in (stage("result", **before_expiry, observedAfterCutoff=hard_stop),
                        stage("result", **late, observedAfterCutoff=hard_stop | {"stopReason": "external-stop"})):
            with self.assertRaisesRegex(ValueError, "Late stop lies outside"):
                read_campaign_receipt(native + changed, TARGETS, IDENTITY, LIMITS)

    def test_policy_and_failure_dispositions_need_a_frozen_milestone(self):
        prefix = READY + RESERVED + DISPATCH
        fields = {"navigationIssued": True, "documentCommitted": False, "documentFinished": False,
                  "timelineMs": {"loadIssued": 1}}
        forged_policy = stage("result", **fields, outcome="policy-blocked", localPolicyRejection="download-navigation",
                              observedAfterCutoff={"timelineMs": {"policyRejection": 25}})
        forged_timeout = stage("result", **fields, outcome="timeout",
                               observedAfterCutoff={"timelineMs": {"navigationFailure": 25}})
        for forged in (forged_policy, forged_timeout):
            with self.assertRaisesRegex(ValueError, "Invalid frozen native disposition"):
                read_campaign_receipt(prefix + forged, TARGETS, IDENTITY, LIMITS)

    def test_navigation_timeout_cannot_use_a_preparation_milestone_or_a_rejected_load(self):
        fields = {"outcome": "timeout", "navigationIssued": True, "documentCommitted": False, "documentFinished": False}
        for milestones in ({"preparationFailure": 3}, {"navigationFailure": 0},
                           {"navigationFailure": 3, "loadNotAccepted": 2}):
            details = {"localLoadDisposition": "load-not-accepted"} if "loadNotAccepted" in milestones else {}
            result = stage("result", **fields, **details, timelineMs={"loadIssued": 1} | milestones)
            with self.assertRaisesRegex(ValueError, "Native failure milestone disagrees with the navigation phase|WebKit callbacks precede"):
                read_campaign_receipt(READY + RESERVED + DISPATCH + result, TARGETS, IDENTITY, LIMITS)

    def test_preparation_timeout_requires_its_exact_deadline(self):
        prefix = READY + RESERVED
        fields = {"outcome": "failed", "navigationIssued": False, "documentCommitted": False, "documentFinished": False,
                  "localPreparationDisposition": "preparation-timeout", "observationCutoffMs": 15_000, "elapsedMs": 22_000,
                  "observedThroughAtNs": 21_001 * NS_PER_MS, "timelineMs": {"preparationTimedOut": 15_000},
                  "observedAfterCutoff": {"stopAtMs": 16_000, "stopReason": "external-stop"}}
        finished = stage("result", **fields, preparationDeadlineAtNs=18_001 * NS_PER_MS)
        self.assertEqual(read_campaign_receipt(prefix + finished, TARGETS, IDENTITY, LIMITS).attempts[0].result, "failed")
        with self.assertRaisesRegex(ValueError, "Native preparation timeout has no matching deadline"):
            read_campaign_receipt(prefix + stage("result", **fields), TARGETS, IDENTITY, LIMITS)
        shortened = fields | {"preparationDeadlineAtNs": 3_002 * NS_PER_MS, "observationCutoffMs": 1,
                              "timelineMs": {"preparationTimedOut": 1}}
        with self.assertRaisesRegex(ValueError, "Invalid native preparation deadline"):
            read_campaign_receipt(prefix + stage("result", **shortened), TARGETS, IDENTITY, LIMITS)
        early_marker = fields | {"preparationStartedAtNs": 3_001 * NS_PER_MS + 1,
                                 "preparationDeadlineAtNs": 18_001 * NS_PER_MS + 1,
                                 "stopReason": "external-stop", "observedAfterCutoff": {}}
        with self.assertRaisesRegex(ValueError, "Native preparation timeout has no matching deadline"):
            read_campaign_receipt(prefix + stage("result", **early_marker), TARGETS, IDENTITY, LIMITS)
        bound_without_deadline = stage("result", outcome="failed", navigationIssued=False, documentCommitted=False,
            documentFinished=False, localLoadDisposition="load-not-accepted", preparationStartedAtNs=None,
            preparationDeadlineAtNs=None)
        with self.assertRaisesRegex(ValueError, "A bound page requires a native preparation deadline"):
            read_campaign_receipt(prefix + bound_without_deadline, TARGETS, IDENTITY, LIMITS)

    def test_preparation_clock_precedes_the_accepted_or_rejected_load(self):
        clock = {"preparationStartedAtNs": 3_004 * NS_PER_MS, "preparationDeadlineAtNs": 18_004 * NS_PER_MS}
        accepted = stage("result", outcome="finished", navigationIssued=True, documentCommitted=True, documentFinished=True, **clock)
        rejected = stage("result", outcome="failed", navigationIssued=False, documentCommitted=False, documentFinished=False,
                         localLoadDisposition="load-not-accepted", **clock)
        for receipt in (DISPATCH + accepted, rejected):
            with self.assertRaisesRegex(ValueError, "Native preparation must precede"):
                read_campaign_receipt(READY + RESERVED + receipt, TARGETS, IDENTITY, LIMITS)

    def test_reports_reject_unwitnessed_policy_and_document_labels(self):
        prefix = READY + RESERVED + DISPATCH
        fields = {"outcome": "failed", "navigationIssued": True, "documentCommitted": False,
                  "documentFinished": False, "errorDomain": "WebKitErrorDomain", "errorCode": 102}
        wrong = stage("result", **fields, navigationPolicy="additional-top-level-navigation")
        with self.assertRaisesRegex(ValueError, "Navigation policy label disagrees"):
            read_campaign_receipt(prefix + wrong, TARGETS, IDENTITY, LIMITS)
        accepted = stage("result", **fields, navigationPolicy="policy-interruption-unattributed")
        parsed = read_campaign_receipt(prefix + accepted, TARGETS, IDENTITY, LIMITS)
        self.assertEqual(parsed.attempts[0].evidence["navigationPolicy"], "policy-interruption-unattributed")
        supplement = stage("retirement", retirementState="confirmed", transportQuiesced=True, **WITNESSES,
                           originalNavigationAfterClose={"timelineMs": {}, "documentFinished": True})
        with self.assertRaisesRegex(ValueError, "Native document flags"):
            read_campaign_receipt(prefix + RESULT + supplement, TARGETS, IDENTITY, LIMITS)
        unsupported = stage("result", outcome="policy-blocked", navigationIssued=True, documentCommitted=False,
                            documentFinished=False, localPolicyRejection="no-local-rejection-observed",
                            navigationPolicy="no-local-rejection-observed")
        with self.assertRaisesRegex(ValueError, "Invalid frozen native disposition"):
            read_campaign_receipt(prefix + unsupported, TARGETS, IDENTITY, LIMITS)

    def test_bound_target_uses_the_same_transport_as_the_pilot(self):
        changed = stage("result", outcome="finished", navigationIssued=True, documentCommitted=True,
                        documentFinished=True, actualProtocol="http")
        with self.assertRaisesRegex(ValueError, "Invalid page binding evidence"):
            read_campaign_receipt(READY + RESERVED + DISPATCH + changed, TARGETS, IDENTITY, LIMITS)

    def test_late_result_and_original_retirement_milestones_are_bounded(self):
        prefix = READY + RESERVED + DISPATCH
        late_failure = stage("result", outcome="finished", navigationIssued=True, documentCommitted=True,
                             documentFinished=True, observedAfterCutoff={"timelineMs": {"navigationFailure": 43_000}})
        with self.assertRaisesRegex(ValueError, "Native milestones are outside"):
            read_campaign_receipt(prefix + late_failure, TARGETS, IDENTITY, LIMITS)
        committed = stage("result", outcome="failed", navigationIssued=True, documentCommitted=True, documentFinished=False)
        for at in (99, 351):
            retirement = stage("retirement", retirementState="confirmed", transportQuiesced=True, **WITNESSES,
                               originalNavigationAfterClose={"timelineMs": {"documentFinish": at}})
            with self.assertRaisesRegex(ValueError, "Native milestones are outside"):
                read_campaign_receipt(prefix + committed + retirement, TARGETS, IDENTITY, LIMITS)
        retirement = stage("retirement", retirementState="confirmed", transportQuiesced=True, **WITNESSES,
                           originalNavigationAfterClose={"timelineMs": {"documentFinish": 320}})
        self.assertTrue(read_campaign_receipt(prefix + committed + retirement, TARGETS, IDENTITY, LIMITS)
                        .attempts[0].settled)
        fake_http = stage("retirement", retirementState="confirmed", transportQuiesced=True, **WITNESSES,
                          originalNavigationAfterClose={"timelineMs": {}, "initialHTTPStatus": 200})
        with self.assertRaisesRegex(ValueError, "Invalid original WebKit callbacks"):
            read_campaign_receipt(prefix + RESULT + fake_http, TARGETS, IDENTITY, LIMITS)

    def test_late_stage_evidence_needs_a_callback_on_the_same_navigation(self):
        unbound = stage("result", outcome="failed", navigationIssued=False, documentCommitted=False,
                        documentFinished=False, observedAfterCutoff={"timelineMs": {"documentFinish": 25},
                                                                      "documentFinished": True})
        with self.assertRaisesRegex(ValueError, "WebKit callbacks precede"):
            read_campaign_receipt(READY + RESERVED + unbound, TARGETS, IDENTITY, LIMITS)
        fields = {"outcome": "timeout", "navigationIssued": True, "documentCommitted": True, "documentFinished": False,
                  "errorDomain": None, "errorCode": None, "observationCutoffMs": 20_001, "elapsedMs": 24_000}
        prefix = READY + RESERVED + DISPATCH
        legitimate = stage("result", **fields, observedAfterCutoff={"timelineMs": {"documentFinish": 20_002},
                                                                    "documentFinished": True})
        receipt = read_campaign_receipt(prefix + legitimate, TARGETS, IDENTITY, LIMITS)
        self.assertEqual(receipt.attempts[0].result, "timeout")
        for evidence in ({"errorDomain": "NSURLErrorDomain", "errorCode": -1202},
                         {"initialResponseObserved": True, "initialHTTPStatus": 200}):
            with self.assertRaisesRegex(ValueError, "Invalid frozen native disposition|Frozen HTTP status"):
                read_campaign_receipt(prefix + stage("result", **fields, observedAfterCutoff=evidence),
                                      TARGETS, IDENTITY, LIMITS)

    def test_same_millisecond_frozen_callback_cannot_precede_the_accepted_handle(self):
        dispatch = stage("dispatch", elapsedNs=3_002 * NS_PER_MS + 800_000,
                         navigationIssuedAtNs=3_002 * NS_PER_MS + 600_000)
        fields = {"outcome": "stopped", "navigationIssued": True, "documentCommitted": False, "documentFinished": False,
                  "observationCutoffMs": 1, "observationCutoffAtNs": 3_002 * NS_PER_MS + 500_000,
                  "navigationIssuedAtNs": 3_002 * NS_PER_MS + 600_000, "timelineMs": {},
                  "observedThroughAtNs": 3_003 * NS_PER_MS, "stopReason": "byte-limit",
                  "observedAfterCutoff": {"timelineMs": {"loadIssued": 1}, "timelineNs": {"loadIssued": 1_600_000}}}
        prefix = READY + RESERVED + dispatch
        self.assertTrue(read_campaign_receipt(prefix + stage("result", **fields), TARGETS, IDENTITY, LIMITS).halted)
        forged = fields | {"documentCommitted": True, "timelineMs": {"documentCommit": 1},
                           "timelineNs": {"documentCommit": 1_400_000}}
        with self.assertRaisesRegex(ValueError, "WebKit callbacks precede"):
            read_campaign_receipt(prefix + stage("result", **forged), TARGETS, IDENTITY, LIMITS)

    def test_redirect_counts_and_initial_response_require_the_original_navigation(self):
        unbound = stage("result", outcome="failed", navigationIssued=False, documentCommitted=False,
                        documentFinished=False, serverRedirectCount=1)
        with self.assertRaisesRegex(ValueError, "WebKit callbacks precede"):
            read_campaign_receipt(READY + RESERVED + unbound, TARGETS, IDENTITY, LIMITS)

        prefix = READY + RESERVED + DISPATCH
        late = {"firstVisibleHTTPStatus": 200, "initialHTTPStatus": 200, "lastHTTPStatus": 200, "initialResponseObserved": True}
        fields = {"outcome": "timeout", "navigationIssued": True, "documentCommitted": False, "documentFinished": False,
                  "errorDomain": None, "errorCode": None, "observationCutoffMs": 20_001, "elapsedMs": 24_000}
        proposals = [
            {"serverRedirectCount": 1, "observedAfterCutoff": late | {"timelineMs": {"firstVisibleHTTPResponse": 20_002}}},
            {"firstVisibleHTTPStatus": 302, "lastHTTPStatus": 302, "observedAfterCutoff": late},
        ]
        for proposal in proposals:
            with self.assertRaisesRegex(ValueError, "Late HTTP evidence misidentifies"):
                read_campaign_receipt(prefix + stage("result", **fields, **proposal), TARGETS, IDENTITY, LIMITS)
        late_after_redirect = (late | {"timelineMs": {"firstVisibleHTTPResponse": 20_002}, "initialResponseObserved": False})
        del late_after_redirect["initialHTTPStatus"]
        receipt = read_campaign_receipt(prefix + stage("result", **fields, serverRedirectCount=1,
                                        observedAfterCutoff=late_after_redirect), TARGETS, IDENTITY, LIMITS)
        self.assertEqual(receipt.attempts[0].evidence["observedAfterCutoff"]["lastHTTPStatus"], 200)

    def test_late_stop_must_fall_between_cutoff_and_the_recording_row(self):
        prefix = READY + RESERVED + DISPATCH
        for stop_ms in (20_000, 20_032, None):
            stop = {"stopAtMs": stop_ms, "stopReason": "external-stop"}
            observed = stage("result", outcome="finished", navigationIssued=True, documentCommitted=True,
                             documentFinished=True, observationCutoffMs=20_001, elapsedMs=24_000,
                             observedAfterCutoff=stop)
            with self.subTest(stop_ms=stop_ms), self.assertRaisesRegex(ValueError, "Late stop lies outside"):
                read_campaign_receipt(prefix + observed, TARGETS, IDENTITY, LIMITS)
        observed = stage("result", outcome="finished", navigationIssued=True, documentCommitted=True,
                         documentFinished=True, observationCutoffMs=20_001, elapsedMs=24_000,
                         observedAfterCutoff={"stopAtMs": 20_001, "stopAtNs": 23_002 * NS_PER_MS + 1,
                                              "stopReason": "external-stop"})
        self.assertTrue(read_campaign_receipt(prefix + observed, TARGETS, IDENTITY, LIMITS).halted)
        same_instant = stage("result", outcome="finished", navigationIssued=True, documentCommitted=True,
                            documentFinished=True, observedThroughAtNs=3_021 * NS_PER_MS,
                            observedAfterCutoff={"stopAtMs": 20, "stopReason": "external-stop"})
        with self.assertRaisesRegex(ValueError, "Native late observations require a nonempty"):
            read_campaign_receipt(prefix + same_instant, TARGETS, IDENTITY, LIMITS)

    def test_frozen_http_status_must_match_the_same_window_response_milestone(self):
        fields = {"outcome": "timeout", "navigationIssued": True, "documentCommitted": False,
                  "documentFinished": False, "timelineMs": {"loadIssued": 1},
                  "errorDomain": None, "errorCode": None, "observationCutoffMs": 20_001, "elapsedMs": 24_000,
                  "observedAfterCutoff": {"timelineMs": {"firstVisibleHTTPResponse": 20_002},
                                          "firstVisibleHTTPStatus": 200, "lastHTTPStatus": 200}}
        native = READY + RESERVED + DISPATCH
        receipt = read_campaign_receipt(native + stage("result", **fields), TARGETS, IDENTITY, LIMITS)
        self.assertNotIn("firstVisibleHTTPStatus", receipt.attempts[0].evidence)
        for contradiction in (fields | {"firstVisibleHTTPStatus": 200},
                              fields | {"timelineMs": {"loadIssued": 1, "firstVisibleHTTPResponse": 10},
                                        "observedAfterCutoff": {}}):
            with self.assertRaisesRegex(ValueError, "Frozen HTTP status and response milestone disagree"):
                read_campaign_receipt(native + stage("result", **contradiction), TARGETS, IDENTITY, LIMITS)

    def test_retirement_claims_need_separate_witnesses_inside_window(self):
        for witnesses in ({}, WITNESSES | {"retirementCommitAtMs": 10_101},
                          WITNESSES | {"transportQuiescedAtMs": 10_101},
                          WITNESSES | {"retirementCommitAtMs": 9_100},
                          WITNESSES | {"reservedBytes": 1}):
            entry = stage("retirement", retirementState="confirmed", transportQuiesced=True, **witnesses)
            with self.subTest(witnesses=witnesses), self.assertRaises(ValueError):
                read_campaign_receipt(READY + RESERVED + DISPATCH + RESULT + entry, TARGETS, IDENTITY, LIMITS)

    def test_witnesses_cannot_extend_past_their_recording_row(self):
        future_dispatch = stage("dispatch", navigationIssuedAtNs=26_000 * NS_PER_MS)
        earlier_dispatch = stage("dispatch", navigationIssuedAtNs=2_999 * NS_PER_MS)
        future_retirement = stage("retirement", retirementState="confirmed", transportQuiesced=True,
            retirementRequestedAtMs=590, retirementCommitAtMs=601,
            transportQuiescedAtMs=601, retirementObservedMs=11)
        future_result = stage("result", outcome="finished", navigationIssued=True, documentCommitted=True,
                              documentFinished=True, observationCutoffMs=301)
        for dispatch in (earlier_dispatch, future_dispatch):
            with self.assertRaisesRegex(ValueError, "Invalid or repeated native dispatch"):
                read_campaign_receipt(READY + RESERVED + dispatch, TARGETS, IDENTITY, LIMITS)
        native = READY + RESERVED + DISPATCH
        with self.assertRaisesRegex(ValueError, "Native observation clocks exceed"):
            read_campaign_receipt(native + future_result, TARGETS, IDENTITY, LIMITS)
        with self.assertRaisesRegex(ValueError, "Missing native retirement start"):
            read_campaign_receipt(native + RESULT + future_retirement, TARGETS, IDENTITY, LIMITS)

    def test_dispatch_and_result_cannot_predate_their_prior_synchronous_writes(self):
        prefix = READY + RESERVED + challenge(NEXT_TOKEN, issued=9_000)
        forged = stage("dispatch", elapsedMs=10_000, navigationIssuedAtNs=4_000 * NS_PER_MS)
        with self.assertRaisesRegex(ValueError, "Invalid or repeated native dispatch"):
            read_campaign_receipt(prefix + forged, TARGETS, IDENTITY, LIMITS)
        dispatch = stage("dispatch", elapsedMs=10_000, navigationIssuedAtNs=9_001 * NS_PER_MS)
        result = stage("result", outcome="finished", navigationIssued=True, documentCommitted=True, documentFinished=True,
                       pageStartedAtNs=9_000 * NS_PER_MS, elapsedMs=10_010)
        with self.assertRaisesRegex(ValueError, "Native observation clocks exceed the admission"):
            read_campaign_receipt(prefix + dispatch + result, TARGETS, IDENTITY, LIMITS)
        dispatch = stage("dispatch", elapsedMs=3_010)
        with self.assertRaisesRegex(ValueError, "WebKit callbacks precede the accepted dispatch write"):
            read_campaign_receipt(READY + RESERVED + dispatch + RESULT, TARGETS, IDENTITY, LIMITS)

    def test_quiescence_and_the_end_of_retirement_must_follow_the_result_write(self):
        prefix = READY + RESERVED + DISPATCH + RESULT
        early_end = stage("retirement", retirementState="confirmed", transportQuiesced=True, **HEALTH_WITNESSES)
        early_sample = stage("retirement", retirementState="confirmed", transportQuiesced=True,
                             **(WITNESSES | {"transportQuiescedAtMs": 125}))
        with self.assertRaisesRegex(ValueError, "Missing native retirement start"):
            read_campaign_receipt(prefix + early_end, TARGETS, IDENTITY, LIMITS)
        with self.assertRaisesRegex(ValueError, "Native retirement witness is outside"):
            read_campaign_receipt(prefix + early_sample, TARGETS, IDENTITY, LIMITS)
        self.assertTrue(read_campaign_receipt(prefix + RETIRED, TARGETS, IDENTITY, LIMITS).attempts[0].settled)
        early_probe_sample = healthy(transportQuiescedAtMs=10, retirementRequestedAtMs=8, retirementObservedMs=142)
        with self.assertRaisesRegex(ValueError, "Native retirement witness is outside"):
            read_campaign_receipt(GRANTED + early_probe_sample, TARGETS, IDENTITY, LIMITS)

    def test_retirement_witnesses_are_bound_to_the_actual_close_and_result_clock(self):
        prefix = READY + RESERVED + DISPATCH + RESULT
        for overrides, reason in (
            ({"retirementRequestedAtMs": 300, "retirementObservedMs": 100}, "Missing native retirement start"),
            ({"retirementCommitAtMs": 150}, "Replacement commit falls inside"),
            ({"retirementState": "unconfirmed"}, "Native retirement state disagrees with its commit witness"),
        ):
            fields = WITNESSES | {"retirementState": "confirmed", "transportQuiesced": True} | overrides
            with self.subTest(overrides=overrides), self.assertRaisesRegex(ValueError, reason):
                read_campaign_receipt(prefix + stage("retirement", **fields), TARGETS, IDENTITY, LIMITS)

        limits = CampaignLimits(LIMITS.targets, LIMITS.duration_seconds, LIMITS.bytes, 3_500)
        short = row("start", elapsedMs=1, **limits.fields()) + prefix[len(START):]
        fields = WITNESSES | {"retirementState": "confirmed", "transportQuiesced": True, "retirementObservedMs": 450}
        with self.assertRaisesRegex(ValueError, "Missing stop witness during retirement"):
            read_campaign_receipt(short + stage("retirement", **fields), TARGETS, IDENTITY, limits)
        fields["haltDuringRetirement"] = {"stopReason": "run-permit-expired", "stopAtMs": 499}
        self.assertTrue(read_campaign_receipt(short + stage("retirement", **fields), TARGETS, IDENTITY, limits).halted)

    def test_retirement_close_and_exit_poll_must_follow_native_lifecycle(self):
        prefix = READY + RESERVED + DISPATCH + RESULT
        fields = {"retirementState": "confirmed", "transportQuiesced": True}
        early_close = WITNESSES | {"retirementRequestedAtMs": 0, "retirementObservedMs": 400}
        with self.assertRaisesRegex(ValueError, "Missing native retirement start"):
            read_campaign_receipt(prefix + stage("retirement", **fields, **early_close), TARGETS, IDENTITY, LIMITS)
        no_commit = WITNESSES | {"retirementCommitAtMs": None, "retirementState": "unconfirmed", "transportQuiesced": True}
        with self.assertRaisesRegex(ValueError, "Native retirement exited without release"):
            read_campaign_receipt(prefix + stage("retirement", **no_commit), TARGETS, IDENTITY, LIMITS)
        with self.assertRaisesRegex(ValueError, "Native retirement exit poll contradicts"):
            read_campaign_receipt(GRANTED + healthy(transportQuiescedAtMs=125), TARGETS, IDENTITY, LIMITS)

    def test_replacement_commit_bounds_live_callbacks_and_the_next_poll(self):
        before_close = READY + RESERVED + DISPATCH
        result = stage("result", outcome="finished", navigationIssued=True, documentCommitted=True, documentFinished=True,
                       timelineMs={"loadIssued": 1, "documentCommit": 80, "documentFinish": 90}, observationCutoffMs=95)
        early_replacement = stage("retirement", retirementState="confirmed", transportQuiesced=True,
            **(WITNESSES | {"retirementRequestedAtMs": 50, "retirementCommitAtMs": 85}))
        with self.assertRaisesRegex(ValueError, "Live WebKit callbacks cannot follow"):
            read_campaign_receipt(before_close + result + early_replacement, TARGETS, IDENTITY, LIMITS)

        prefix = before_close + RESULT
        too_fast = stage("retirement", retirementState="confirmed", transportQuiesced=True,
                         **WITNESSES, retirementFirstPolledAtNs=3_306 * NS_PER_MS)
        with self.assertRaisesRegex(ValueError, "exit poll precedes the first completed sleep"):
            read_campaign_receipt(prefix + too_fast, TARGETS, IDENTITY, LIMITS)

    def test_original_navigation_must_not_repeat_the_reported_commit_or_finish(self):
        fields = {"retirementState": "confirmed", "transportQuiesced": True}
        pending = stage("result", outcome="failed", navigationIssued=True, documentCommitted=False, documentFinished=False)
        for result, milestones, error in (
            (RESULT, {"documentFinish": 320}, "repeat observed document milestones"),
            (pending, {"documentFinish": 320}, "finished without its preceding commit"),
            (pending, {"documentCommit": 340, "documentFinish": 320}, "finished without its preceding commit"),
        ):
            native = READY + RESERVED + DISPATCH + result + stage("retirement", **fields, **WITNESSES,
                originalNavigationAfterClose={"timelineMs": milestones})
            with self.assertRaisesRegex(ValueError, error):
                read_campaign_receipt(native, TARGETS, IDENTITY, LIMITS)

    def test_dispatch_pause_keeps_health_evidence_but_rejects_a_new_reservation(self):
        native, read = three_timeout_fixture()
        extra = row("reserved", ordinal=4, host="fourth.invalid", attempt="owned-key-4", elapsedMs=13_000)
        paused = native + PAUSED
        final_health = healthy(phase="after-three-no-http-timeouts")
        receipt = read(paused + final_health)
        self.assertEqual(len(receipt.attempts), 3)
        self.assertTrue(receipt.halted)
        stopped_retirement = row("retirement", ordinal=3, host="third.invalid", attempt="owned-key-3",
            retirementState="confirmed", transportQuiesced=True, **TIMEOUT_WITNESSES,
            haltDuringRetirement={"stopReason": "external-stop", "stopAtMs": 349})
        settled_stop = native.rsplit(b"\n", 2)[0] + b"\n" + stopped_retirement
        with self.assertRaisesRegex(ValueError, "New traffic after native halt"):
            read(settled_stop + PAUSED)
        with self.assertRaises(ValueError):
            read(paused + final_health + final_health)
        with self.assertRaises(ValueError):
            missing_witness = final_health.replace(b'"retirementCommitAtMs": 150, ', b"")
            read(paused + missing_witness)
        for fields in ({"retirementState": "unbound"}, {"retirementState": []}, {"transportQuiesced": 1}):
            invalid = healthy(phase="after-three-no-http-timeouts", **fields)
            with self.assertRaisesRegex(ValueError, "Native retirement state disagrees"):
                read(paused + invalid)
        early_health = healthy(phase="after-three-no-http-timeouts", pageStartedAtNs=9_999 * NS_PER_MS)
        with self.assertRaisesRegex(ValueError, "Unexpected native health check"):
            read(paused + early_health)
        premature = row("checkpoint", reason="three-no-http-timeouts", reservedCount=3)
        with self.assertRaisesRegex(ValueError, "Invalid native checkpoint"):
            read(paused + premature)
        wrong_phase = row("checkpoint", reason="external-stop", reservedCount=3)
        with self.assertRaisesRegex(ValueError, "Invalid native checkpoint"):
            read(paused + wrong_phase)
        with_stop = row("checkpoint", reason="three-no-http-timeouts", reservedCount=3, budgetStopReason="external-stop")
        self.assertEqual(read(paused + with_stop).checkpoint, "three-no-http-timeouts")
        before_pause = row("checkpoint", reason="external-stop", reservedCount=3, budgetStopReason="external-stop")
        with self.assertRaisesRegex(ValueError, "unwitnessed poll stop"):
            read(native + before_pause)
        lost = row("checkpoint", reason="three-no-http-timeouts", reservedCount=3, budgetStopReason="transport-lost")
        with self.assertRaisesRegex(ValueError, "Invalid native checkpoint stop"):
            read(paused + lost)
        one_permit = challenge(NEXT_TOKEN, issued=10_001)
        second_permit = challenge(TOKEN.replace(b"f48", b"f38"), issued=10_012)
        publish_failed = row("checkpoint", reason="three-no-http-timeouts", reservedCount=3,
                             budgetStopReason="run-control-unavailable", budgetStopAtNs=10_002 * NS_PER_MS)
        self.assertEqual(read(paused + one_permit + publish_failed).checkpoint, "three-no-http-timeouts")
        initial_pending = challenge(TOKEN.replace(b"f48", b"f28"), issued=11, reservedBytes=64)
        initial_had_pending = native.replace(healthy(), initial_pending + healthy(), 1)
        self.assertEqual(read(initial_had_pending + PAUSED + one_permit + publish_failed).checkpoint,
                         "three-no-http-timeouts")
        with self.assertRaisesRegex(ValueError, "Invalid native checkpoint"):
            pending_read = challenge(NEXT_TOKEN, issued=10_001, reservedBytes=64)
            read(paused + pending_read + publish_failed)
        with self.assertRaisesRegex(ValueError, "Invalid native checkpoint"):
            read(paused + one_permit + with_stop)
        in_probe = paused + one_permit + second_permit
        with self.assertRaisesRegex(ValueError, "Invalid native checkpoint"):
            read(in_probe + with_stop)
        with self.assertRaisesRegex(ValueError, "unwitnessed poll stop"):
            read(in_probe + final_health + with_stop)
        completed = row("checkpoint", reason="three-no-http-timeouts", reservedCount=3)
        self.assertEqual(read(in_probe + final_health + completed).checkpoint, "three-no-http-timeouts")
        failed = healthy(phase="after-three-no-http-timeouts", retirementState="unconfirmed", transportQuiesced=False,
                         elapsedMs=20_200, outcome="failed", documentCommitted=False, documentFinished=False,
                         retirementCommitAtMs=None, transportQuiescedAtMs=None, retirementObservedMs=10_000)
        self.assertTrue(read(paused + failed).halted)
        for prefix in (native, paused + final_health):
            with self.assertRaises(ValueError):
                read(prefix + extra)


if __name__ == "__main__":
    unittest.main()

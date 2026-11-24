"""Read task-owned device ledgers and grant bounded native diagnostic traffic."""

import base64
import hashlib
import json
import os
import re
from bisect import bisect_left, bisect_right
from collections.abc import Sequence
from dataclasses import dataclass, replace
from pathlib import Path
from subprocess import TimeoutExpired
from tempfile import NamedTemporaryFile, mkdtemp
from time import monotonic, sleep

RUN_CHALLENGE = re.compile(rb"aegis-access-lease-v1 [0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\n")
SHA256 = re.compile(r"[0-9a-f]{64}")
HOST_NAME = re.compile(r"[a-z0-9_-]+(?:\.[a-z0-9_-]+)*")
MAX_SNAPSHOT_BYTES = 16 * 1024 * 1024
ATTEMPT_EVENTS = {"reserved", "dispatch", "result", "retirement"}
IDENTITY_FIELDS = {"campaignID", "device", "nodeInputSHA256", "sourceSHA", "targetsSHA256"}
ROW_FIELDS = IDENTITY_FIELDS | {"event", "schemaVersion", "elapsedNs", "elapsedMs", "chargedBytes", "reservedBytes"}
ATTEMPT_FIELDS = {"ordinal", "host", "attempt"}
RESULT_FIELDS = (
    "firstVisibleHTTPStatus", "initialResponseObserved", "initialHTTPStatus", "lastHTTPStatus",
    "documentCommitted", "documentFinished", "navigationPolicy", "localPolicyRejection",
    "localLoadDisposition", "localPreparationDisposition", "errorDomain", "errorCode",
    "serverRedirectCount", "timelineMs", "timelineNs", "observationCutoffMs", "stopReason", "observedAfterCutoff",
    "actualProtocol", "port",
)
PAGE_FIELDS = set(RESULT_FIELDS) | {
    "outcome", "navigationIssued", "pageStartedAtNs", "navigationIssuedAtNs", "preparationStartedAtNs",
    "preparationDeadlineAtNs", "observationCutoffAtNs", "observedThroughAtNs",
}
RETIREMENT_FIELDS = {
    "retirementState", "transportQuiesced", "retirementEvents", "retirementRequestedAtNs", "retirementRequestedAtMs",
    "retirementObservedMs", "retirementObservedThroughAtNs", "retirementCommitAtNs", "retirementCommitAtMs",
    "transportQuiescedAtNs", "transportQuiescedAtMs", "retirementFirstPolledAtNs", "retirementExitPolledAtNs",
    "originalNavigationAfterClose", "haltDuringRetirement",
}
EVENT_FIELDS = {
    "start": {"maxTargets", "durationLimitSeconds", "byteLimit", "runPermitWindowMs", "noHTTPTimeoutLimit", "bundle", "os", "network"},
    "permit": {"challengeSHA256", "challengeIssuedAtNs"},
    "reserved": ATTEMPT_FIELDS | {"admittedAtNs"},
    "dispatch": ATTEMPT_FIELDS | {"navigationIssuedAtNs"},
    "result": ATTEMPT_FIELDS | PAGE_FIELDS,
    "retirement": ATTEMPT_FIELDS | RETIREMENT_FIELDS,
    "health": PAGE_FIELDS | RETIREMENT_FIELDS | {"phase", "probeNonce", "healthAdmittedAtNs"},
    "dispatch-paused": {"reason", "reservedCount", "pausedAtNs"},
    "checkpoint": {"reason", "reservedCount", "budgetStopReason", "budgetStopAtNs"},
}
TARGET_OBSERVATION_MS = 20_000
HEALTH_OBSERVATION_MS = 8_000
NANOS_PER_MILLISECOND = 1_000_000
RETIREMENT_OBSERVATION_NS = 10_000 * NANOS_PER_MILLISECOND
# The native fence and retirement sampler both sleep for 50 ms.
FENCE_POLL_NS = 50 * NANOS_PER_MILLISECOND
PUBLISHER_POLL_NS = 2_000 * NANOS_PER_MILLISECOND
PREPARATION_NS = 15_000 * NANOS_PER_MILLISECOND
DEADLINE_STOP_REASONS = {"time-limit", "run-permit-expired"}
CAMPAIGN_TRANSPORT = "socks5"
NATIVE_STOP_REASONS = {
    "time-limit", "byte-limit", "external-stop", "metering-failure", "node-revision-changed", "transport-lost",
    "run-permit-expired", "run-control-unavailable",
}
METER_STOP_REASONS = {"byte-limit", "metering-failure"}
PAGE_STOP_REASONS = METER_STOP_REASONS | {"transport-lost"}
POLL_STOP_REASONS = {"external-stop", "node-revision-changed", "transport-lost", "run-control-unavailable"}
LOCAL_POLICY_REASONS = {
    "unsupported-mime-type", "additional-top-level-navigation", "download-navigation", "non-https-navigation",
}
WEBKIT_CALLBACKS = {"provisionalStart", "firstVisibleHTTPResponse", "documentCommit", "documentFinish",
                    "navigationFailure", "policyRejection"}
PAGE_MILESTONES = WEBKIT_CALLBACKS | {"loadIssued", "loadNotAccepted", "preparationFailure", "preparationTimedOut"}
ORIGINAL_CALLBACKS = {"provisionalStart", "documentCommit", "documentFinish", "navigationFailure"}
ORIGINAL_EVIDENCE_FIELDS = {
    "timelineMs", "timelineNs", "documentCommitted", "documentFinished", "initialResponseObserved", "serverRedirectCount",
    "navigationPolicy", "errorDomain", "errorCode",
}


class LedgerObservationUnavailable(RuntimeError):
    def __init__(self, message: str, observed_prefix: bytes):
        super().__init__(message)
        self.observed_prefix = observed_prefix


class LedgerPollDeferred(LedgerObservationUnavailable):
    pass


class LedgerPrefixChanged(LedgerObservationUnavailable):
    pass


class InvalidNativeRows(ValueError):
    def __init__(self, message: str, valid_prefix: bytes):
        super().__init__(message)
        self.valid_prefix = valid_prefix


def require_time(deadline: float, observed: bytes):
    if monotonic() >= deadline:
        raise LedgerPollDeferred("Native snapshot window ended", observed)


def bounded_snapshot(path: Path) -> tuple[bytes, bool]:
    with path.open("rb") as stream:
        raw = stream.read(MAX_SNAPSHOT_BYTES + 1)
    return raw[:MAX_SNAPSHOT_BYTES], len(raw) > MAX_SNAPSHOT_BYTES


def publish_snapshot(destination: Path, raw: bytes, *, update=False):
    # Preserve the prior canonical file and each raw copy attempt.
    with NamedTemporaryFile(dir=destination.parent, prefix=f".{destination.name}.", delete=False) as output:
        staged = Path(output.name)
        try:
            output.write(raw)
            output.flush()
            os.fsync(output.fileno())
            if update:
                os.replace(staged, destination)
            else:
                os.link(staged, destination)
            directory = os.open(destination.parent, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            staged.unlink(missing_ok=True)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate member in native JSON")
        result[key] = value
    return result


def copy_snapshot(copy, destination: Path, previous: bytes, previous_witness: bytes, report, validate, save, same_grant,
                  *, deadline: float, retry_delay=0):
    """Use only validated prefixes and require a fresh complete copy for authority."""
    if retry_delay < 0:
        raise ValueError("Snapshot retry delay must be nonnegative")
    observed = previous
    witness = previous_witness

    def report_attempt(number, outcome):
        try:
            report(number, outcome)
        except BaseException as error:
            raise LedgerObservationUnavailable("Could not record the native copy attempt", observed) from error

    def retain(*, disputed=False):
        save(observed, witness, disputed=disputed, pending=False)

    for number in range(1, 4):
        require_time(deadline, observed)
        if number > 1 and retry_delay:
            sleep(max(0, min(retry_delay, deadline - monotonic())))
            require_time(deadline, observed)
        try:
            folder = Path(mkdtemp(dir=destination.parent, prefix=f"{destination.stem}-copy-{number:02d}-"))
        except OSError as error:
            raise LedgerObservationUnavailable("Could not stage the native copy attempt", observed) from error
        attempt = folder / "device.jsonl"
        save(observed, witness, pending=True)
        transport_error = None
        interruption = None
        try:
            status = copy(attempt, deadline)
            if status != 0:
                transport_error = f"copy-exit-{status}"
        except TimeoutExpired:
            transport_error = "copy-timeout"
        except Exception as failure:
            transport_error = f"copy-error-{type(failure).__name__}"
        except BaseException as failure:
            transport_error = "copy-interrupted"
            interruption = failure
        try:
            raw, oversized = bounded_snapshot(attempt)
        except FileNotFoundError:
            retain()
            report_attempt(number, transport_error or "copy-without-file")
            if interruption is not None:
                raise LedgerObservationUnavailable("Native copy was interrupted", observed) from interruption
            continue
        except OSError as error:
            report_attempt(number, "invalid-copy")
            raise LedgerObservationUnavailable(str(error), observed) from error

        if oversized:
            # Even a complete foreign-looking prefix cannot establish what is
            # in the unread suffix. Commit the dispute before any exit path.
            save(observed, witness, disputed=True, pending=True)
        overlap = min(len(raw), len(witness))
        if raw[:overlap] != witness[:overlap]:
            retain(disputed=same_grant(raw) is not False)
            report_attempt(number, "rewritten-prefix")
            raise LedgerPrefixChanged("Device ledger changed after observation", observed)
        complete = raw.endswith(b"\n")
        prefix = raw[:raw.rfind(b"\n") + 1]
        if complete and len(prefix) < len(witness) and transport_error is None and not oversized:
            retain()
            report_attempt(number, "lost-prefix")
            raise LedgerPrefixChanged("Device ledger lost observed rows", observed)
        if len(raw) > len(witness) and same_grant(raw) is not False:
            witness = raw
        if prefix and len(prefix) >= len(observed):
            try:
                receipt = validate(prefix)
            except InvalidNativeRows as error:
                if len(error.valid_prefix) > len(observed):
                    observed = error.valid_prefix
                retain(disputed=same_grant(raw) is not False)
                report_attempt(number, "invalid-ledger")
                raise LedgerObservationUnavailable(str(error), observed) from error
            except ValueError as error:
                retain(disputed=same_grant(raw) is not False)
                report_attempt(number, "invalid-ledger")
                raise LedgerObservationUnavailable(str(error), observed) from error
            if len(prefix) > len(observed):
                observed = prefix
        retain(disputed=oversized and same_grant(raw) is not False)
        if oversized:
            report_attempt(number, "snapshot-size-limit")
            raise LedgerObservationUnavailable("Native snapshot exceeds the observation size limit", observed)
        if interruption is not None:
            report_attempt(number, transport_error)
            raise LedgerObservationUnavailable("Native copy was interrupted", observed) from interruption
        if transport_error or not complete:
            report_attempt(number, transport_error or "incomplete-copy")
            continue

        require_time(deadline, observed)
        try:
            publish_snapshot(destination, raw)
        except OSError as error:
            raise LedgerObservationUnavailable("Could not publish native observation", observed) from error
        report_attempt(number, "complete")
        require_time(deadline, observed)
        return observed, receipt
    raise LedgerObservationUnavailable("No complete native snapshot in three attempts", observed)


@dataclass(frozen=True)
class CampaignLimits:
    targets: int
    duration_seconds: int
    bytes: int
    permit_window_ms: int
    no_http_timeout_limit: int = 3

    def fields(self) -> dict[str, int]:
        return {
            "maxTargets": self.targets,
            "durationLimitSeconds": self.duration_seconds,
            "byteLimit": self.bytes,
            "runPermitWindowMs": self.permit_window_ms,
            "noHTTPTimeoutLimit": self.no_http_timeout_limit,
        }


@dataclass(frozen=True)
class StopWitness:
    reason: str
    instant_ns: int

    def applies_by(self, clock_ns: int) -> bool:
        # Deadlines take effect at equality. Other stops can race a counter read.
        return (self.instant_ns < clock_ns
                or (self.instant_ns == clock_ns and self.reason in DEADLINE_STOP_REASONS))


@dataclass(frozen=True)
class PermitSample:
    issued_ns: int
    row_ns: int
    charged: int
    pending: int
    after_dispatch: bool


@dataclass(frozen=True)
class ChargeSample:
    event: str
    elapsed_ns: int
    charged: int
    pending: int
    issued_ns: int | None = None

    def precedes(self, mark_ns: int) -> bool:
        return append_precedes_mark(self.issued_ns, self.elapsed_ns, mark_ns)


@dataclass(frozen=True)
class RetirementSample:
    observed_ns: int
    may_meter: bool
    charge_before_observation: int
    earlier_charge: int
    counters: ChargeSample


@dataclass(frozen=True)
class TrafficDeadline:
    instant_ns: int
    reason: str
    last_renewal_ns: int

    @classmethod
    def first(cls, lease_ns: int, batch_ns: int, last_renewal_ns: int):
        if lease_ns < batch_ns:
            return cls(lease_ns, "run-permit-expired", last_renewal_ns)
        return cls(batch_ns, "time-limit", last_renewal_ns)

    def matches(self, stop: StopWitness) -> bool:
        if stop.reason in DEADLINE_STOP_REASONS:
            return stop.reason == self.reason and stop.instant_ns == self.instant_ns
        return self.last_renewal_ns <= stop.instant_ns < self.instant_ns


@dataclass(frozen=True)
class PageObservation:
    started_ns: int
    observed_ns: int
    bound: bool
    preparation_started_ns: int | None
    dispatch_ns: int | None
    dispatch_written_ns: int | None
    milestones: dict[str, int]
    live_callback_floor_ns: int
    closing_policy_floor_ns: int | None
    closing_policy_through_ns: int | None
    stop: StopWitness | None

    @property
    def load_attempt_ns(self) -> int | None:
        rejected = self.milestones.get("loadNotAccepted")
        return self.dispatch_ns if rejected is None else self.started_ns + rejected

    @property
    def synchronous_failure_ns(self) -> int | None:
        # The preparation catch, load rejection, and owned WebKit failure
        # handlers (including content process termination) request close.
        failures = self.milestones.keys() & {"navigationFailure", "loadNotAccepted", "preparationFailure"}
        return min((self.started_ns + self.milestones[name] for name in failures), default=None)

    @property
    def preparation_catch_through_ns(self) -> int | None:
        """Latest possible clock check before recording a preparation failure."""
        failure = self.milestones.get("preparationFailure")
        prep = self.preparation_started_ns
        if failure is None or prep is None:
            return None
        return min(self.started_ns + failure, prep + PREPARATION_NS - 1)

    @property
    def preparation_timeout_ns(self) -> int | None:
        timeout = self.milestones.get("preparationTimedOut")
        return self.started_ns + timeout if timeout is not None else None

    @property
    def bound_abort(self) -> bool:
        return self.bound and self.load_attempt_ns is None

    @property
    def closed_before_observation(self) -> bool:
        return (self.synchronous_failure_ns is not None or self.closing_policy_floor_ns is not None
                or "preparationTimedOut" in self.milestones or self.bound_abort)

    def before_dispatch(self, permit: PermitSample) -> bool:
        return self.dispatch_written_ns is not None and not permit.after_dispatch


@dataclass(frozen=True)
class AttemptReceipt:
    ordinal: int
    host: str
    key: str
    admitted_ns: int
    reserved_ns: int
    dispatch_ns: int | None = None
    dispatch_written_ns: int | None = None
    result: str | None = None
    result_written_ns: int | None = None
    observation: PageObservation | None = None
    evidence: dict | None = None
    retirement: str | None = None
    transport_quiesced: bool | None = None
    retirement_evidence: dict | None = None

    @property
    def dispatch_confirmed(self) -> bool:
        return self.dispatch_ns is not None

    @property
    def settled(self) -> bool:
        return (self.result is not None and self.retirement in {"confirmed", "unbound"}
                and self.transport_quiesced is True)


@dataclass(frozen=True)
class CampaignReceipt:
    attempts: tuple[AttemptReceipt, ...]
    checkpoint: str | None
    challenge_sha256: str | None
    halted: bool

    def summary(self):
        return {
            "reserved": len(self.attempts),
            "dispatchConfirmed": sum(attempt.dispatch_confirmed for attempt in self.attempts),
            "reservedWithoutDispatchProof": sum(not attempt.dispatch_confirmed for attempt in self.attempts),
            "withResult": sum(attempt.result is not None for attempt in self.attempts),
            "withRetirement": sum(attempt.retirement is not None for attempt in self.attempts),
            "checkpoint": self.checkpoint,
            "nativeHalted": self.halted,
            "byOrdinal": [
                {"ordinal": attempt.ordinal, "reserved": True, "dispatchConfirmed": attempt.dispatch_confirmed,
                 "result": attempt.result, "retirement": attempt.retirement, "transportQuiesced": attempt.transport_quiesced,
                 **(attempt.evidence or {}), **(attempt.retirement_evidence or {})}
                for attempt in self.attempts
            ],
        }


@dataclass(frozen=True)
class ReconciledCampaign:
    receipt: CampaignReceipt

    def remaining_targets(self, planned: tuple[str, ...]) -> tuple[str, ...]:
        consumed = {canonical_host(attempt.host) for attempt in self.receipt.attempts}
        return tuple(host for host in planned if canonical_host(host) not in consumed)


def canonical_host(host: str) -> str:
    return host.lower().rstrip(".")


def validate_grant(targets: tuple[str, ...], identity: dict, limits: CampaignLimits):
    if (set(identity) != IDENTITY_FIELDS or len(targets) != limits.targets
            or any(not isinstance(host, str) or not HOST_NAME.fullmatch(host) for host in targets)
            or len(set(targets)) != len(targets)
            or not 1 <= limits.targets <= 100 or not 1 <= limits.duration_seconds <= 45 * 60
            or not 1 <= limits.bytes <= 512 * 1024 * 1024 or not 1 <= limits.permit_window_ms <= 30_000
            or limits.no_http_timeout_limit != 3):
        raise ValueError("Invalid frozen cohort or run limits")
    target_bytes = ("\n".join(targets) + "\n").encode()
    if hashlib.sha256(target_bytes).hexdigest() != identity["targetsSHA256"]:
        raise ValueError("Ordered targets differ from their frozen digest")


def read_campaign_receipt(raw: bytes, targets: tuple[str, ...], identity: dict, limits: CampaignLimits) -> CampaignReceipt:
    """Validate the complete native protocol before deriving any ordinal states."""
    validate_grant(targets, identity, limits)
    if not raw.endswith(b"\n"):
        raise ValueError("Incomplete native ledger")
    attempts = []
    keys = set()
    challenges = set()
    latest_challenge = None
    latest_permit: PermitSample | None = None
    grant_expires_ns = None
    permit_window_ns = limits.permit_window_ms * NANOS_PER_MILLISECOND
    batch_end_ns = limits.duration_seconds * 1_000_000_000
    checkpoint = None
    initial_grant_ns = None
    initial_health_seen = False
    initial_health = False
    final_health = False
    dispatch_paused_ns = None
    pause_decided_ns = None
    page_renewals: list[PermitSample] = []
    probe_had_pending_bytes = False
    quiescent_charge = 0
    retirement_renewals: list[PermitSample] = []
    page_charges: list[ChargeSample] = []
    target_guard_renewed = False
    no_http_timeouts = 0
    preparation_failures = 0
    halted = False
    first_stop = None
    last_retirement = None
    capped_sample: ChargeSample | None = None
    cap_bound_ns: int | None = None

    def retain_stop(previous_ns, *witnesses):
        nonlocal first_stop, halted
        for witness in witnesses:
            if witness is not None:
                if first_stop is not None:
                    raise ValueError("A native run cannot latch a second stop")
                validate_poll_stop_order(witness, previous_ns)
                first_stop = witness
                halted = True

    def validate_cap_stop(stop, *, required, upper_ns=None, poll_after_sample=False):
        nonlocal cap_bound_ns
        if (capped_sample is not None and poll_after_sample and stop is not None
                and stop.reason in POLL_STOP_REASONS):
            raise ValueError("Native poll stop disagrees with an earlier byte-cap sample")
        if cap_bound_ns is None:
            return
        if upper_ns is not None:
            cap_bound_ns = min(cap_bound_ns, upper_ns)
        if (stop is None and required) or (stop is not None and stop.instant_ns > cap_bound_ns):
            raise ValueError("Native stop disagrees with an earlier byte-cap sample")

    def constrain_page_cap(observation, retirement=None):
        if capped_sample is None:
            return
        marks = page_actor_marks(observation, retirement)
        # The dispatch append finishes before the result observation, and
        # the result append finishes before the first retirement sample.
        before_observation = (capped_sample.event == "dispatch"
                              or capped_sample.precedes(observation.observed_ns))
        bounds = [mark for mark in marks if capped_sample.precedes(mark)]
        if before_observation:
            bounds.append(observation.observed_ns)
        if retirement is not None:
            bounds.append(retirement["retirementFirstPolledAtNs" if capped_sample.event == "result"
                                     else "retirementExitPolledAtNs"])
        validate_cap_stop(observation.stop, required=before_observation, upper_ns=min(bounds, default=None))

    last_elapsed_ns = last_charged = 0
    previous_sample = None
    offset = 0
    for line in raw.splitlines(keepends=True):
        try:
            row = json.loads(line, object_pairs_hook=unique_object)
            if (not isinstance(row, dict) or checkpoint is not None
                    or type(row.get("schemaVersion")) is not int or row["schemaVersion"] != 3
                    or any(row.get(field) != value for field, value in identity.items())):
                raise ValueError("Native ledger identity or checkpoint changed")
            event = row.get("event")
            if not isinstance(event, str) or event not in EVENT_FIELDS:
                raise ValueError("Invalid native event")
            if row.keys() - ROW_FIELDS - EVENT_FIELDS[event]:
                raise ValueError(f"Unexpected evidence in a native {event} row")
            if halted and event in {"reserved", "dispatch", "permit", "dispatch-paused"}:
                raise ValueError("New traffic after native halt")
            late = row.get("observedAfterCutoff", {})
            if not isinstance(late, dict):
                raise ValueError("Invalid late native observations")
            elapsed, charged, pending = (row.get(field) for field in ("elapsedNs", "chargedBytes", "reservedBytes"))
            previous_elapsed, previous_charge = last_elapsed_ns, last_charged
            if (any(type(value) is not int for value in (elapsed, charged, pending)) or elapsed < previous_elapsed
                    or charged < previous_charge or pending < 0 or charged + pending > limits.bytes):
                raise ValueError("Invalid native budget observation")
            if type(row.get("elapsedMs")) is not int or row["elapsedMs"] != elapsed // NANOS_PER_MILLISECOND:
                raise ValueError("Native clock views disagree")
            sample = ChargeSample(event, elapsed, charged, pending, row.get("challengeIssuedAtNs"))
            # A following row runs after the prior append and its counter read.
            if capped_sample is not None:
                cap_bound_ns = elapsed if cap_bound_ns is None else min(cap_bound_ns, elapsed)
            last_elapsed_ns, last_charged = elapsed, charged
            if row.get("transportQuiesced") is True and pending != 0:
                raise ValueError("Quiescence conflicts with outstanding byte reservations")
            awaiting_health = not initial_health_seen or (dispatch_paused_ns is not None and not final_health)
            if awaiting_health:
                probe_had_pending_bytes |= pending > 0
            last = attempts[-1] if attempts else None
            awaiting_pause = (dispatch_paused_ns is None and last is not None and last.settled
                              and no_http_timeouts >= limits.no_http_timeout_limit)
            between_targets = (initial_health and dispatch_paused_ns is None and not awaiting_pause
                               and len(attempts) < limits.targets and preparation_failures < 3
                               and (last is None or last.settled))
            lease_end_ns = grant_expires_ns if grant_expires_ns is not None else permit_window_ns
            traffic_deadline = TrafficDeadline.first(lease_end_ns, batch_end_ns,
                                                     latest_permit.issued_ns if latest_permit else 0)
            halted |= elapsed >= batch_end_ns or charged >= limits.bytes
            if offset == 0:
                if event != "start" or any(type(row.get(field)) is not int or row[field] != value
                                           for field, value in limits.fields().items()):
                    raise ValueError("Native start does not match the frozen cohort limits")
                validate_worker_free(charged, pending, 0)
            elif event == "checkpoint":
                checkpoint = row.get("reason")
                probe_seen = not awaiting_health
                stop = validate_checkpoint_stop(row, traffic_deadline, first_stop,
                                                max(last_retirement.observed_ns if last_retirement else 0,
                                                    pause_decided_ns or 0),
                                                previous_ns=previous_elapsed, probe_seen=probe_seen,
                                                permit_seen=latest_permit is not None)
                validate_cap_stop(stop, required=True, poll_after_sample=first_stop is None)
                if (type(row.get("reservedCount")) is not int
                        or row["reservedCount"] != len(attempts)
                        or (last is not None and last.retirement is None)):
                    raise ValueError("Invalid native checkpoint")
                terminal_reason = None
                if dispatch_paused_ns is not None:
                    if final_health:
                        terminal_reason = "three-no-http-timeouts"
                elif initial_health_seen and not initial_health:
                    terminal_reason = "health-check-failed"
                elif last is not None:
                    if last.retirement == "unconfirmed":
                        terminal_reason = "retirement-unconfirmed"
                    elif not last.transport_quiesced:
                        terminal_reason = "transport-quiescence-unconfirmed"
                    elif preparation_failures >= 3:
                        terminal_reason = "repeated-preparation-failure"
                    elif len(attempts) == limits.targets and no_http_timeouts < limits.no_http_timeout_limit:
                        terminal_reason = "target-limit"
                if first_stop is None and stop is not None:
                    if stop.reason in POLL_STOP_REASONS:
                        if (not (awaiting_health or between_targets) or stop.reason == "transport-lost"
                                or (between_targets and target_guard_renewed and stop.reason != "run-control-unavailable")):
                            raise ValueError("Native checkpoint claims an unwitnessed poll stop")
                        validate_poll_stop_order(stop, previous_elapsed)
                if stop is not None:
                    earlier_samples = [previous_sample]
                    if last_retirement is not None and last_retirement.counters is not previous_sample:
                        earlier_samples.insert(0, last_retirement.counters)
                    after_stop = earlier_samples
                    if first_stop is None:
                        earlier_charge = None
                        if stop.reason in METER_STOP_REASONS:
                            earlier_charge = quiescent_charge
                            if last_retirement is not None:
                                earlier_charge = (last_retirement.earlier_charge if stop.instant_ns > last_retirement.observed_ns
                                                  else last_retirement.charge_before_observation)
                        first = first_post_stop_counter(stop, earlier_samples, charged, earlier_charge)
                        after_stop = earlier_samples[first:]
                        if earlier_charge is not None:
                            post_stop_charge = after_stop[0].charged if after_stop else charged
                            validate_meter_stop(stop, post_stop_charge, limits.bytes, earlier_charge,
                                                may_meter=last_retirement is not None and last_retirement.may_meter)
                    validate_stopped_counters([*after_stop, sample])
                expected = terminal_reason
                stopped_in_entry = (not probe_seen and stop is not None and charged == quiescent_charge and pending == 0
                                    and not probe_had_pending_bytes and len(page_renewals) < 2
                                    and (not page_renewals or stop.reason in DEADLINE_STOP_REASONS
                                         or stop.reason == "run-control-unavailable"))
                if dispatch_paused_ns is not None:
                    if stopped_in_entry:
                        expected = "three-no-http-timeouts"
                elif stop is not None:
                    expected = stop.reason if probe_seen or stopped_in_entry else None
                if expected is None or checkpoint != expected:
                    raise ValueError("Invalid native checkpoint")
                if not probe_seen or last_retirement is None or not last_retirement.may_meter:
                    validate_worker_free(charged, pending, quiescent_charge)
                halted = True
            elif event == "permit":
                if awaiting_pause or (between_targets and target_guard_renewed):
                    raise ValueError("No native poll available for challenge renewal")
                digest = row.get("challengeSHA256")
                issued = row.get("challengeIssuedAtNs")
                if not isinstance(digest, str) or not SHA256.fullmatch(digest) or digest in challenges:
                    raise ValueError("Invalid native run challenge receipt")
                if type(issued) is not int or not 0 <= issued <= elapsed:
                    raise ValueError("Missing or invalid native challenge issuance time")
                after_dispatch = last is not None and last.retirement is None and last.dispatch_confirmed
                permit = PermitSample(issued, elapsed, charged, pending, after_dispatch)
                if latest_permit is None:
                    if issued != 0:
                        raise ValueError("Initial challenge was not issued at native budget start")
                    validate_worker_free(charged, pending, 0)
                else:
                    prior_deadline = grant_expires_ns or latest_permit.issued_ns + permit_window_ns
                    if not previous_elapsed <= issued < min(prior_deadline, batch_end_ns):
                        raise ValueError("Native challenge issuance was outside the active window")
                    grant_expires_ns = latest_permit.issued_ns + permit_window_ns
                    if initial_grant_ns is None:
                        validate_worker_free(charged, pending, 0)
                        initial_grant_ns = elapsed
                    elif awaiting_health:
                        page_renewals.append(permit)
                        page_charges.append(sample)
                    elif between_targets:
                        validate_worker_free(charged, pending, quiescent_charge)
                        target_guard_renewed = True
                    elif last is not None and last.retirement is None:
                        if last.observation is None:
                            page_renewals.append(permit)
                        else:
                            if not retirement_renewals:
                                validate_page_renewals(page_renewals, last.observation, quiescent_charge, "target",
                                                       result_written_ns=last.result_written_ns,
                                                       waiting_renewals=(permit,))
                            elif not fence_slept(retirement_renewals[-1], permit):
                                raise ValueError("Native challenge renewal is outside the target interval")
                            retirement_renewals.append(permit)
                        page_charges.append(sample)
                latest_permit = permit
                latest_challenge = digest
                challenges.add(digest)
            elif event in ATTEMPT_EVENTS:
                ordinal = row.get("ordinal")
                key = row.get("attempt")
                if (type(ordinal) is not int or not 1 <= ordinal <= len(targets) or row.get("host") != targets[ordinal - 1]
                        or not isinstance(key, str) or not key or len(challenges) < 2 or not initial_health):
                    raise ValueError("Foreign native dispatch key or missing granted native run")
                if event == "reserved":
                    admitted = row.get("admittedAtNs")
                    if (dispatch_paused_ns is not None or no_http_timeouts >= limits.no_http_timeout_limit
                            or preparation_failures >= 3 or ordinal != len(attempts) + 1 or key in keys
                            or type(admitted) is not int or not previous_elapsed <= admitted <= elapsed
                            or grant_expires_ns is None or admitted >= traffic_deadline.instant_ns
                            or (attempts and not attempts[-1].settled)):
                        raise ValueError("Native reservation repeats or precedes retirement")
                    validate_worker_free(charged, pending, quiescent_charge)
                    attempts.append(AttemptReceipt(ordinal, targets[ordinal - 1], key, admitted, elapsed))
                    keys.add(key)
                    target_guard_renewed = False
                else:
                    if not attempts or ordinal != len(attempts) or key != attempts[-1].key:
                        raise ValueError("Native stage without the current reservation")
                    attempt, witness = record_stage(attempts[-1], event, row, previous_elapsed, traffic_deadline)
                    # The close's transport check can stop before the result append.
                    # It still follows any permit row that was already recorded.
                    poll_floor = latest_permit.row_ns if event == "retirement" else previous_elapsed
                    retain_stop(poll_floor, witness)
                    attempts[-1] = attempt
                    if event == "dispatch":
                        page_charges.append(sample)
                    elif event == "result":
                        observation = attempt.observation
                        halted |= validate_page_renewals(page_renewals, observation, quiescent_charge, "target",
                                                         result_written_ns=attempt.result_written_ns)
                        validate_page_metering(witness, row, observation, page_charges, quiescent_charge, limits.bytes)
                        constrain_page_cap(observation)
                        validate_cap_stop(witness, required=False, poll_after_sample=True)
                        page_charges.append(sample)
                        no_http = attempt.result == "timeout" and row.get("firstVisibleHTTPStatus") is None
                        no_http_timeouts = no_http_timeouts + 1 if no_http else 0
                        preparation_failures = 0 if attempt.dispatch_confirmed else preparation_failures + 1
                    elif event == "retirement":
                        observation = attempt.observation
                        if previous_elapsed > row["retirementExitPolledAtNs"]:
                            raise ValueError("Native retirement exit poll precedes the preceding row")
                        cap_at_result = capped_sample is not None and capped_sample.event == "result"
                        stopped_in_close = validate_page_renewals(
                            page_renewals, observation, quiescent_charge, "target", retirement=row,
                            retirement_stop=witness, result_written_ns=attempt.result_written_ns,
                            waiting_renewals=retirement_renewals, stop_before_result=cap_at_result)
                        constrain_page_cap(observation, row)
                        after_cap = capped_sample is not None and not (cap_at_result and stopped_in_close)
                        validate_cap_stop(observation.stop or witness, required=True,
                                          poll_after_sample=witness is not None and after_cap)
                        validate_page_metering(observation.stop or witness, row, observation, page_charges,
                                               quiescent_charge, limits.bytes,
                                               result_after_stop=observation.stop is not None or stopped_in_close)
                        retirement_renewals.clear()
                        halted |= (not attempt.settled or preparation_failures >= 3
                                   or (len(attempts) == limits.targets and no_http_timeouts < limits.no_http_timeout_limit))
            elif event == "dispatch-paused":
                decided = row.get("pausedAtNs")
                if (dispatch_paused_ns is not None or row.get("reason") != "three-no-http-timeouts"
                        or type(row.get("reservedCount")) is not int or row["reservedCount"] != len(attempts)
                        or no_http_timeouts < limits.no_http_timeout_limit
                        or type(decided) is not int or not previous_elapsed <= decided <= elapsed
                        or decided >= traffic_deadline.instant_ns
                        or not attempts or not attempts[-1].settled):
                    raise ValueError("Invalid native dispatch pause")
                validate_worker_free(charged, pending, quiescent_charge)
                dispatch_paused_ns = elapsed
                pause_decided_ns = decided
                probe_had_pending_bytes = False
            elif event == "health":
                phase = row.get("phase")
                initial = phase == "before-first-target" and not initial_health_seen and not attempts
                final = phase == "after-three-no-http-timeouts" and not final_health
                earliest_ns = initial_grant_ns if initial else dispatch_paused_ns if final else None
                admitted_ns = row.get("healthAdmittedAtNs")
                if (earliest_ns is None or first_stop is not None or type(admitted_ns) is not int
                        or not earliest_ns <= admitted_ns < traffic_deadline.instant_ns):
                    raise ValueError("Unexpected native health check")
                observation = validate_navigation_observation(row, admitted_ns, traffic_deadline, HEALTH_OBSERVATION_MS)
                later_stop = validate_retirement_witnesses(row, observation, traffic_deadline)
                retain_stop(previous_elapsed, observation.stop, later_stop)
                validate_page_renewals(page_renewals, observation, quiescent_charge, "health probe",
                                       admitted_ns=admitted_ns, retirement=row, retirement_stop=later_stop)
                validate_page_metering(observation.stop or later_stop, row, observation, page_charges,
                                       quiescent_charge, limits.bytes)
                constrain_page_cap(observation, row)
                validate_cap_stop(observation.stop or later_stop, required=True, poll_after_sample=True)
                if initial:
                    initial_health_seen = True
                    initial_health = (row.get("outcome") == "finished" and row.get("lastHTTPStatus") == 200
                                      and all(row.get(field) is True for field in
                                              ("navigationIssued", "documentCommitted", "documentFinished"))
                                      and row.get("actualProtocol") == CAMPAIGN_TRANSPORT
                                      and row.get("retirementState") == "confirmed"
                                      and row.get("transportQuiesced") is True)
                    if not initial_health:
                        halted = True
                else:
                    final_health = True
                    halted = True
            else:
                raise ValueError("Unknown native event")
            if event in {"health", "retirement"}:
                observed_ns = row["retirementObservedThroughAtNs"]
                may_meter = observation.preparation_started_ns is not None and not row["transportQuiesced"]
                last_retirement = RetirementSample(
                    observed_ns, may_meter,
                    charge_before(observed_ns, observation, row, page_charges, quiescent_charge), previous_charge,
                    sample)
                if not may_meter:
                    quiescent_charge = charged
                page_renewals.clear()
                page_charges.clear()
            if capped_sample is None and charged == limits.bytes:
                capped_sample = sample
            if latest_permit is not None:
                observed_expiry = grant_expires_ns or latest_permit.issued_ns + permit_window_ns
                halted |= elapsed >= observed_expiry
        except (ValueError, RecursionError) as error:
            raise InvalidNativeRows(str(error), raw[:offset]) from error
        previous_sample = sample
        offset += len(line)
    return CampaignReceipt(tuple(attempts), checkpoint, latest_challenge, halted)


def record_stage(attempt: AttemptReceipt, event: str, row: dict, previous_ns: int,
                 deadline: TrafficDeadline) -> tuple[AttemptReceipt, StopWitness | None]:
    if event == "dispatch":
        issued = row.get("navigationIssuedAtNs")
        if (attempt.dispatch_confirmed or attempt.result is not None or type(issued) is not int
                or not previous_ns <= issued <= row["elapsedNs"]):
            raise ValueError("Invalid or repeated native dispatch")
        return replace(attempt, dispatch_ns=issued, dispatch_written_ns=row["elapsedNs"]), None
    if event == "result":
        if attempt.result is not None or row.get("navigationIssuedAtNs") != attempt.dispatch_ns:
            raise ValueError("Result disagrees with the independent native navigation stages")
        observation = validate_navigation_observation(row, attempt.admitted_ns, deadline, TARGET_OBSERVATION_MS,
                                                      reserved_ns=attempt.reserved_ns,
                                                      dispatch_written_ns=attempt.dispatch_written_ns)
        return replace(attempt, result=row["outcome"], result_written_ns=row["elapsedNs"], observation=observation,
                       evidence={field: row[field] for field in RESULT_FIELDS if field in row}), observation.stop
    if attempt.observation is None or attempt.retirement is not None:
        raise ValueError("Invalid or repeated native retirement")
    witness = validate_retirement_witnesses(row, attempt.observation, deadline, result_written_ns=attempt.result_written_ns)
    evidence = {field: row[field] for field in
                ("transportQuiescedAtMs", "originalNavigationAfterClose", "haltDuringRetirement") if field in row}
    return replace(attempt, retirement=row["retirementState"], transport_quiesced=row["transportQuiesced"],
                   retirement_evidence=evidence), witness


def relative_milliseconds(stamp_ns: int, origin_ns: int) -> int:
    elapsed_ns = stamp_ns - origin_ns
    rounded = abs(elapsed_ns) // NANOS_PER_MILLISECOND
    return -rounded if elapsed_ns < 0 else rounded


def validate_poll_stop_order(stop: StopWitness, previous_ns: int):
    if stop.reason in POLL_STOP_REASONS and stop.instant_ns < previous_ns:
        raise ValueError("Native poll stop precedes the preceding row")


def validate_worker_free(charged: int, pending: int, entry_charge: int):
    if charged != entry_charge or pending != 0:
        raise ValueError("Native worker-free interval disagrees with byte counters")


def append_precedes_mark(issued_ns: int | None, row_ns: int, mark_ns: int) -> bool:
    # A MainActor event cannot interrupt the synchronous permit publication.
    return row_ns < mark_ns or (issued_ns is not None and issued_ns < mark_ns == row_ns)


def fence_slept(before: PermitSample, after: PermitSample) -> bool:
    return before.row_ns + FENCE_POLL_NS <= after.issued_ns


def page_navigation_marks(observation: PageObservation) -> set[int]:
    marks = {observation.started_ns, observation.preparation_started_ns, observation.dispatch_written_ns}
    marks.update(observation.started_ns + stamp for name, stamp in observation.milestones.items()
                 if name != "preparationTimedOut")
    marks.discard(None)
    return marks


def retirement_callback_marks(observation: PageObservation, retirement: dict) -> set[int]:
    original = retirement.get("originalNavigationAfterClose") or {}
    marks = {observation.started_ns + stamp for stamp in original.get("timelineNs", {}).values()}
    replacement = retirement.get("retirementCommitAtNs")
    if replacement is not None:
        marks.add(replacement)
    return marks


def retirement_actor_marks(observation: PageObservation, retirement: dict | None) -> set[int]:
    if retirement is None:
        return set()
    marks = {retirement.get(name) for name in (
        "transportQuiescedAtNs", "retirementFirstPolledAtNs", "retirementExitPolledAtNs",
        "retirementObservedThroughAtNs",
    )}
    marks.discard(None)
    return marks | retirement_callback_marks(observation, retirement)


def page_actor_marks(observation: PageObservation, retirement: dict | None) -> set[int]:
    marks = page_navigation_marks(observation) | {observation.observed_ns}
    if retirement is not None:
        marks |= retirement_actor_marks(observation, retirement) | {retirement["retirementRequestedAtNs"]}
    return marks


@dataclass(frozen=True)
class EarlyCloseWindow:
    live_through_ns: int
    request_from_ns: int
    request_through_ns: int
    checks_through_ns: int
    publisher_only: bool = False


def early_close_window(observation: PageObservation, requested: int | None,
                       retirement: dict | None, *, callback_before_final: bool) -> EarlyCloseWindow | None:
    observed = observation.observed_ns
    if (not observation.closed_before_observation and not callback_before_final
            and (requested is None or requested >= observed)):
        return None
    checks_through = min(retirement_actor_marks(observation, retirement) | {observed})
    live_through = observed
    request_from = max(observation.live_callback_floor_ns, observation.load_attempt_ns or observation.started_ns)
    failure_ns = observation.synchronous_failure_ns
    if failure_ns is not None:
        request_from = failure_ns
        catch_through = observation.preparation_catch_through_ns
        live_through = failure_ns if catch_through is None else catch_through
        next_mark = min((mark for mark in page_navigation_marks(observation) if mark > failure_ns), default=observed)
        checks_through = min(checks_through, next_mark)
        if "preparationFailure" in observation.milestones:
            stop = observation.stop
            # Only the watch can retire a published generation without setting
            # closed. A fence stop would suppress the later preparation catch.
            watch_stop = (stop is not None and stop.reason in POLL_STOP_REASONS and stop.instant_ns < failure_ns)
            if ((requested is not None and requested < failure_ns) or
                    (watch_stop and (requested is None or requested == failure_ns))):
                request_from = requested if requested is not None else stop.instant_ns
                request_through = requested if requested is not None else failure_ns
                if catch_through is not None:
                    request_through = min(request_through, catch_through)
                return EarlyCloseWindow(request_through, request_from, min(request_through, checks_through),
                                        checks_through, publisher_only=True)
    elif observation.closing_policy_floor_ns is not None:
        # The snapshot bounds the callback. The request marker can follow
        # that boundary on the same actor turn, with no intervening live poll.
        request_from = observation.closing_policy_floor_ns
        live_through = observation.closing_policy_through_ns
    elif (timeout_ns := observation.preparation_timeout_ns) is not None:
        request_from = timeout_ns
        stop = observation.stop
        watch_stop = (stop is not None and stop.reason in POLL_STOP_REASONS
                      and stop.instant_ns < (requested if requested is not None else timeout_ns))
        if (requested is not None and requested < timeout_ns) or watch_stop:
            # A watch can retire before the timeout handler runs even when
            # the handler will backdate its milestone to an earlier deadline.
            watch_from = requested if requested is not None else stop.instant_ns
            watch_through = min(checks_through, requested) if requested is not None else checks_through
            return EarlyCloseWindow(watch_through, watch_from, watch_through, checks_through, publisher_only=True)
    if requested is None:
        return EarlyCloseWindow(live_through, request_from, checks_through, checks_through)
    return EarlyCloseWindow(live_through, max(request_from, requested), min(checks_through, requested), checks_through)


def validate_page_renewals(renewals: list[PermitSample], observation: PageObservation, entry_charge: int,
                           page: str, *, admitted_ns: int | None = None, retirement: dict | None = None,
                           retirement_stop: StopWitness | None = None,
                           result_written_ns: int | None = None,
                           waiting_renewals: Sequence[PermitSample] = (), stop_before_result: bool = False) -> bool:
    """Check poll reachability and whether every assignment ends with a stop in the final close.

    A capped result already sampled the budget, so a poll stop must precede that read.
    """
    marks = page_actor_marks(observation, retirement)
    prep = observation.preparation_started_ns
    first_poll = retirement["retirementFirstPolledAtNs"] if retirement is not None else None
    exit_poll = retirement["retirementExitPolledAtNs"] if retirement is not None else None
    requested = retirement["retirementRequestedAtNs"] if retirement is not None else None
    close_through = first_poll if result_written_ns is None else result_written_ns
    first_sample_ns = first_poll if first_poll is not None else result_written_ns
    failure_ns = observation.synchronous_failure_ns
    observed = observation.observed_ns
    first_poll_slept = first_poll is not None and first_poll < exit_poll
    # The final guards, snapshot, close, result append and first sample share
    # one actor turn. Only a sampler that sleeps can admit another callback,
    # including one tied to that sample's clock.
    callbacks = retirement_callback_marks(observation, retirement) if retirement is not None else set()
    earlier_callbacks = {at for at in callbacks if not first_poll_slept or at < first_poll}
    if any(at > observed for at in earlier_callbacks):
        raise ValueError("Native retirement callback precedes the first possible yield")
    # Reported live events and callbacks proven to precede the final turn
    # bound the guard even when their clock ties the observation.
    final_start = max(page_navigation_marks(observation) | {mark for mark in marks if mark < observed} | earlier_callbacks)
    timeout_ns = observation.preparation_timeout_ns
    if timeout_ns is not None:
        # The deadline bounds the final guard, but is not a turn that can
        # interrupt the publication of a permit.
        final_start = max(final_start, timeout_ns, requested if requested is not None else timeout_ns)
    original = (retirement.get("originalNavigationAfterClose") or {}) if retirement is not None else {}
    early_redirect = (not first_poll_slept and (original.get("serverRedirectCount") or 0) > 0
                      and not original.get("timelineNs"))
    if early_redirect and requested > observed:
        raise ValueError("Original redirect requires a reachable callback turn")
    early_close = early_close_window(observation, requested, retirement,
                                     callback_before_final=bool(earlier_callbacks) or early_redirect)
    if early_redirect:
        # The callback must follow the whole early close and fit the native
        # snapshot. A different actor turn can still share its clock.
        callback_through = min(exit_poll, requested + RETIREMENT_OBSERVATION_NS)
        early_close = replace(early_close, checks_through_ns=min(early_close.checks_through_ns, callback_through))
    close_from = observed if requested is None else requested
    final_close_checks = (observation.load_attempt_ns is not None and observation.stop is None
                          and early_close is None)
    outside = f"Native challenge renewal is outside the {page} interval"
    catch_through = observation.preparation_catch_through_ns
    if catch_through is not None:
        # The catch checks the deadline and records failure on one turn.
        # Only the independent actor stamps proven earlier bound that check.
        stop = observation.stop
        actor_marks = marks | {stop.instant_ns} if stop is not None and stop.reason in POLL_STOP_REASONS else marks
        if prep > failure_ns or any(catch_through < stamp < failure_ns for stamp in actor_marks):
            raise ValueError(outside)
    latest_close = requested if requested is not None else result_written_ns
    if (requested is not None and failure_ns is not None and observation.stop is not None
            and observation.stop.reason in POLL_STOP_REASONS
            and failure_ns < observation.stop.instant_ns < requested):
        raise ValueError(f"Native poll stop is inside the synchronous {page} close")
    permits = []
    close_eligible = []
    live_min = wait_min = 0
    live_max = wait_max = len(renewals) + len(waiting_renewals)
    for index, permit in enumerate([*renewals, *waiting_renewals]):
        issued, written = permit.issued_ns, permit.row_ns
        if index == 0 and admitted_ns is not None and written <= admitted_ns and issued < observation.started_ns:
            if permit.charged != entry_charge or permit.pending != 0:
                raise ValueError("Native health entry renewal disagrees with byte counters")
            continue
        if issued < observation.started_ns or any(issued < stamp < written for stamp in marks):
            raise ValueError(outside)
        # A publication that began before the failure must finish before the
        # catch, even when its row ties the failure stamp.
        if (catch_through is not None and written > catch_through
                and append_precedes_mark(issued, written, failure_ns)):
            raise ValueError(outside)
        # These live failures call close() on the same actor turn. Close's
        # binding checks begin after its request marker.
        if (requested is not None and failure_ns is not None and failure_ns < requested
                and issued < requested and failure_ns < written):
            raise ValueError(outside)
        if prep is None or issued < prep:
            validate_worker_free(permit.charged, permit.pending, entry_charge)
        after_result = index >= len(renewals)
        can_live = not after_result and written <= observed
        can_close = (not after_result and final_close_checks and not observation.before_dispatch(permit)
                     and close_from <= issued <= written <= close_through)
        can_wait = ((after_result or admitted_ns is not None) and first_poll_slept
                    and first_poll <= issued <= written <= exit_poll)
        if after_result and retirement is None:
            can_wait = prep is not None and result_written_ns is not None and result_written_ns <= issued
        if not (can_live or can_close or can_wait):
            raise ValueError(outside)
        position = len(permits)
        if not can_live:
            live_max = min(live_max, position)
        if not can_close and not can_wait:
            live_min = position + 1
        if not can_live and not can_close:
            wait_max = min(wait_max, position)
        if not can_wait:
            wait_min = position + 1
        elif permits and not fence_slept(permits[-1], permit):
            wait_min = max(wait_min, position)
        permits.append(permit)
        close_eligible.append(can_close)
    # The slices are consecutive in append order. A shared clock can put a
    # permit on either side of an unrecorded boundary, even on both boundaries
    # of a health probe. A target's result append separates close from waiting.
    poll_stop = retirement_stop if retirement_stop is not None and retirement_stop.reason in POLL_STOP_REASONS else None
    can_stop_in_close = (poll_stop is not None and final_close_checks
                         and close_from <= poll_stop.instant_ns <= close_through)
    can_stop_in_wait = (poll_stop is not None and poll_stop.reason != "transport-lost" and first_poll_slept
                        and first_poll <= poll_stop.instant_ns <= exit_poll)
    if poll_stop is not None and not (can_stop_in_close or can_stop_in_wait):
        if poll_stop.reason == "transport-lost":
            raise ValueError("Native transport loss requires a live binding")
        raise ValueError("Native retirement poll stop precedes the first reachable poll")
    terminal_close = False
    for live_end in range(max(live_min, wait_min - 2), min(live_max, wait_max, len(permits)) + 1):
        for wait_start in range(max(live_end, wait_min), min(live_end + 2, wait_max, len(permits)) + 1):
            if not all(close_eligible[live_end:wait_start]):
                continue
            closing = permits[live_end:wait_start]
            waiting = permits[wait_start:]
            if len(closing) == 2 and waiting:
                continue
            # The first sample must precede the deadline to begin a sleep.
            # A fence can wake after the deadline while that sleep is pending.
            request_after_ns = first_sample_ns - RETIREMENT_OBSERVATION_NS if waiting else None
            if (request_after_ns is not None and early_close is None
                    and (latest_close <= request_after_ns or (closing and closing[0].issued_ns <= request_after_ns))):
                continue
            live = permits[:live_end]
            if poll_stop is not None:
                if (len(closing) < 2 and can_stop_in_wait and not stop_before_result
                        and page_polls_possible(live, waiting, observation, marks, requested, early_close, final_start,
                                                wait_stop=poll_stop, request_after_ns=request_after_ns)):
                    return False
                if waiting or not can_stop_in_close:
                    continue
            if retirement is not None and not close_polls_possible(closing, retirement_stop, close_through, marks):
                continue
            if page_polls_possible(live, waiting, observation, marks, requested, early_close, final_start,
                                   request_after_ns=request_after_ns):
                if poll_stop is None and len(closing) < 2:
                    return False
                terminal_close = True
    if terminal_close:
        return True
    if stop_before_result and can_stop_in_wait:
        raise ValueError("Native poll stop disagrees with an earlier byte-cap sample")
    raise ValueError(outside)


def page_polls_possible(permits: list[PermitSample], waiting: Sequence[PermitSample],
                        observation: PageObservation, marks: set[int], requested: int | None,
                        early_close: EarlyCloseWindow | None, final_start: int, *,
                        wait_stop: StopWitness | None = None, request_after_ns: int | None = None) -> bool:
    prep = observation.preparation_started_ns
    load = observation.load_attempt_ns
    stop = observation.stop
    live_stop = stop if stop is not None and stop.reason in POLL_STOP_REASONS else None
    # The fence closes on failure, and the publisher retires in its failing
    # watch turn. Load and final guards also precede close without yielding.
    if live_stop is not None and observation.live_callback_floor_ns > live_stop.instant_ns:
        return False
    observed = observation.observed_ns
    final_binding = load is not None and early_close is None
    final_limit = 0 if observation.bound_abort else 2 if final_binding else 1
    next_call = {id(before): after for before, after in zip(permits, permits[1:])}
    # run() finishes with a binding check (while live) and a direct call.
    # Any renewals from them must be a suffix after the last actor event.
    for final_count in range(min(len(permits), final_limit) + 1):
        end = len(permits) - final_count
        if final_count and (permits[end].issued_ns < final_start or observation.before_dispatch(permits[end])):
            continue
        final_stop = (live_stop is not None and not observation.bound_abort
                      and final_start <= live_stop.instant_ns
                      and (final_binding or live_stop.reason != "transport-lost")
                      and (not final_count or (
                          poll_can_follow_publication(permits[-1], live_stop, marks)
                          and (live_stop.reason in {"run-control-unavailable", "transport-lost"}
                               or (final_binding and final_count == 1)))))
        if live_stop is not None and final_count and not final_stop:
            continue
        close = early_close
        if close is not None:
            # run()'s direct poll follows the early close, including when the
            # poll publishes before the frozen observation cutoff.
            final_at = observed
            if final_count:
                final_at = permits[end].issued_ns
            elif final_stop:
                final_at = live_stop.instant_ns
            request_from = close.request_from_ns
            if request_after_ns is not None:
                request_from = max(request_from, request_after_ns + 1)
            close = replace(close, request_from_ns=request_from,
                            request_through_ns=min(close.request_through_ns, final_at),
                            checks_through_ns=min(close.checks_through_ns, final_at))
            if close.request_from_ns > close.request_through_ns:
                continue
        before_final = permits[:end]
        # open() can poll once before preparation and any dispatch append.
        open_counts = ((0, 1) if before_final and not before_final[0].after_dispatch
                       and (prep is None or before_final[0].row_ns <= prep) else (0,))
        for open_count in open_counts:
            active = before_final[open_count:]
            if prep is not None and active and active[0].issued_ns < prep:
                continue
            for async_permits, load_end in without_load_polls(active, observation, marks, requested):
                poll_stop = None if final_stop or observation.bound_abort else live_stop
                if async_page_polls_possible(async_permits, waiting, observation, marks, next_call, poll_stop,
                                             wait_stop, close=close, load_end=load_end):
                    return True
    return False


def without_load_polls(permits: list[PermitSample], observation: PageObservation, marks: set[int],
                       requested: int | None):
    if observation.bound_abort:
        stop = observation.stop
        through = observation.observed_ns if requested is None else requested
        if stop.instant_ns > through:
            return
        # The page binds, runs navigationAllowed and checks live entry health
        # without yielding. Entry health polls before its full savedNode read.
        # If that read fails, onTransportLoss checks pin, Wi-Fi and run control
        # afresh. A third renewal must still lead to the winning stop.
        for count in range(min(len(permits), 3) + 1):
            end = len(permits) - count
            if count and (permits[-1].row_ns > through or (count >= 2 and any(
                    append_precedes_mark(permits[end].issued_ns, permits[end].row_ns, mark)
                    and mark < permits[-1].row_ns for mark in marks))):
                continue
            if count == 3 and not transport_loss_poll_possible(permits[-1], stop, through, marks):
                continue
            yield permits[:end], end
        return

    yield permits, 0
    load = observation.load_attempt_ns
    if load is None or not permits:
        return
    # The two predicates precede either load outcome. The target's synchronous
    # dispatch append also orders permits with equal timestamps.
    if observation.dispatch_written_ns is None:
        first_split = bisect_left(permits, load, key=lambda permit: permit.issued_ns)
        last_split = bisect_right(permits, load, key=lambda permit: permit.row_ns)
    else:
        first_split = last_split = next((index for index, permit in enumerate(permits) if permit.after_dispatch),
                                        len(permits))
    for split in range(first_split, last_split + 1):
        for count in range(1, min(split, 2) + 1):
            yield permits[:split - count] + permits[split:], split - count


def direct_fence_suffix_start(permits: list[PermitSample], observation: PageObservation) -> int:
    # After close the only async source is the same direct fence timer.
    # Its suffix can be checked once, regardless of where the close fits.
    for index in range(len(permits) - 1, -1, -1):
        if (observation.before_dispatch(permits[index]) or
                (index + 1 < len(permits) and not fence_slept(permits[index], permits[index + 1]))):
            return index + 1
    return 0


def async_page_polls_possible(active: list[PermitSample], waiting: Sequence[PermitSample],
                              observation: PageObservation, marks: set[int], next_call: dict[int, PermitSample],
                              poll_stop: StopWitness | None, wait_stop: StopWitness | None, *,
                              close: EarlyCloseWindow | None, load_end: int) -> bool:
    permits = [*active, *waiting]
    prep = observation.preparation_started_ns
    live_through = observation.observed_ns if close is None else min(close.live_through_ns, close.request_through_ns)
    direct_suffix = len(permits) if close is None else direct_fence_suffix_start(permits, observation)
    can_check_binding = observation.load_attempt_ns is not None
    # Publication has no ledger stamp. The earliest possible first watch
    # is two seconds after preparation starts, even if open() resumes late.
    watch_ready = prep + PUBLISHER_POLL_NS if prep is not None else None
    publisher_close = close is not None and close.publisher_only
    if publisher_close and watch_ready is None:
        return False
    timeout_ns = observation.preparation_timeout_ns
    # After the first request and the deadline, a fence could latch a stop
    # after the timeout handler has closed the page.
    watch_stop = (publisher_close and poll_stop is not None
                  and (timeout_ns is None or poll_stop.instant_ns < max(timeout_ns, close.request_from_ns)))

    def close_can_finish(start: int, fence_at: int, watch_at: int) -> bool:
        # Pick a request anywhere between the preceding live append and the
        # first call in or after close. The clipped window already includes
        # the callback evidence, final guard, explicit request and first sleep.
        request_from = max(close.request_from_ns, permits[start - 1].row_ns) if start else close.request_from_ns
        request_through = close.request_through_ns
        if start < len(permits):
            request_through = min(request_through, permits[start].issued_ns)
        if publisher_close:
            request_from = max(request_from, watch_at)
            if watch_stop:
                # The watch's failing guard precedes shutdown on the same
                # turn. An earlier fence stop would suppress the timeout.
                return (request_from <= request_through and start == len(permits)
                        and watch_at <= poll_stop.instant_ns <= request_through
                        and (start == 0 or permits[start - 1].row_ns <= poll_stop.instant_ns))
        if poll_stop is not None:
            request_through = min(request_through, poll_stop.instant_ns)
        if request_from > request_through:
            return False
        # Explicit close may publish twice only if its binding check causes
        # the winning stop. It may also publish once or leave no permit row.
        limit = min(len(active) - start, 2) if can_check_binding else 0
        for count in range(limit + 1):
            end = start + count
            closing = permits[start:end]
            if closing and (observation.before_dispatch(closing[0]) or closing[-1].row_ns > close.checks_through_ns):
                break
            if count == 2 and (end != len(permits) or id(closing[-1]) in next_call
                               or not close_polls_possible(closing, observation.stop, close.checks_through_ns, marks)):
                continue
            if (poll_stop is not None and can_check_binding and end == len(permits)
                    and poll_stop.instant_ns <= close.checks_through_ns
                    and close_polls_possible(closing, poll_stop, close.checks_through_ns, marks)):
                return True
            if end < direct_suffix or (end < len(permits) and permits[end].issued_ns < fence_at):
                continue
            stop = poll_stop or wait_stop
            if stop is None:
                return True
            if stop.reason == "transport-lost":
                continue
            last = permits[-1] if end < len(permits) else None
            next_fence = fence_at if last is None else last.row_ns + FENCE_POLL_NS
            if (next_fence <= stop.instant_ns or
                    (last is not None and (poll_stop is not None or waiting)
                     and stop.reason == "run-control-unavailable" and poll_can_follow_publication(last, stop, marks))):
                return True
        return False

    # open() checks its new binding and closes on abort in the same actor turn.
    # A fence can only check that binding on another turn after a load attempt.
    binding_floor = observation.dispatch_written_ns or observation.dispatch_ns

    def live_binding(at):
        return binding_floor is not None and binding_floor <= at <= live_through

    loss_stop = observation.stop
    if loss_stop is not None and loss_stop.reason in POLL_STOP_REASONS:
        loss_stop = poll_stop
    # With a known callback the stopping poll can occur in close or later.
    # Without such a trigger, the observed live poll may itself cause close.
    if close is not None and (observation.closed_before_observation or loss_stop is None
                             or loss_stop.instant_ns > close.request_through_ns
                             or any(loss_stop.instant_ns < mark < close.request_from_ns for mark in marks)):
        loss_stop = None
    live_stop = poll_stop if loss_stop is not None else None
    last = active[-1] if active else None
    live_finish = (live_stop is not None and last is not None and not waiting and id(last) not in next_call
                   and poll_can_follow_publication(last, live_stop, marks))
    finish_in_binding = (live_finish and live_binding(live_stop.instant_ns) and not observation.before_dispatch(last))
    finish_in_publication = live_finish and live_stop.reason == "run-control-unavailable"
    same_poll_stop = finish_in_publication or finish_in_binding
    # A failing binding check may call onTransportLoss before the first
    # close marker, including when the publisher watch initiates retirement.
    terminal_loss = (last is not None and not waiting and id(last) not in next_call
                     and live_binding(last.issued_ns) and not observation.before_dispatch(last)
                     and transport_loss_poll_possible(last, loss_stop, live_through, marks))
    plans = {0: {(prep if prep is not None else observation.started_ns, watch_ready or 0)}}
    for index in range(len(permits) + 1):
        ready = sorted(plans.pop(index, ()))
        # An explicit close needs only the earliest fence. A publisher
        # request also needs a ready watch in that same assignment.
        if close is not None and index >= load_end:
            choices = ready if publisher_close else ready[:1]
            if any(close_can_finish(index, fence_at, watch_at) for fence_at, watch_at in choices):
                return True
        if index == len(permits):
            break
        permit = permits[index]
        if close is not None and (index == len(active) or permit.row_ns > live_through):
            return False
        next_permit = permits[index + 1] if index + 1 < len(active) else None
        in_binding = live_binding(permit.issued_ns) and not observation.before_dispatch(permit)
        can_pair = (next_permit is not None and next_call.get(id(permit)) is next_permit
                    and in_binding and next_permit.row_ns <= live_through
                    and not any(permit.issued_ns < mark < next_permit.row_ns for mark in marks))
        pair_can_stop = (same_poll_stop and next_permit is last
                         and poll_can_follow_publication(permit, live_stop, marks))
        pair_can_lose = (terminal_loss and not any(permit.issued_ns < mark < loss_stop.instant_ns for mark in marks))
        can_watch = index < len(active) and watch_ready is not None and permit.row_ns <= live_through
        # The retiring watch can publish once before its guard fails. An
        # intervening actor event would require a separate watch turn.
        retiring_watch = (publisher_close
                          and not any(append_precedes_mark(permit.issued_ns, permit.row_ns, mark)
                                      and mark < close.request_from_ns for mark in marks)
                          and (not watch_stop or (poll_stop.reason == "run-control-unavailable"
                                                  and poll_can_follow_publication(permit, poll_stop, marks))))
        # Earlier readiness on both timers subsumes a later assignment.
        earliest_watch = None
        for fence_at, watch_at in ready:
            if earliest_watch is not None and watch_at >= earliest_watch:
                continue
            earliest_watch = watch_at
            fence_poll = permit.issued_ns >= fence_at
            watch_poll = can_watch and permit.issued_ns >= watch_at
            if (fence_poll or watch_poll) and permit is last and same_poll_stop:
                return True
            if fence_poll:
                plans.setdefault(index + 1, set()).add((permit.row_ns + FENCE_POLL_NS, watch_at))
                if can_pair:
                    if pair_can_stop:
                        return True
                    if pair_can_lose and index + 3 == len(permits) and next_call.get(id(next_permit)) is last:
                        return True
                    plans.setdefault(index + 2, set()).add((next_permit.row_ns + FENCE_POLL_NS, watch_at))
            if watch_poll:
                if retiring_watch and close_can_finish(index + 1, fence_at, watch_at):
                    return True
                if can_pair and pair_can_lose and index + 2 == len(permits):
                    return True
                plans.setdefault(index + 1, set()).add((fence_at, permit.row_ns + PUBLISHER_POLL_NS))
        if not plans:
            return False
    if live_stop is not None:
        at = live_stop.instant_ns
        return ((live_stop.reason != "transport-lost" or live_binding(at))
                and any(fence_at <= at or (watch_ready is not None and watch_at <= at <= live_through)
                        for fence_at, watch_at in ready))
    if close is not None:
        return False
    if wait_stop is None or any(fence_at <= wait_stop.instant_ns for fence_at, _ in ready):
        return True
    if waiting and wait_stop.reason == "run-control-unavailable":
        # Publication can fail in the same fence poll after recording its permit.
        return poll_can_follow_publication(waiting[-1], wait_stop, marks)
    return False


def transport_loss_poll_possible(permit: PermitSample, stop: StopWitness | None, through_ns: int,
                                  marks: set[int]) -> bool:
    return (stop is not None and permit.issued_ns <= stop.instant_ns <= through_ns and permit.row_ns <= through_ns
            and not any(permit.issued_ns < mark < stop.instant_ns for mark in marks)
            and (stop.reason not in POLL_STOP_REASONS
                 or (stop.reason in {"transport-lost", "run-control-unavailable"}
                     and poll_can_follow_publication(permit, stop, marks))))


def poll_can_follow_publication(permit: PermitSample, stop: StopWitness, marks: set[int]) -> bool:
    return (permit.row_ns <= stop.instant_ns
            and not any(append_precedes_mark(permit.issued_ns, permit.row_ns, mark)
                        and mark < stop.instant_ns for mark in marks))


def close_polls_possible(close_permits: list[PermitSample], stop: StopWitness | None,
                         close_through: int, marks: set[int]) -> bool:
    # close() may renew in isCurrentEntryHealthy without calling onTransportLoss.
    # A second renewal can only be in onTransportLoss, which stops the run.
    if len(close_permits) == 2:
        return transport_loss_poll_possible(close_permits[-1], stop, close_through, marks)
    if close_permits and stop is not None and stop.reason in POLL_STOP_REASONS:
        # A failed savedNode read can cause a fresh guard inside close().
        return poll_can_follow_publication(close_permits[-1], stop, marks)
    return True


def validate_load_permits(observation: PageObservation, samples: list[ChargeSample], limit: int, stopped_at: int):
    load_at = observation.load_attempt_ns
    if load_at is None:
        return
    before_dispatch = False
    for index in range(len(samples) - 1, -1, -1):
        sample = samples[index]
        if sample.event == "dispatch":
            # The dispatch append is synchronous with the accepted load.
            before_dispatch = True
        elif sample.event == "permit" and (before_dispatch or sample.precedes(load_at)):
            # permitsTraffic checks the budget again after publishing the new challenge.
            if sample.charged == limit:
                raise ValueError("Native load follows a permit that sampled the byte cap")
            if index >= stopped_at:
                raise ValueError("Native load follows a permit published at or after the stop")


def charge_before(stop_ns: int, observation: PageObservation, retirement: dict | None,
                  samples: list[ChargeSample], entry_charge: int) -> int:
    # The row clock precedes its counter lock. A following actor event or row
    # can prove order. A subsequent successful renewal also proves no prior stop.
    mark = max((at for at in page_actor_marks(observation, retirement) if at < stop_ns), default=-1)
    if retirement is not None and samples and retirement["retirementExitPolledAtNs"] < stop_ns:
        return samples[-1].charged
    for index in range(len(samples) - 1, -1, -1):
        sample = samples[index]
        following = samples[index + 1] if index + 1 < len(samples) else None
        if (sample.precedes(mark) or (following is not None
                and (following.event == "permit" or following.elapsed_ns < stop_ns))
                or (retirement is not None and sample.event == "result"
                    and retirement["retirementFirstPolledAtNs"] < stop_ns)):
            return sample.charged
    return entry_charge


def validate_meter_stop(stop: StopWitness, charged: int, limit: int, earlier_charge: int, *, may_meter: bool):
    if (not may_meter or (stop.reason == "metering-failure" and charged <= earlier_charge)
            or (stop.reason == "byte-limit" and earlier_charge == limit)):
        raise ValueError("Native ledger claims an unwitnessed meter stop inconsistent with byte counters or worker activity")


def first_post_stop_counter(stop: StopWitness, samples: list[ChargeSample], witness_charge: int,
                            earlier_charge: int | None, *, result_after_stop: bool = False) -> int:
    # The counter lock follows the row clock. A deadline at that clock or
    # a serialized stop read can order the sample even on clock ties.
    first = next((index for index, sample in enumerate(samples) if stop.applies_by(sample.elapsed_ns)
                  or (result_after_stop and sample.event == "result")), len(samples))
    if stop.reason == "metering-failure" and earlier_charge is not None:
        charge = samples[first].charged if first < len(samples) else witness_charge
        if charge > earlier_charge:
            # The first failing settlement charges a positive reservation
            # in the same lock that latches the stop. Charge never falls, so
            # a read already at the same total cannot precede that settlement.
            first = bisect_left(samples, charge, hi=first, key=lambda sample: sample.charged)
    return first


def validate_stopped_counters(samples: list[ChargeSample]):
    for before, after in zip(samples, samples[1:]):
        drained = before.pending - after.pending
        if drained < 0 or after.charged - before.charged > drained:
            raise ValueError("Native byte counters grew beyond reservations outstanding after stop")


def validate_page_metering(stop: StopWitness | None, row: dict, observation: PageObservation,
                           samples: list[ChargeSample], entry_charge: int, limit: int,
                           *, result_after_stop: bool = False):
    prep = observation.preparation_started_ns
    charged, pending = row["chargedBytes"], row["reservedBytes"]
    retirement = row if "retirementFirstPolledAtNs" in row else None
    earlier_charge = (charge_before(stop.instant_ns, observation, retirement, samples, entry_charge)
                      if stop is not None and stop.reason in METER_STOP_REASONS else None)
    stopped_at = (first_post_stop_counter(stop, samples, charged, earlier_charge, result_after_stop=result_after_stop)
                  if stop is not None else len(samples))
    validate_load_permits(observation, samples, limit, stopped_at)
    after_stop = samples[stopped_at:]
    if earlier_charge is not None:
        quiesced_at = row.get("transportQuiescedAtNs") if row.get("transportQuiesced") else None
        may_meter = (prep is not None and prep <= stop.instant_ns
                     and (quiesced_at is None or stop.instant_ns <= quiesced_at))
        # The witnessing append follows its stop read. An earlier result
        # follows a stop proven to occur in its synchronous close. A tie
        # with an independent worker settlement can go either way.
        post_stop_charge = after_stop[0].charged if after_stop else charged
        validate_meter_stop(stop, post_stop_charge, limit, earlier_charge, may_meter=may_meter)
    if after_stop:
        validate_stopped_counters([*after_stop, ChargeSample(row["event"], row["elapsedNs"], charged, pending)])
    if prep is None:
        validate_worker_free(charged, pending, entry_charge)


def validate_checkpoint_stop(row: dict, deadline: TrafficDeadline, earlier: StopWitness | None, earliest_ns: int,
                             *, previous_ns: int, probe_seen: bool, permit_seen: bool) -> StopWitness | None:
    reason, instant = row.get("budgetStopReason"), row.get("budgetStopAtNs")
    if reason is None and instant is None and earlier is None:
        if previous_ns >= deadline.instant_ns:
            raise ValueError("Expired native checkpoint requires the stop witness")
        return None
    if (not isinstance(reason, str) or reason not in NATIVE_STOP_REASONS
            or type(instant) is not int or not 0 <= instant <= row["elapsedNs"]
            or (reason in PAGE_STOP_REASONS and not probe_seen)
            or (not permit_seen and reason not in DEADLINE_STOP_REASONS)):
        raise ValueError("Invalid native checkpoint stop")
    stop = StopWitness(reason, instant)
    if (earlier is not None and stop != earlier) or (earlier is None and
            (instant < earliest_ns or not deadline.matches(stop))):
        raise ValueError("Invalid native checkpoint stop")
    return stop


def bounded_milestones(payload: dict, earliest: int, latest: int) -> dict:
    timeline, shown = payload.get("timelineNs"), payload.get("timelineMs")
    if (not isinstance(timeline, dict) or not isinstance(shown, dict) or timeline.keys() != shown.keys()
            or any(type(value) is not int or not earliest <= value <= latest
                   or type(shown[key]) is not int or shown[key] != relative_milliseconds(value, 0)
                   for key, value in timeline.items())):
        raise ValueError("Native milestones are outside their observation interval")
    return timeline


def validate_stop_witness(payload: dict, after_ns: int, through_ns: int, origin_ns: int,
                          deadline: TrafficDeadline) -> StopWitness | None:
    reason, instant_ns, displayed = (payload.get(key) for key in ("stopReason", "stopAtNs", "stopAtMs"))
    if reason is None and instant_ns is None and displayed is None:
        return None
    if (not isinstance(reason, str) or reason not in NATIVE_STOP_REASONS
            or type(instant_ns) is not int or not after_ns < instant_ns <= through_ns
            or type(displayed) is not int or displayed != relative_milliseconds(instant_ns, origin_ns)
            or not deadline.matches(StopWitness(reason, instant_ns))):
        raise ValueError("Late stop lies outside the native observation interval")
    return StopWitness(reason, instant_ns)


def validate_snapshot_labels(payload: dict, timeline: dict):
    for field, marker in (("documentCommitted", "documentCommit"), ("documentFinished", "documentFinish")):
        if field in payload and payload[field] is not (marker in timeline):
            raise ValueError("Native document flags have no corresponding milestones")
    if "navigationPolicy" in payload:
        policy = payload.get("localPolicyRejection")
        if policy is None:
            policy = ("policy-interruption-unattributed" if payload.get("errorDomain") == "WebKitErrorDomain"
                      and payload.get("errorCode") == 102 else "no-local-rejection-observed")
        if payload["navigationPolicy"] != policy:
            raise ValueError("Navigation policy label disagrees with native evidence")


def validate_snapshot_evidence(payload: dict, timeline: dict, known: dict):
    validate_snapshot_labels(payload, timeline)
    redirects = payload.get("serverRedirectCount", 0)
    if type(redirects) is not int or redirects < 0:
        raise ValueError("Invalid native redirect evidence")
    for field in ("firstVisibleHTTPStatus", "initialHTTPStatus", "lastHTTPStatus"):
        if field in payload and (type(payload[field]) is not int or not 100 <= payload[field] <= 599):
            raise ValueError("Invalid native HTTP response evidence")
    first, initial, last = (payload.get(field) for field in ("firstVisibleHTTPStatus", "initialHTTPStatus", "lastHTTPStatus"))
    flag = payload.get("initialResponseObserved", False)
    if ((first is None) != (last is None) or (initial is not None and (first is None or initial != first))
            or flag is not (initial is not None)
            or (first is not None and "firstVisibleHTTPResponse" not in known)
            or (first is None and "firstVisibleHTTPResponse" in timeline)):
        raise ValueError("Frozen HTTP status and response milestone disagree")
    policy = payload.get("localPolicyRejection")
    failure = payload.get("errorDomain")
    code = payload.get("errorCode")
    failures = {"navigationFailure", "preparationFailure"}
    if ((policy is not None and (not isinstance(policy, str) or policy not in LOCAL_POLICY_REASONS
                                or "policyRejection" not in known))
            or (policy is None and "policyRejection" in timeline)
            or (failure is None and (code is not None or failures & timeline.keys()))
            or (failure is not None and (not isinstance(failure, str) or not failure or type(code) is not int
                                        or not failures & known.keys()))):
        raise ValueError("Invalid frozen native disposition")
    if (payload.get("localLoadDisposition") != ("load-not-accepted" if "loadNotAccepted" in timeline else None)
            or payload.get("localPreparationDisposition") != ("preparation-timeout" if "preparationTimedOut" in timeline else None)):
        raise ValueError("Invalid local preparation or load disposition")


def validate_navigation_observation(row: dict, admitted_ns: int, deadline: TrafficDeadline, window_ms: int,
                                    *, reserved_ns: int | None = None,
                                    dispatch_written_ns: int | None = None) -> PageObservation:
    issued_ns = row.get("navigationIssuedAtNs")
    dispatched = issued_ns is not None
    outcome, finished, committed = (row.get(field) for field in ("outcome", "documentFinished", "documentCommitted"))
    if (row.get("navigationIssued") is not dispatched or not isinstance(outcome, str)
            or outcome not in {"finished", "failed", "timeout", "stopped", "policy-blocked"}
            or type(finished) is not bool or type(committed) is not bool
            or (finished and not committed) or (committed and not dispatched)
            or (not dispatched and outcome not in {"failed", "stopped"})):
        raise ValueError("Invalid native navigation observation")

    started_ns, cutoff_ns, observed_ns = (row.get(field) for field in
        ("pageStartedAtNs", "observationCutoffAtNs", "observedThroughAtNs"))
    earliest_page_ns = admitted_ns if reserved_ns is None else reserved_ns
    if (any(type(stamp) is not int for stamp in (started_ns, cutoff_ns, observed_ns))
            or not earliest_page_ns <= started_ns <= observed_ns <= row["elapsedNs"]
            or not admitted_ns <= cutoff_ns <= min(observed_ns, deadline.instant_ns)
            or (dispatch_written_ns is not None and observed_ns < dispatch_written_ns)
            or (cutoff_ns < started_ns and outcome != "stopped")):
        raise ValueError("Native observation clocks exceed the admission, grant or recording interval")
    cutoff = cutoff_ns - started_ns
    observed = observed_ns - started_ns
    if type(row.get("observationCutoffMs")) is not int or row["observationCutoffMs"] != relative_milliseconds(cutoff, 0):
        raise ValueError("Native observation clocks disagree")

    prep_started_ns, preparation_ns = row.get("preparationStartedAtNs"), row.get("preparationDeadlineAtNs")
    if ((prep_started_ns is None) != (preparation_ns is None) or (preparation_ns is not None
            and (type(prep_started_ns) is not int or type(preparation_ns) is not int
                 or not started_ns <= prep_started_ns <= observed_ns or preparation_ns != prep_started_ns + PREPARATION_NS))):
        raise ValueError("Invalid native preparation deadline")
    deadline_ns = preparation_ns
    if dispatched:
        if type(issued_ns) is not int or not started_ns <= issued_ns <= observed_ns:
            raise ValueError("Invalid native navigation issuance")
        deadline_ns = issued_ns + window_ms * NANOS_PER_MILLISECOND
    if deadline_ns is not None and cutoff_ns > deadline_ns:
        raise ValueError("Frozen observation extends beyond the native navigation or preparation window")
    possible_end_ns = min(observed_ns, deadline_ns) if deadline_ns is not None else observed_ns

    timeline = bounded_milestones(row, 0, cutoff)
    later = row.get("observedAfterCutoff", {})
    if later and observed_ns == cutoff_ns:
        raise ValueError("Native late observations require a nonempty observation interval")
    late_timeline = bounded_milestones(later, max(0, cutoff + 1), observed) if (
        "timelineMs" in later or "timelineNs" in later) else {}
    if timeline.keys() & late_timeline.keys():
        raise ValueError("Native milestones cannot appear in both observation intervals")
    late_stop = validate_stop_witness(later, cutoff_ns, observed_ns, started_ns, deadline)
    load = timeline.get("loadIssued")
    late_load = late_timeline.get("loadIssued")
    if not dispatched:
        if load is not None or late_load is not None:
            raise ValueError("Unexpected native dispatch milestone")
    else:
        expected = issued_ns - started_ns
        if issued_ns <= cutoff_ns:
            if load != expected or late_load is not None:
                raise ValueError("Missing or out-of-window native dispatch milestone")
        elif outcome != "stopped" or load is not None or late_load != expected:
            raise ValueError("Missing or out-of-window late dispatch milestone")
    milestones = timeline | late_timeline
    if milestones.keys() - PAGE_MILESTONES:
        raise ValueError("Unknown native page milestone")
    callbacks = WEBKIT_CALLBACKS & milestones.keys()
    callback_start = (dispatch_written_ns or issued_ns or started_ns) - started_ns
    if ((callbacks or row.get("serverRedirectCount") or later.get("serverRedirectCount")) and issued_ns is None
            or any(milestones[key] < callback_start for key in callbacks)
            or (row.get("serverRedirectCount") and cutoff < callback_start)):
        raise ValueError("WebKit callbacks precede the accepted dispatch write")
    commit, finish, response = (milestones.get(key) for key in ("documentCommit", "documentFinish", "firstVisibleHTTPResponse"))
    if finish is not None and (commit is None or commit > finish):
        raise ValueError("Native document milestones are out of order")
    if response is not None and commit is not None and response > commit:
        raise ValueError("Frozen HTTP status and response milestone disagree")

    validate_snapshot_evidence(row, timeline, timeline)
    validate_snapshot_evidence(later, late_timeline, milestones)
    live_callback_floor = max((started_ns + milestones[key] for key in callbacks), default=started_ns)
    # A repeat response or rejection, or a redirect, may only have a phase.
    if dispatched and any(later.get(field) for field in (
            "firstVisibleHTTPStatus", "localPolicyRejection", "serverRedirectCount", "errorDomain")):
        live_callback_floor = max(live_callback_floor, cutoff_ns + 1)
    if (later.get("initialHTTPStatus") is not None
            and (row.get("firstVisibleHTTPStatus") is not None or row.get("serverRedirectCount", 0) != 0
                 or "firstVisibleHTTPResponse" not in late_timeline)):
        raise ValueError("Late HTTP evidence misidentifies the initial response")

    protocol = row.get("actualProtocol")
    if protocol not in ("unbound", CAMPAIGN_TRANSPORT):
        raise ValueError("Invalid page binding evidence")
    bound = protocol != "unbound"
    port = row.get("port")
    if ((bound and (type(port) is not int or not 0 < port <= 65535 or port == 1080))
            or (not bound and port is not None)):
        raise ValueError("Invalid page binding port")
    if cutoff_ns < started_ns and (bound or prep_started_ns is not None or milestones):
        raise ValueError("A stop before page creation cannot carry page activity")
    rejected_at = milestones.get("loadNotAccepted")
    load_rejected = rejected_at is not None
    if not bound and (dispatched or load_rejected):
        raise ValueError("Native dispatch or load rejection requires a bound page")
    if bound and prep_started_ns is None:
        raise ValueError("A bound page requires a native preparation deadline")
    load_attempted_at = issued_ns if dispatched else started_ns + rejected_at if load_rejected else None
    if load_attempted_at is not None and not prep_started_ns <= load_attempted_at:
        raise ValueError("Native preparation must precede the load attempt")
    prep_timeout = milestones.get("preparationTimedOut")
    prep_failure = "preparationFailure" in milestones
    if ((bound and (prep_failure or prep_timeout is not None))
            or (prep_failure and prep_timeout is not None) or (dispatched and load_rejected)):
        raise ValueError("Native failure milestone disagrees with the navigation phase")
    if prep_timeout is not None and (preparation_ns is None
                                    or prep_timeout != preparation_ns - started_ns
                                    or ("preparationTimedOut" in timeline) != (preparation_ns <= cutoff_ns)
                                    or preparation_ns > observed_ns):
        raise ValueError("Native preparation timeout has no matching deadline")
    stop = row.get("stopReason")
    policy = row.get("localPolicyRejection")
    failure = row.get("errorDomain")
    code = row.get("errorCode")
    frozen_stop = StopWitness(stop, cutoff_ns) if stop is not None else None
    if ((frozen_stop is not None and (not isinstance(stop, str) or stop not in NATIVE_STOP_REASONS
                                    or not deadline.matches(frozen_stop) or late_stop is not None))
            or (frozen_stop is None and cutoff_ns != possible_end_ns)
            or (frozen_stop is None and late_stop is None and observed_ns >= deadline.instant_ns)):
        raise ValueError("Frozen observation does not match the native cutoff")
    if stop is not None:
        expected = "stopped"
    elif policy is not None:
        expected = "policy-blocked"
    elif finished:
        expected = "finished"
    elif failure is not None:
        expected = "timeout" if dispatched and failure == "NSURLErrorDomain" and code == -1001 else "failed"
    elif dispatched and cutoff_ns == deadline_ns:
        expected = "timeout"
    else:
        expected = "failed"
    if expected != outcome:
        raise ValueError("Outcome disagrees with the frozen stop, policy or error observation")
    witness = frozen_stop or late_stop
    # Once open() assigns initialBinding, it attempts view.load unless a
    # guard fails. Both navigationAllowed and onTransportLoss then leave a
    # winning budget, pin, Wi-Fi, run-control or transport-loss stop.
    if bound and load_attempted_at is None and witness is None:
        raise ValueError("A native bound page without a load attempt requires a stop")
    if (witness is not None and witness.reason in DEADLINE_STOP_REASONS and bound
            and witness.instant_ns <= prep_started_ns):
        raise ValueError("Native binding follows expiry before preparation")
    if witness is not None and witness.reason in POLL_STOP_REASONS:
        if witness.instant_ns < started_ns:
            raise ValueError("Native page poll stop precedes page creation")
        if prep_started_ns is not None and witness.instant_ns < prep_started_ns:
            raise ValueError("Native preparation follows a synchronous page poll stop")
        if load_attempted_at is not None and witness.instant_ns < (dispatch_written_ns or load_attempted_at):
            raise ValueError("Native dispatch follows a synchronous page poll stop")
        if witness.reason == "transport-lost" and (not bound or witness.instant_ns < prep_started_ns):
            raise ValueError("Native transport loss requires a live binding")
    # The milestone records the first rejection. Only a terminal disposition
    # proves closure, and its snapshot bounds when the disposition was seen.
    terminal_policy = "additional-top-level-navigation"
    closing_policy_floor = None
    policy_through = None
    if terminal_policy in (policy, later.get("localPolicyRejection")):
        policy_through = cutoff_ns if policy == terminal_policy else observed_ns
        if live_callback_floor > policy_through:
            raise ValueError("Live WebKit callbacks cannot follow terminal navigation policy")
        # Both callbacks close on the same actor turn. Original-navigation
        # failures during retirement are recorded on a separate timeline.
        if "navigationFailure" in milestones:
            raise ValueError("Terminal navigation policy conflicts with live navigation failure")
        # A later rejection can be the first terminal one. A live callback
        # must also precede the synchronous retirement request.
        closing_policy_floor = max(started_ns + milestones["policyRejection"], live_callback_floor)
    return PageObservation(started_ns, observed_ns, bound, prep_started_ns, issued_ns, dispatch_written_ns,
                           milestones, live_callback_floor, closing_policy_floor, policy_through, witness)


def retirement_instant(row: dict, prefix: str, origin_ns: int, earliest_ns: int, latest_ns: int) -> int | None:
    instant, shown = row.get(prefix + "AtNs"), row.get(prefix + "AtMs")
    if instant is None and shown is None:
        return None
    if (type(instant) is not int or not earliest_ns <= instant <= latest_ns
            or type(shown) is not int or shown != relative_milliseconds(instant, origin_ns)):
        raise ValueError("Native retirement witness is outside its observation window")
    return instant


def validate_retirement_witnesses(row: dict, observation: PageObservation, deadline: TrafficDeadline,
                                  *, result_written_ns: int | None = None) -> StopWitness | None:
    requested_ns = row.get("retirementRequestedAtNs")
    first_poll_ns = row.get("retirementFirstPolledAtNs")
    poll_ns = row.get("retirementExitPolledAtNs")
    observed_ns = row.get("retirementObservedThroughAtNs")
    state, quiesced = row.get("retirementState"), row.get("transportQuiesced")
    if (not isinstance(state, str) or state not in {"confirmed", "unconfirmed", "unbound"}
            or type(quiesced) is not bool or (state != "unbound") != observation.bound):
        raise ValueError("Native retirement state disagrees with navigation or transport evidence")
    # A target's load and dispatch append share one actor turn. Health
    # snapshots only carry the accepted navigation clock.
    earliest_close_ns = observation.dispatch_written_ns or observation.dispatch_ns or observation.started_ns
    poll_start_ns = max(observation.observed_ns, result_written_ns or 0)
    if (any(type(stamp) is not int for stamp in (requested_ns, first_poll_ns, poll_ns, observed_ns))
            or not earliest_close_ns <= requested_ns <= first_poll_ns <= poll_ns <= observed_ns <= row["elapsedNs"]
            or first_poll_ns < poll_start_ns
            or (result_written_ns is not None and requested_ns > result_written_ns)):
        raise ValueError("Missing native retirement start")
    if observation.closing_policy_floor_ns is not None and requested_ns < observation.closing_policy_floor_ns:
        raise ValueError("Native retirement request precedes terminal navigation policy evidence")
    requested = relative_milliseconds(requested_ns, observation.started_ns)
    retirement_deadline_ns = requested_ns + RETIREMENT_OBSERVATION_NS
    end_ns = min(poll_ns, retirement_deadline_ns)
    if (type(row.get("retirementRequestedAtMs")) is not int or row["retirementRequestedAtMs"] != requested
            or type(row.get("retirementObservedMs")) is not int
            or row["retirementObservedMs"] != relative_milliseconds(observed_ns, requested_ns)):
        raise ValueError("Native retirement clocks disagree")
    commit = retirement_instant(row, "retirementCommit", observation.started_ns, requested_ns, poll_ns)
    if ((commit is not None and not observation.bound)
            or (state == "confirmed") != (commit is not None and commit <= end_ns)):
        raise ValueError("Native retirement state disagrees with its commit witness")
    if commit is not None and any(observation.started_ns + observation.milestones[name] > commit
                                  for name in WEBKIT_CALLBACKS & observation.milestones.keys()):
        raise ValueError("Live WebKit callbacks cannot follow the replacement commit")
    sample = retirement_instant(row, "transportQuiesced", observation.started_ns, first_poll_ns, end_ns)
    if quiesced and sample is None:
        raise ValueError("Native retirement witness is outside its observation window")
    if result_written_ns is not None and commit is not None and observation.observed_ns < commit < result_written_ns:
        raise ValueError("Replacement commit falls inside the synchronous result write")
    if observation.preparation_started_ns is None:
        if first_poll_ns != poll_ns:
            raise ValueError("Unprepared native page must exit retirement at its first poll")
        if quiesced != (first_poll_ns <= retirement_deadline_ns):
            raise ValueError("Unprepared native page quiescence disagrees with its first poll")
    # Known samples can be consecutive, with arbitrarily late wakes.
    if 0 < poll_ns - first_poll_ns < FENCE_POLL_NS:
        raise ValueError("Native retirement exit poll precedes the first completed sleep")
    if first_poll_ns >= retirement_deadline_ns and first_poll_ns != poll_ns:
        raise ValueError("Native retirement continues after its first expired poll")
    if sample is not None and 0 < sample - first_poll_ns < FENCE_POLL_NS:
        raise ValueError("Native quiescence sample precedes the first completed sleep")
    released_ns = commit if observation.bound else requested_ns
    if poll_ns < retirement_deadline_ns and (released_ns is None or sample is None):
        raise ValueError("Native retirement exited without release and quiescence")
    if sample is not None and sample < poll_ns:
        # A replacement callback tied to an idle sample can run just after
        # that sampler yields. An unbound page is already released at the sample.
        released_before_sample = (released_ns is not None
                                  and (released_ns < sample or (not observation.bound and released_ns == sample)))
        if poll_ns - sample < FENCE_POLL_NS or sample >= retirement_deadline_ns or released_before_sample:
            raise ValueError("Native retirement exit poll contradicts the quiescence sample")

    original = row.get("originalNavigationAfterClose")
    if original is not None:
        if (not isinstance(original, dict) or observation.dispatch_ns is None
                or original.keys() - ORIGINAL_EVIDENCE_FIELDS or original.get("initialResponseObserved", False) is not False):
            raise ValueError("Invalid original WebKit callbacks during retirement")
        timeline = bounded_milestones(original, requested_ns - observation.started_ns, end_ns - observation.started_ns)
        if timeline.keys() - ORIGINAL_CALLBACKS:
            raise ValueError("Invalid original WebKit callbacks during retirement")
        document_milestones = {"provisionalStart", "documentCommit", "documentFinish"}
        if document_milestones & timeline.keys() & observation.milestones.keys():
            raise ValueError("Original callbacks repeat observed document milestones")
        finish = timeline.get("documentFinish")
        commit_at = timeline.get("documentCommit", observation.milestones.get("documentCommit"))
        if finish is not None and (commit_at is None or finish < commit_at):
            raise ValueError("Original navigation finished without its preceding commit")
        validate_snapshot_evidence(original, timeline, timeline)
    payload = row.get("haltDuringRetirement", {})
    if not isinstance(payload, dict):
        raise ValueError("Invalid stop observed during retirement")
    stop = validate_stop_witness(payload, observation.observed_ns, observed_ns, observation.started_ns, deadline)
    if stop is not None and observation.stop is not None:
        raise ValueError("A native run cannot latch a second stop")
    if stop is not None and stop.reason in POLL_STOP_REASONS and stop.instant_ns > poll_ns:
        raise ValueError("Native retirement poll stop follows the exit poll")
    transport_stop = observation.stop or stop
    if transport_stop is not None and transport_stop.reason == "transport-lost":
        after_close = original["timelineNs"].values() if original is not None else ()
        if ((commit is not None and commit < transport_stop.instant_ns)
                or any(observation.started_ns + at < transport_stop.instant_ns for at in after_close)):
            raise ValueError("Native transport loss requires a live binding")
    if observation.stop is None and stop is None and observed_ns >= deadline.instant_ns:
        raise ValueError("Missing stop witness during retirement")
    return stop


class CampaignObserver:
    """Renew an active grant or independently reconcile the stopped process."""

    def __init__(self, targets: tuple[str, ...], identity: dict, limits: CampaignLimits,
                 state_file: Path, *, recover=False):
        validate_grant(targets, identity, limits)
        self.targets = targets
        self.identity = dict(identity)
        self.limits = limits
        self.state_file = state_file
        self._prefix = b""
        self._witness = b""
        self._disputed = False
        self._pending = False
        self._renewals_closed = recover
        self._last_challenge = None
        if recover:
            with state_file.open("rb") as stream:
                state = json.loads(stream.read(2 * 16 * 1024 * 1024 + 1), object_pairs_hook=unique_object)
            if (state["identity"] != self.identity or state["limits"] != limits.fields()
                    or type(state["disputed"]) is not bool or type(state["pending"]) is not bool):
                raise ValueError("Stored observation is for a different grant")
            self._witness = base64.b64decode(state["witness"], validate=True)
            verified = state["verifiedLength"]
            if type(verified) is not int or not 0 <= verified <= len(self._witness) <= MAX_SNAPSHOT_BYTES:
                raise ValueError("Invalid archived native copy witness")
            self._prefix = self._witness[:verified]
            self._disputed = state["disputed"]
            self._pending = state["pending"]
            if self._prefix:
                self._validate(self._prefix)
        else:
            self._persist(update=False)

    @property
    def observed_prefix(self) -> bytes:
        return self._prefix

    def _validate(self, raw: bytes) -> CampaignReceipt:
        return read_campaign_receipt(raw, self.targets, self.identity, self.limits)

    def _same_grant(self, raw: bytes) -> bool | None:
        header, separator, _ = raw.partition(b"\n")
        if not separator:
            return None
        try:
            row = json.loads(header, object_pairs_hook=unique_object)
        except (ValueError, RecursionError):
            return None
        if not isinstance(row, dict) or not IDENTITY_FIELDS <= row.keys():
            return None
        header_identity = {field: row[field] for field in IDENTITY_FIELDS}
        if header_identity == self.identity:
            return True
        # Only dismiss a complete, self-consistent foreign ledger. A foreign-looking
        # header must not hide this run's reservation or an unreadable suffix.
        if not raw.endswith(b"\n"):
            return None
        for line in raw.splitlines()[1:]:
            try:
                row = json.loads(line, object_pairs_hook=unique_object)
            except (ValueError, RecursionError):
                return None
            if not isinstance(row, dict) or not IDENTITY_FIELDS <= row.keys():
                return None
            identity = {field: row[field] for field in IDENTITY_FIELDS}
            if identity == self.identity:
                return True
            if identity != header_identity:
                return None
        return False

    def _persist(self, *, update=True):
        state = json.dumps({
            "identity": self.identity, "limits": self.limits.fields(),
            "witness": base64.b64encode(self._witness).decode("ascii"), "verifiedLength": len(self._prefix),
            "disputed": self._disputed, "pending": self._pending,
        }).encode()
        publish_snapshot(self.state_file, state, update=update)

    def _save(self, prefix: bytes, witness: bytes, *, pending: bool, disputed=False):
        self._prefix = prefix
        self._witness = witness
        self._pending = pending
        self._disputed |= disputed
        try:
            self._persist()
        except BaseException:
            self._pending = True
            raise

    def _read(self, copy, destination, report, deadline, retry_delay):
        try:
            self._prefix, receipt = copy_snapshot(copy, destination, self._prefix, self._witness, report, self._validate,
                                                  self._save, self._same_grant,
                                                  deadline=deadline, retry_delay=retry_delay)
        except LedgerObservationUnavailable as failure:
            self._prefix = failure.observed_prefix
            raise
        return receipt

    def observe_and_renew(self, copy, destination, report, read_challenge, send_command, *, deadline, retry_delay=0):
        """Each device callback takes the same absolute monotonic deadline."""
        if self._renewals_closed:
            raise RuntimeError("Renewal is closed for this cohort")
        try:
            receipt = self._read(copy, destination, report, deadline, retry_delay)
            if receipt.checkpoint is not None or receipt.halted:
                self._renewals_closed = True
                return receipt
            expected = receipt.challenge_sha256
            if expected is None or expected == self._last_challenge:
                return receipt
            require_time(deadline, self._prefix)
            challenge = read_challenge(deadline)
            require_time(deadline, self._prefix)
            if not RUN_CHALLENGE.fullmatch(challenge):
                raise RuntimeError("Invalid native run challenge")
            if hashlib.sha256(challenge).hexdigest() == expected:
                send_command(challenge, deadline)
                self._last_challenge = expected
                require_time(deadline, self._prefix)
            return receipt
        except BaseException:
            self._renewals_closed = True
            raise

    def reconcile_stopped(self, copy, first, second, report, is_stopped, *, deadline, retry_delay=0):
        """A stopped process and two matching complete reads bind any next admission."""
        self._renewals_closed = True
        if self._disputed or self._pending:
            raise LedgerObservationUnavailable("Unresolved native copy evidence blocks recovery", self._prefix)
        require_time(deadline, self._prefix)
        if not is_stopped(deadline):
            raise RuntimeError("Native campaign process is still active")
        self._read(copy, first, report, deadline, retry_delay)
        first_bytes = self._prefix
        receipt = self._read(copy, second, report, deadline, retry_delay)
        if first_bytes != self._prefix or not is_stopped(deadline):
            raise RuntimeError("Native ledger has not stopped appending")
        require_time(deadline, self._prefix)
        return ReconciledCampaign(receipt)

"""Short-lived, session-bound credentials for one operator-selected TLS CONNECT node.

The node and control plane share SQLite in this controlled first release. Remote
panel reads occur outside write transactions; authorization is checked again at
the transaction's linearization point. No raw bearer token or password is stored.
"""

from contextlib import closing
from dataclasses import dataclass, field
import hashlib
import hmac
import ipaddress
from pathlib import Path
import re
import secrets
import sqlite3
import uuid

from . import store

Unavailable = store.Unavailable
MAX_TTL_MS = 300_000
MAX_SOURCE_AGE_MS = 15_000
_BINDING = ('id', 'plan_id', 'period_id', 'period_start', 'period_end', 'panel_client')
_LOOKUP = f"""
    SELECT account.*, COALESCE(version.version, 0) AS authority_version
    FROM ({store.CURRENT_ACCOUNT_SQL}) AS account
    LEFT JOIN node_authority_versions AS version ON version.account_id = account.id
"""
_TOKEN = re.compile(r'[A-Za-z0-9_-]{1,256}', re.ASCII)


@dataclass(frozen=True)
class ManagedNode:
    node_id: str
    host: str
    port: int
    ttl_ms: int = 60_000
    admitted_clients: frozenset[str] = field(kw_only=True)

    def __post_init__(self):
        if (not isinstance(self.node_id, str)
                or not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', self.node_id)
                or not isinstance(self.host, str) or not self.host.isascii()
                or type(self.port) is not int or not 1 <= self.port <= 65535
                or type(self.ttl_ms) is not int or not 1 <= self.ttl_ms <= MAX_TTL_MS
                or not isinstance(self.admitted_clients, (set, frozenset))
                or not self.admitted_clients
                or any(not isinstance(client, str) or not client or client == '*'
                       for client in self.admitted_clients)):
            raise ValueError('invalid managed node configuration')
        object.__setattr__(self, 'admitted_clients', frozenset(self.admitted_clients))
        try:
            ipaddress.ip_address(self.host)
        except ValueError:
            if (len(self.host) > 253 or not all(re.fullmatch(
                    r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', label)
                    for label in self.host.split('.'))):
                raise ValueError('invalid managed node host') from None

    @classmethod
    def from_config(cls, config, host, port, ttl_ms=60_000):
        """Use the same nodeId and dedicated upstream mapping as node --config."""
        upstreams = config.get('upstreams') if isinstance(config, dict) else None
        if (not isinstance(upstreams, dict) or not upstreams
                or any(type(value) is not int or not 1 <= value <= 65535
                       for value in upstreams.values())
                or len(set(upstreams.values())) != len(upstreams)):
            raise ValueError('invalid managed node configuration')
        return cls(config.get('nodeId'), host, port, ttl_ms,
                   admitted_clients=frozenset(upstreams))


def _connect(path):
    # mode=rw never creates a replacement authority database on a path typo.
    db = sqlite3.connect(Path(path).absolute().as_uri() + '?mode=rw', uri=True,
                         timeout=5, isolation_level=None)
    db.row_factory = sqlite3.Row
    return db


def migrate(database_path):
    try:
        with closing(_connect(database_path)) as db:
            db.executescript(Path(__file__).with_suffix('.sql').read_text())
    except sqlite3.Error:
        raise Unavailable('credential store unavailable') from None


def _digest(token):
    if not isinstance(token, str) or not _TOKEN.fullmatch(token):
        return None
    return hashlib.sha256(token.encode('ascii')).digest()


def _uuid(value):
    if not isinstance(value, str):
        return False
    try:
        return str(uuid.UUID(value)) == value
    except ValueError:
        return False


def _account(db, digest, now):
    return db.execute(_LOOKUP, (digest, now)).fetchone()


def _same(first, second):
    return first is not None and second is not None and all(
        first[key] == second[key] for key in (*_BINDING, 'session_expiry', 'authority_version'))


def _bound_to(grant, account):
    return all(grant['account_id' if k == 'id' else k] == account[k] for k in _BINDING)


def _usage(account, observed, now, live):
    if account['plan_id'] is None:
        return None
    result = store._response(account, observed, now)
    # Offline snapshots require a measurement watermark. A fresh direct panel
    # read has no measurement timestamp; its validated receipt bounds freshness.
    stamp = observed['received_at'] if live else observed['measured_at']
    if stamp is None or not 0 <= now - stamp <= MAX_SOURCE_AGE_MS:
        raise Unavailable('current usage unavailable')
    return result if result['status'] == 'active' else None


def _observe(db, digest, clock_ms, panel, admitted_clients=None):
    account = _account(db, digest, clock_ms())
    observed = None
    if account is not None and account['plan_id'] is not None:
        if admitted_clients is not None and account['panel_client'] not in admitted_clients:
            raise Unavailable('managed node unavailable')
        if panel is not None:
            observed = panel.read(account['panel_client'], clock_ms)
    return account, observed


def issue(database_path, token, context_id, mode, clock_ms, *, node, panel=None, renew_id=None):
    """Issue a new grant or extend a matching live grant without rotating its secret."""
    if (not _uuid(context_id) or mode not in ('regular', 'private')
            or renew_id is not None and not _uuid(renew_id)):
        raise ValueError('invalid credential scope')
    if not isinstance(node, ManagedNode):
        raise ValueError('invalid managed node configuration')
    digest = _digest(token)
    if digest is None:
        return None
    try:
        with closing(_connect(database_path)) as db:
            initial, observed = _observe(db, digest, clock_ms, panel, node.admitted_clients)
            db.execute('BEGIN IMMEDIATE')
            now = clock_ms()
            current = _account(db, digest, now)
            if current is None:
                return None
            if not _same(initial, current):
                raise Unavailable('authorization changed')
            if current['plan_id'] is not None and current['panel_client'] not in node.admitted_clients:
                raise Unavailable('managed node unavailable')
            if renew_id is not None:
                grant = db.execute('SELECT * FROM node_credentials WHERE credential_id=? '
                                   'AND token_hash=? AND node_id=? AND context_id=? AND mode=? '
                                   'AND revoked=0 AND expires_at>?',
                                   (renew_id, digest, node.node_id, context_id, mode, now)).fetchone()
                if grant is None or not _bound_to(grant, current):
                    return {}
            usage = _usage(current, observed if panel is not None else current, now,
                           panel is not None)
            if usage is None:
                if renew_id is not None:
                    db.execute('UPDATE node_credentials SET revoked=1 WHERE credential_id=?', (renew_id,))
                    db.commit()
                return {}
            expiry = min(now + node.ttl_ms, current['session_expiry'],
                         current['period_end'], usage['expiresAt'])
            if renew_id is not None:
                db.execute('UPDATE node_credentials SET expires_at=? WHERE credential_id=?',
                           (expiry, renew_id))
                db.commit()
                return dict(accountId=current['id'], periodId=current['period_id'],
                            credentialId=renew_id, contextId=context_id, mode=mode, expiresAt=expiry)
            credential_id, password = str(uuid.uuid4()), secrets.token_urlsafe(32)
            db.execute('DELETE FROM node_credentials WHERE expires_at<=?', (now,))
            db.execute('UPDATE node_credentials SET revoked=1 WHERE token_hash=? '
                       'AND node_id=? AND context_id=? AND mode=?',
                       (digest, node.node_id, context_id, mode))
            db.execute('INSERT INTO node_credentials VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,0)',
                       (credential_id, digest, *(current[k] for k in _BINDING),
                        node.node_id, context_id, mode,
                        hashlib.sha256(password.encode('ascii')).digest(), expiry))
            db.commit()
            return dict(accountId=current['id'], periodId=current['period_id'],
                        credentialId=credential_id, contextId=context_id, mode=mode,
                        host=node.host, port=node.port, username=credential_id,
                        password=password, expiresAt=expiry)
    except sqlite3.Error:
        raise Unavailable('credential store unavailable') from None


def revoke(database_path, token, credential_id, clock_ms):
    """Authenticated, non-disclosing idempotent delete; bool indicates session validity."""
    digest = _digest(token)
    if digest is None:
        return False
    try:
        with closing(_connect(database_path)) as db:
            db.execute('BEGIN IMMEDIATE')
            account = _account(db, digest, clock_ms())
            if account is None:
                return False
            db.execute('UPDATE node_credentials SET revoked=1 WHERE credential_id=? '
                       'AND token_hash=? AND account_id=?', (credential_id, digest, account['id']))
            db.commit()
            return True
    except sqlite3.Error:
        raise Unavailable('credential store unavailable') from None


def verify_node(database_path, username, password, clock_ms, *, panel=None, node_id):
    """Return the authorized panel_client, None on denial, or raise Unavailable."""
    if (not _uuid(username) or not isinstance(password, str)
            or not re.fullmatch(r'[A-Za-z0-9_-]{43}', password)):
        return None
    password_hash = hashlib.sha256(password.encode('ascii')).digest()
    try:
        with closing(_connect(database_path)) as db:
            grant = db.execute('SELECT * FROM node_credentials WHERE credential_id=?',
                               (username,)).fetchone()
            if (grant is None or grant['revoked'] or grant['node_id'] != node_id
                    or grant['expires_at'] <= clock_ms()
                    or not hmac.compare_digest(grant['password_hash'], password_hash)):
                return None
            initial, observed = _observe(db, grant['token_hash'], clock_ms, panel)
            db.execute('BEGIN IMMEDIATE')
            now = clock_ms()
            latest = db.execute('SELECT * FROM node_credentials WHERE credential_id=?',
                                (username,)).fetchone()
            current = _account(db, grant['token_hash'], now)
            if (latest is None or latest['expires_at'] <= now
                    or any(latest[k] != grant[k] for k in grant.keys() if k != 'expires_at')
                    or not _same(initial, current)):
                return None
            if not _bound_to(latest, current):
                return None
            usage = _usage(current, observed if panel is not None else current, now,
                           panel is not None)
            if usage is None:
                db.execute('UPDATE node_credentials SET revoked=1 WHERE credential_id=?', (username,))
                db.commit()
                return None
            db.commit()
            return current['panel_client']
    except sqlite3.Error:
        raise Unavailable('credential store unavailable') from None

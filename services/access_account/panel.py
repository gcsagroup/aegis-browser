"""Read a dedicated finite-period client's counters from 3X-UI v3.11.0."""

from contextlib import closing
import http.client
import json
import ssl
from urllib.parse import quote, urlsplit

from .store import Unavailable


class Panel:
    def __init__(self, base_url, api_token):
        url = urlsplit(base_url)
        if (not url.hostname or url.username is not None or url.password is not None
                or url.query or url.fragment or not api_token or not api_token.isascii()
                or not api_token.isprintable() or any(ch.isspace() for ch in api_token)):
            raise ValueError("invalid panel configuration")
        if url.scheme != "https" and not (url.scheme == "http" and url.hostname == "127.0.0.1"):
            raise ValueError("panel requires HTTPS or local 127.0.0.1 HTTP")
        self.host = url.hostname
        self.port = url.port
        self.tls = url.scheme == "https"
        self.prefix = url.path.rstrip("/") + "/panel/api/clients/"
        self.token = api_token

    def _get(self, route, client):
        # http.client does not follow redirects or consult environment proxy settings.
        target = self.prefix + route + "/" + quote(client, safe="")
        headers = {"Authorization": "Bearer " + self.token, "Accept": "application/json"}
        try:
            if self.tls:
                conn = http.client.HTTPSConnection(self.host, self.port, timeout=5,
                                                   context=ssl.create_default_context())
            else:
                conn = http.client.HTTPConnection(self.host, self.port, timeout=5)
            with closing(conn):
                conn.request("GET", target, headers=headers)
                response = conn.getresponse()
                if response.status != 200:
                    raise Unavailable("panel request failed")
                body = response.read(65537)
                if len(body) > 65536:
                    raise Unavailable("panel response too large")
                result = json.loads(body)
        except (OSError, http.client.HTTPException, ValueError, RecursionError) as error:
            raise Unavailable("invalid panel response") from error

        if not isinstance(result, dict) or result.get("success") is not True:
            raise Unavailable("panel read failed")
        obj = result.get("obj")
        if not isinstance(obj, dict):
            raise Unavailable("panel client unavailable")
        return obj

    def read(self, client, now_ms):
        if client in ("", ".", "..") or "/" in client or "\\" in client:
            raise Unavailable("invalid panel client binding")
        usage = self._get("traffic", client)
        received = now_ms()
        # Node snapshots can clear the limit fields in client_traffics. 3X-UI
        # keeps the configured limits and traffic-reset policy in ClientRecord.
        settings = self._get("get", client).get("client")
        if not isinstance(settings, dict) or any(row.get("email") != client for row in (settings, usage)):
            raise Unavailable("wrong panel client")
        quota, expiry = settings.get("totalGB"), settings.get("expiryTime")
        up, down = usage.get("up"), usage.get("down")
        if any(type(v) is not int or not 0 <= v <= 2**63 - 1 for v in (quota, expiry, up, down)):
            raise Unavailable("invalid panel counter or limit")
        if (not quota or not 0 < expiry <= 2**53 - 1 or settings.get("trafficReset") != "never"
                or any(type(settings.get(k)) is not int or settings[k] != 0
                       for k in ("reset", "resetDay", "resetWeekday"))):
            raise Unavailable("a dedicated finite plan with an absolute expiry is required")
        for row in (settings, usage):
            if type(row.get("enable")) is not bool or (not row["enable"] and up + down < quota
                                                       and received < expiry):
                raise Unavailable("panel client disabled")
        return dict(quota_bytes=quota, uploaded_bytes=up, downloaded_bytes=down,
                    expires_at=expiry, received_at=received, measured_at=None)

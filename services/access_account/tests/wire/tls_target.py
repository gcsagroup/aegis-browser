"""Independent TLS 1.3 origin. Count TCP payload at this end before TLS decoding."""
import contextlib
import hashlib
from email.utils import formatdate
import socketserver
import ssl
import threading


class WireTLS:
    """Drive a TLS session over a socket (including an already-TLS CONNECT tunnel)."""

    def __init__(self, sock, context, *, server=False):
        self.sock = sock
        self.incoming = ssl.MemoryBIO()
        self.outgoing = ssl.MemoryBIO()
        self.tls = context.wrap_bio(self.incoming, self.outgoing, server_side=server,
                                    server_hostname=None if server else "localhost")
        self.received = 0
        self.sent = 0

    def flush(self):
        while self.outgoing.pending:
            block = self.outgoing.read()
            self.sock.sendall(block)
            self.sent += len(block)

    def run(self, action):
        while True:
            try:
                value = action()
            except ssl.SSLWantReadError:
                self.flush()
                block = self.sock.recv(65536)
                if not block:
                    raise EOFError("Peer closed the connection before TLS shutdown")
                self.received += len(block)
                self.incoming.write(block)
            else:
                self.flush()
                return value

    def read(self, count):
        data = bytearray()
        while len(data) < count:
            block = self.run(lambda: self.tls.read(count - len(data)))
            if not block:
                raise EOFError("Early TLS close")
            data.extend(block)
        return bytes(data)

    def write(self, data):
        while data:
            n = self.run(lambda: self.tls.write(data[:16384]))
            data = data[n:]


def payload(identity, round_number, size, direction):
    return hashlib.shake_256(f"{identity}/{round_number}/{direction}".encode()).digest(size)


# A and B use different amounts in each direction so swapped accounts cannot reconcile.
def sizes(identity, round_number):
    scale = (1 if identity == "a" else 3) * (round_number + 1)
    return 37009 * scale, 19001 * scale


class Origin(socketserver.ThreadingTCPServer):
    daemon_threads = True

    def __init__(self, context):
        self.context = context
        self.counts = {}
        self.failures = []
        self.cache_requests = 0
        self.lock = threading.Lock()
        super().__init__(("127.0.0.1", 0), OriginConnection)

    def record(self, identity, channel):
        with self.lock:
            self.counts[identity] = (channel.received, channel.sent)

    def snapshot(self):
        with self.lock:
            return dict(self.counts)


class OriginConnection(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(20)
        channel = WireTLS(self.request, self.server.context, server=True)
        try:
            channel.run(channel.tls.do_handshake)
            identity = channel.read(1).decode("ascii")
            if identity == "G":
                self.cached_resource(channel)
                return
            if identity not in ("a", "b", "d"):
                raise ValueError("Unexpected TLS origin session")
            with self.server.lock:
                if identity in self.server.counts:
                    raise ValueError("Duplicate TLS origin session")
                self.server.counts[identity] = (channel.received, channel.sent)
            # A small, complete TLS record before streaming makes the Vision
            # switch observable independently of large-record TCP segmentation.
            channel.write(b"ready")
            for number in range(3):
                up, down = sizes(identity, number)
                if channel.read(up) != payload(identity, number, up, "up"):
                    raise ValueError("Origin received the wrong upload")
                channel.write(payload(identity, number, down, "down"))
                self.server.record(identity, channel)
            # Client waits at the third checkpoint with this connection still open.
            if channel.read(1) != b"!":
                raise ValueError("Invalid close marker")
            channel.run(channel.tls.unwrap)
            self.server.record(identity, channel)
        except Exception as error:
            with self.server.lock:
                self.server.failures.append(type(error).__name__ + ": " + str(error))

    def cached_resource(self, channel):
        request = bytearray(b"G")
        while not request.endswith(b"\r\n\r\n") and len(request) < 8192:
            request.extend(channel.read(1))
        if not request.startswith(b"GET /cache HTTP/1.1\r\n"):
            raise ValueError("Unexpected cache request")
        if any(header.startswith((b"proxy-authorization:", b"authorization:"))
               for header in request.lower().split(b"\r\n")):
            raise ValueError("Credential reached target")
        with self.server.lock:
            self.server.cache_requests += 1
        channel.write(("HTTP/1.1 200 OK\r\nCache-Control: public, max-age=600\r\n"
                       f"Date: {formatdate(usegmt=True)}\r\nContent-Length: 8\r\n"
                       "Connection: close\r\n\r\nresource").encode("ascii"))


class Cover(socketserver.ThreadingTCPServer):
    """REALITY's local handshake destination, deliberately separate from the measured origin."""
    daemon_threads = True


class CoverConnection(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(5)
        with contextlib.suppress(OSError):
            with self.server.context.wrap_socket(self.request, server_side=True) as tls:
                tls.recv(1024)


class Client:
    def __init__(self, identity, sock, context):
        self.identity = identity
        self.channel = WireTLS(sock, context)
        self.channel.run(self.channel.tls.do_handshake)
        self.channel.write(identity.encode("ascii"))
        if self.channel.read(5) != b"ready":
            raise ValueError("Missing origin greeting")

    def exchange(self, number):
        up, down = sizes(self.identity, number)
        self.channel.write(payload(self.identity, number, up, "up"))
        if self.channel.read(down) != payload(self.identity, number, down, "down"):
            raise ValueError("Client received the wrong download")

    def finish(self):
        self.channel.write(b"!")
        self.channel.run(self.channel.tls.unwrap)


class PlainOrigin(socketserver.ThreadingTCPServer):
    """Non-TLS target for exercising Vision's transition to unpadded, encrypted writes."""
    daemon_threads = True


class PlainConnection(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(8)
        with self.request.makefile("rb") as reader:
            for n in range(40):
                packet = reader.read(32)
                if packet != payload("p", n, 32, "up"):
                    return
                reply = payload("p", n, 819, "down")
                self.request.sendall(reply)
                self.server.received += len(packet)
                self.server.sent += len(reply)

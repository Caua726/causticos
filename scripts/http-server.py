#!/usr/bin/env python3
"""http-server.py — an HTTP peer for the guest that is not our code.

httpt dials this. SLIRP presents the host as 10.0.2.2 to the guest, so a
listener here is reachable from inside with no port forwarding.

It is written against raw sockets rather than http.server because the point is
to serve the shapes a real client has to survive, and the stdlib one will not
produce most of them: a chunked body, a body with no Content-Length that ends
at the close, a response dribbled out in pieces so the client's parser meets a
header split across two reads, a redirect, a 404 with a body.

The payload is a pure function of its offset — byte i is (i * 31 + 7) & 0xFF —
so the guest can verify what it received without the file having to be shipped
to it. A checksum would prove the bytes are consistent; this proves they are
the RIGHT bytes, in the right order, with none missing from the middle.

    scripts/http-server.py [port] [seconds] [certchain.pem keyfile.pem]

With the last two arguments it speaks TLS 1.3 instead, using OpenSSL's server
side — which is the point of testing against it. Two implementations that agree
with each other prove they agree with each other; a handshake against OpenSSL
proves the key schedule, the transcript and the record layer are what the RFC
says, because OpenSSL will simply refuse anything else.

Exits on its own after the timeout so a stuck test cannot leave it running.
"""

import socket
import os
import socketserver
import ssl
import sys
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 17780
TIMEOUT = float(sys.argv[2]) if len(sys.argv) > 2 else 120.0
CERT = sys.argv[3] if len(sys.argv) > 3 else None
KEY = sys.argv[4] if len(sys.argv) > 4 else None
# A directory of REAL files to serve, for tests whose subject is the content
# rather than the protocol — the audio stream needs a WAV the host generated
# and the guest has never seen. Synthetic paths still win, so nothing that
# already depends on this server changes.
SERVE_DIR = sys.argv[5] if len(sys.argv) > 5 else "build"

BLOB_LEN = 65536
CHUNKED_LEN = 5000
NOCLEN_LEN = 3000


def blob(n):
    return bytes(((i * 31 + 7) & 0xFF) for i in range(n))


BLOB = blob(BLOB_LEN)


def read_request(f):
    """Request line plus headers. Returns (method, target) or None."""
    line = f.readline(8192)
    if not line:
        return None
    parts = line.split()
    if len(parts) < 2:
        return None
    while True:
        h = f.readline(8192)
        if not h or h in (b"\r\n", b"\n"):
            break
    return parts[0].decode("latin1"), parts[1].decode("latin1")


class Handler(socketserver.StreamRequestHandler):
    timeout = 20

    def head(self, status, reason, extra=(), body_len=None, chunked=False):
        out = [f"HTTP/1.1 {status} {reason}\r\n".encode()]
        out.append(b"Server: causticos-test/1\r\n")
        if chunked:
            out.append(b"Transfer-Encoding: chunked\r\n")
        elif body_len is not None:
            out.append(f"Content-Length: {body_len}\r\n".encode())
        for e in extra:
            out.append(e.encode() + b"\r\n")
        out.append(b"Connection: close\r\n\r\n")
        return b"".join(out)

    def handle(self):
        try:
            req = read_request(self.rfile)
        except OSError:
            return
        if req is None:
            return
        method, target = req
        path = target.split("?", 1)[0]
        is_head = method == "HEAD"

        if path == "/f.bin":
            self.wfile.write(self.head(200, "OK", body_len=BLOB_LEN))
            if not is_head:
                self.wfile.write(BLOB)

        elif path == "/chunked":
            self.wfile.write(self.head(200, "OK", chunked=True))
            if not is_head:
                data = BLOB[:CHUNKED_LEN]
                at = 0
                # Deliberately uneven chunks, including one of a single byte:
                # a client that assumes chunks are uniform passes on a server
                # that happens to be uniform and fails on the next one.
                for size in (1, 7, 100, 1500, 4096):
                    if at >= len(data):
                        break
                    n = min(size, len(data) - at)
                    self.wfile.write(f"{n:x}\r\n".encode() + data[at:at + n] + b"\r\n")
                    at += n
                while at < len(data):
                    n = min(1000, len(data) - at)
                    self.wfile.write(f"{n:x}\r\n".encode() + data[at:at + n] + b"\r\n")
                    at += n
                # Zero chunk, one trailer, blank line.
                self.wfile.write(b"0\r\nX-Checksum: none\r\n\r\n")

        elif path == "/noclen":
            # No Content-Length and no chunking: the body ends when the
            # connection does. Only legal because Connection: close is set.
            self.wfile.write(self.head(200, "OK"))
            if not is_head:
                self.wfile.write(BLOB[:NOCLEN_LEN])

        elif path == "/slow":
            # The response head arrives in fragments, so the client's parser
            # meets a status line split from its headers and a header line
            # split down the middle.
            head = self.head(200, "OK", body_len=64)
            for i in range(0, len(head), 7):
                self.wfile.write(head[i:i + 7])
                self.wfile.flush()
                time.sleep(0.01)
            if not is_head:
                self.wfile.write(BLOB[:64])

        elif path == "/redirect":
            body = b"moved\n"
            self.wfile.write(self.head(302, "Found", extra=["Location: /f.bin"],
                                       body_len=len(body)))
            if not is_head:
                self.wfile.write(body)

        elif path == "/redirect-abs":
            body = b"moved\n"
            loc = f"Location: http://10.0.2.2:{PORT}/f.bin"
            self.wfile.write(self.head(302, "Found", extra=[loc],
                                       body_len=len(body)))
            if not is_head:
                self.wfile.write(body)

        elif path == "/continue":
            # A 100 Continue before the real response. A client that stops at
            # the first status line reports this as the answer.
            self.wfile.write(b"HTTP/1.1 100 Continue\r\n\r\n")
            self.wfile.flush()
            self.wfile.write(self.head(200, "OK", body_len=16))
            if not is_head:
                self.wfile.write(BLOB[:16])

        elif path == "/missing":
            body = b"no such thing\n"
            self.wfile.write(self.head(404, "Not Found", body_len=len(body)))
            if not is_head:
                self.wfile.write(body)

        else:
            # A real file, if there is one by that name. basename only: this is
            # a test server, but a test server that can be talked out of its
            # own directory is a bad habit to leave lying around.
            name = os.path.basename(path.lstrip("/"))
            full = os.path.join(SERVE_DIR, name) if name else ""
            if full and os.path.isfile(full):
                data = open(full, "rb").read()
                self.wfile.write(self.head(200, "OK", body_len=len(data)))
                if not is_head:
                    self.wfile.write(data)
            else:
                body = b"unknown path\n"
                self.wfile.write(self.head(404, "Not Found", body_len=len(body)))
                if not is_head:
                    self.wfile.write(body)

        try:
            self.wfile.flush()
            self.connection.shutdown(socket.SHUT_WR)
        except OSError:
            pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def get_request(self):
        # socketserver swallows an OSError from accept(), and for a TLS socket
        # accept() is where the handshake happens — so a client whose hello is
        # rejected sees a closed connection and the server says nothing at all.
        # That silence is useless to whoever is debugging the client, which is
        # the entire reason this server exists.
        try:
            return super().get_request()
        except OSError as e:
            print(f"handshake rejected: {e}", flush=True)
            raise


def main():
    srv = Server(("127.0.0.1", PORT), Handler)
    srv.timeout = 0.5
    kind = "http"
    if CERT:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        # TLS 1.3 and nothing else, so a client that quietly fell back to 1.2
        # fails here rather than passing a test it should not have.
        ctx.minimum_version = ssl.TLSVersion.TLSv1_3
        ctx.maximum_version = ssl.TLSVersion.TLSv1_3
        ctx.load_cert_chain(CERT, KEY)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
        kind = "https"
    print(f"{kind} server on 127.0.0.1:{PORT} for {TIMEOUT}s", flush=True)
    end = time.monotonic() + TIMEOUT
    try:
        while time.monotonic() < end:
            srv.handle_request()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()


if __name__ == "__main__":
    main()

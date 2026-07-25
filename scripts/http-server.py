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

    scripts/http-server.py [port] [seconds]

Exits on its own after the timeout so a stuck test cannot leave it running.
"""

import socket
import socketserver
import sys
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 17780
TIMEOUT = float(sys.argv[2]) if len(sys.argv) > 2 else 120.0

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


def main():
    srv = Server(("127.0.0.1", PORT), Handler)
    srv.timeout = 0.5
    print(f"http server on 127.0.0.1:{PORT} for {TIMEOUT}s", flush=True)
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

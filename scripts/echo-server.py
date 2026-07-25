#!/usr/bin/env python3
"""echo-server.py — a TCP peer the guest can talk to that is not our code.

netdt's TCP test dials this. SLIRP presents the host as 10.0.2.2 to the
guest, so a listener here is reachable from inside with no port forwarding:
the guest dials out rather than the host dialling in.

The point of it being Python is that it is not the stack under test. A
loopback of two of our own connections proves they agree with each other; it
cannot prove they agree with anyone else. This one does a real three-way
handshake with a real implementation, and if our window scaling, our options
or our sequence arithmetic were wrong in a way both our ends shared, this is
where it would show.

    scripts/echo-server.py [port] [seconds]

Exits on its own after the timeout so a stuck test cannot leave it running.
"""

import socket
import sys
import threading

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 17777
TIMEOUT = float(sys.argv[2]) if len(sys.argv) > 2 else 120.0


def serve(conn):
    try:
        while True:
            data = conn.recv(4096)
            if not data:
                break
            conn.sendall(data)
    except OSError:
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


def main():
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", PORT))
    s.listen(8)
    s.settimeout(TIMEOUT)
    print(f"echo server on 127.0.0.1:{PORT} for {TIMEOUT}s", flush=True)
    try:
        while True:
            conn, _ = s.accept()
            threading.Thread(target=serve, args=(conn,), daemon=True).start()
    except (socket.timeout, OSError, KeyboardInterrupt):
        pass
    finally:
        s.close()


if __name__ == "__main__":
    main()

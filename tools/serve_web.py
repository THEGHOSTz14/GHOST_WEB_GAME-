#!/usr/bin/env python3
"""Serve builds/web the way a game portal does.

Deliberately does NOT send COOP/COEP headers: y8 does not send them either, so
a build that only works through this server with --isolate is a build that will
white-screen on the portal. Run `tools/build_web.sh` first, then this, then open
http://127.0.0.1:8060/ .
"""

import argparse
import os
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MIME = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript",
    ".wasm": "application/wasm",
    ".pck": "application/octet-stream",
    ".png": "image/png",
    ".svg": "image/svg+xml",
    ".json": "application/json",
    ".cfg": "text/plain",
}


class Handler(BaseHTTPRequestHandler):
    root = ""
    isolate = False

    def _send(self, code, ctype, body, encoding=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        if encoding:
            self.send_header("Content-Encoding", encoding)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        if self.isolate:
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path in ("/", ""):
            path = "/index.html"
        rel = os.path.normpath(path.lstrip("/"))
        if rel.startswith("..") or os.path.isabs(rel):
            self._send(403, "text/plain", b"nope")
            return
        full = os.path.join(self.root, rel)
        if not os.path.isfile(full):
            self._send(404, "text/plain", b"not found")
            return
        ctype = MIME.get(os.path.splitext(full)[1].lower(), "application/octet-stream")
        if "gzip" in self.headers.get("Accept-Encoding", "") \
                and os.path.isfile(full + ".gz"):
            self._send(200, ctype, open(full + ".gz", "rb").read(), "gzip")
            return
        self._send(200, ctype, open(full, "rb").read())

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


def main():
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", default=os.path.join(here, "builds", "web"))
    ap.add_argument("--port", type=int, default=8060)
    ap.add_argument("--isolate", action="store_true",
                    help="add COOP/COEP, i.e. test a threaded build (not how y8 serves you)")
    a = ap.parse_args()
    if not os.path.isfile(os.path.join(a.root, "index.html")):
        print(f"no index.html in {a.root} -- run tools/build_web.sh first", file=sys.stderr)
        return 1
    Handler.root = a.root
    Handler.isolate = a.isolate
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), Handler)
    print(f"serving {a.root} at http://127.0.0.1:{a.port}/ "
          f"({'isolated' if a.isolate else 'portal-like, no COOP/COEP'})")
    print("ctrl-c to stop")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())

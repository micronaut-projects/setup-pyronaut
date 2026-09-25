#!/usr/bin/env python3
"""A stand-in for the GitHub REST API, serving a directory tree.

`/repos/o/r/releases?per_page=100` is answered from `repos/o/r/releases/index.json`,
so an endpoint can be both a document and the parent of others. The query string
is ignored. Every request's path and Authorization header is appended to
`requests.log` in the served directory, and the chosen port is written to `port`.

Usage: server.py DIRECTORY
"""

import http.server
import sys
from pathlib import Path

ROOT = Path(sys.argv[1]).resolve()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0].strip("/")
        with open(ROOT / "requests.log", "a", encoding="utf-8") as log:
            log.write(f"{path} {self.headers.get('Authorization', '-')}\n")
        target = (ROOT / path).resolve()
        if target.is_dir():
            target = target / "index.json"
        if ROOT not in target.parents or not target.is_file():
            self.send_error(404)
            return
        body = target.read_bytes()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
(ROOT / "port").write_text(str(server.server_address[1]), encoding="utf-8")
server.serve_forever()

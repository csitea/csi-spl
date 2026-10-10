#!/usr/bin/env python3
"""Signed-out API stub for the WUI browser e2e (workflows 10 and 11).

GET /api/v1/auth/session answers 401 (auth-v1 section 4) and
/api/v1/auth/providers an empty list. Without it serve-generated.mjs would
SPA-fallback those URLs to HTML and the console-errors gate would see a JSON
parse error. Everything else is a JSON 404. Usage: wui-e2e-mock-api.py <port>
"""

import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class H(BaseHTTPRequestHandler):
    def _send(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        p = self.path.split("?")[0]
        if p == "/api/v1/auth/session":
            return self._send(401, b'{"error":"unauthenticated"}')
        if p == "/api/v1/auth/providers":
            return self._send(200, b'{"native":false,"providers":[]}')
        self._send(404, b'{"error":"not_found"}')

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.end_headers()

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()

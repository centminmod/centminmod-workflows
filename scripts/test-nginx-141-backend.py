#!/usr/bin/env python3
"""Loopback test backend for the 141.00beta01 nginx feature checks.

usage: test-nginx-141-backend.py <port> [ok|sse]
  ok   any method and path: 200 "backend <port> <method> <path>"
  sse  GET: text/event-stream with one event, a 3 second pause, then a second
       event; POST and DELETE: 200 JSON-RPC result
Listens on 127.0.0.1 only.
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
MODE = sys.argv[2] if len(sys.argv) > 2 else "ok"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):  # noqa: A002 - base class signature
        pass

    def _send(self, code, body, ctype="text/plain"):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _any(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        if MODE == "sse" and self.command == "GET":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(b"data: first\n\n")
            self.wfile.flush()
            time.sleep(3)
            self.wfile.write(b"data: second\n\n")
            self.wfile.flush()
            self.close_connection = True
        elif MODE == "sse":
            self._send(200, json.dumps({"jsonrpc": "2.0", "id": 1, "result": {}}), "application/json")
        else:
            self._send(200, "backend %d %s %s\n" % (PORT, self.command, self.path))

    do_GET = do_POST = do_PUT = do_DELETE = _any


ThreadingHTTPServer.daemon_threads = True
ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()

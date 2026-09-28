"""Small local-lab HTTP server; reports the Pod's configured version."""

import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/":
            status = 200
            payload = {
                "version": os.environ["APP_VERSION"],
                "pod": os.environ.get("POD_NAME", "local-test"),
            }
        elif self.path == "/ready":
            status = 200
            payload = {"ready": True}
        else:
            status = 404
            payload = {"error": "unknown path"}

        body = (json.dumps(payload) + "\n").encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    print(f"Starting version={os.environ['APP_VERSION']} port={port}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()

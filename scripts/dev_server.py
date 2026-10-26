"""Local dev server: serves frontend/ and forwards /api/* to the backend, like nginx does in the container."""

import os
import urllib.error
import urllib.request
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

BACKEND_URL = os.getenv("BACKEND_URL", "http://127.0.0.1:8000")
PORT = int(os.getenv("PORT", "8080"))
FRONTEND_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "frontend")
FORWARDED_HEADERS = ("Content-Type", "X-Session-Id", "Idempotency-Key")


class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        self._proxy() if self.path.startswith("/api/") else super().do_GET()

    def _proxy(self):
        if not self.path.startswith("/api/"):
            self.send_error(404)
            return
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)) or None
        request = urllib.request.Request(BACKEND_URL + self.path[len("/api"):], data=body, method=self.command)
        for name in FORWARDED_HEADERS:
            if self.headers.get(name):
                request.add_header(name, self.headers[name])
        try:
            response = urllib.request.urlopen(request, timeout=10)
        except urllib.error.HTTPError as error:
            response = error  # 4xx/5xx answers still carry a body the UI needs to show
        except urllib.error.URLError:
            self.send_error(502, "Backend not reachable. Is it running on " + BACKEND_URL + "?")
            return
        payload = response.read()
        self.send_response(response.getcode())
        self.send_header("Content-Type", response.headers.get("Content-Type", "application/json"))
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    do_POST = do_PATCH = do_DELETE = _proxy


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", PORT), partial(Handler, directory=FRONTEND_DIR))
    print(f"Shop UI: http://localhost:{PORT}  (API calls go to {BACKEND_URL})")
    server.serve_forever()

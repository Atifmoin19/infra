"""Combined health for Render's healthCheckPath (/health -> Caddy -> here).

200 {"status": "ok", ...} only when all three apps answer 200 on their own /health;
otherwise 503 with per-app results. Stdlib only, runs on the base image's python.
"""
import json
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

APPS = {
    "portfolio": "http://127.0.0.1:8001/health",
    "expense": "http://127.0.0.1:8002/health",
    "dayline": "http://127.0.0.1:8003/health",
}


def probe(url):
    try:
        with urllib.request.urlopen(url, timeout=4) as r:
            return r.status
    except Exception as e:  # noqa: BLE001
        return getattr(e, "code", None) or 0


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        with ThreadPoolExecutor(len(APPS)) as pool:
            codes = dict(zip(APPS, pool.map(probe, APPS.values())))
        ok = all(c == 200 for c in codes.values())
        body = json.dumps({"status": "ok" if ok else "degraded",
                           "services": {k: ("ok" if c == 200 else f"down ({c})") for k, c in codes.items()}}).encode()
        self.send_response(200 if ok else 503)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    do_HEAD = do_GET

    def log_message(self, *args):  # quiet: Render polls this every few seconds
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 8099), Handler).serve_forever()

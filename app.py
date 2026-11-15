from __future__ import annotations

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


ROOT = Path(__file__).parent
LOG_PATH = ROOT / "data" / "application.jsonl"
PORT = 8002
LEVELS = {"INFO", "WARN", "ERROR"}


def load_events() -> list[dict]:
    events = []
    with LOG_PATH.open(encoding="utf-8") as log_file:
        for line_number, line in enumerate(log_file, start=1):
            try:
                event = json.loads(line)
            except json.JSONDecodeError as error:
                raise ValueError(f"Invalid JSON log at line {line_number}") from error
            required = {"timestamp", "level", "service", "message"}
            if not isinstance(event, dict) or not required.issubset(event):
                raise ValueError(f"Log at line {line_number} is missing required fields")
            events.append(event)
    return events


def search_events(query: str = "", level: str = "", service: str = "") -> list[dict]:
    terms = query.lower().strip().split()
    events = load_events()
    return [
        event for event in events
        if (not level or level in LEVELS and event["level"] == level)
        and (not service or event["service"].lower() == service.lower())
        and all(term in json.dumps(event).lower() for term in terms)
    ]


class Handler(BaseHTTPRequestHandler):
    def send_body(self, body: bytes, content_type: str, status: int = 200) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        request = urlparse(self.path)
        if request.path == "/":
            self.send_body((ROOT / "index.html").read_bytes(), "text/html; charset=utf-8")
            return
        if request.path == "/api/events":
            params = parse_qs(request.query)
            try:
                events = search_events(
                    params.get("q", [""])[0],
                    params.get("level", [""])[0].upper(),
                    params.get("service", [""])[0],
                )
            except (OSError, ValueError) as error:
                self.send_body(json.dumps({"error": str(error)}).encode(), "application/json", 500)
                return
            self.send_body(json.dumps(events).encode(), "application/json")
            return
        if request.path == "/api/services":
            self.send_body(json.dumps(sorted({event["service"] for event in load_events()})).encode(), "application/json")
            return
        self.send_body(b'{"error":"Not found"}', "application/json", 404)

if __name__ == "__main__":
    print(f"Log Triage Workbench listening on http://localhost:{PORT}")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()

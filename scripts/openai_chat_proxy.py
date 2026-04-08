#!/usr/bin/env python3
"""
Small reverse proxy in front of llama-server that fixes common client JSON bugs:
- message fields that must be strings but are sent as null (content, reasoning_content, …)
- tool_calls[].function.arguments == null -> "{}"

Uses only the stdlib. For POST /v1/chat/completions only; all other requests are forwarded unchanged.
"""
from __future__ import annotations

import argparse
import http.client
import json
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
    "proxy-connection",
}


def _null_string_fields(obj: Any, keys: frozenset[str]) -> None:
    if not isinstance(obj, dict):
        return
    for k in keys:
        if k in obj and obj[k] is None:
            obj[k] = ""


def _sanitize_message(msg: Any) -> None:
    if not isinstance(msg, dict):
        return
    _null_string_fields(
        msg,
        frozenset(
            {
                "content",
                "reasoning_content",
                "name",
                "tool_call_id",
                "refusal",
            }
        ),
    )
    tc = msg.get("tool_calls")
    if isinstance(tc, list):
        for call in tc:
            if not isinstance(call, dict):
                continue
            _null_string_fields(call, frozenset({"id", "type"}))
            fn = call.get("function")
            if isinstance(fn, dict):
                _null_string_fields(fn, frozenset({"name"}))
                a = fn.get("arguments")
                if a is None or a == "":
                    fn["arguments"] = "{}"


def sanitize_chat_completions_body(body: bytes) -> bytes:
    if not body:
        return body
    try:
        data = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return body
    if not isinstance(data, dict):
        return body
    msgs = data.get("messages")
    if isinstance(msgs, list):
        for m in msgs:
            _sanitize_message(m)
    try:
        return json.dumps(data, ensure_ascii=False).encode("utf-8")
    except (TypeError, ValueError):
        return body


def _parse_backend(url: str) -> tuple[str, int, bool]:
    p = urllib.parse.urlsplit(url)
    if p.scheme not in ("http", "https"):
        raise SystemExit(f"Backend URL must be http(s): {url!r}")
    host = p.hostname or "127.0.0.1"
    port = p.port or (443 if p.scheme == "https" else 80)
    return host, port, p.scheme == "https"


class Handler(BaseHTTPRequestHandler):
    backend_host: str
    backend_port: int
    backend_https: bool

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write("%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), fmt % args))

    def _forward(self) -> None:
        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length) if length > 0 else b""

        path = self.path
        _parsed = urllib.parse.urlsplit(path)
        if self.command == "POST" and _parsed.path.rstrip("/") == "/v1/chat/completions":
            body = sanitize_chat_completions_body(body)

        headers = {}
        for key, value in self.headers.items():
            lk = key.lower()
            if lk in HOP_BY_HOP:
                continue
            if lk == "host":
                continue
            headers[key] = value
        headers["Host"] = f"{self.backend_host}:{self.backend_port}"
        headers["Connection"] = "close"
        headers["Content-Length"] = str(len(body))

        conn_cls = http.client.HTTPSConnection if self.backend_https else http.client.HTTPConnection
        conn = conn_cls(self.backend_host, self.backend_port, timeout=600)
        try:
            conn.request(self.command, path, body=body, headers=headers)
            resp = conn.getresponse()
            self.send_response(resp.status)
            for name, value in resp.getheaders():
                if name.lower() in HOP_BY_HOP:
                    continue
                self.send_header(name, value)
            self.end_headers()
            while True:
                chunk = resp.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
        finally:
            conn.close()

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = do_HEAD = _forward


def main() -> None:
    ap = argparse.ArgumentParser(description="Sanitize OpenAI chat JSON, proxy to llama-server")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--backend", default="http://127.0.0.1:18080", help="llama-server base URL")
    args = ap.parse_args()
    host, port, https = _parse_backend(args.backend)
    Handler.backend_host = host
    Handler.backend_port = port
    Handler.backend_https = https

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"openai_chat_proxy listening on {args.host}:{args.port} -> {args.backend}", file=sys.stderr)
    server.serve_forever()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Forward requests to Ollama, forcing "think": false on chat and generate calls.

paperless-ngx 3.4.2 cannot switch thinking off: it passes extra LLM params into
the request's `options`, where Ollama ignores `think`. gemma4 thinks by
default, and on the Mac mini a suggestion-sized prompt took 20 s and 1508
tokens with thinking, 5 s and 422 tokens without (2026-11-06). Paperless
points at this proxy instead of Ollama; every other call (embeddings, model
listing, version) passes through unchanged, and streamed replies are relayed
as they arrive.

Usage: ollama-think-proxy.py [--listen 0.0.0.0:11435] [--upstream 127.0.0.1:11434]
Standard library only, Python 3.7+ (macOS /usr/bin/python3 is enough).
"""
import argparse
import http.client
import http.server
import json
import sys
import time

REWRITE_PATHS = ("/api/chat", "/api/generate")
HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-connection", "transfer-encoding", "te",
    "trailer", "upgrade", "content-length", "host",
}
UPSTREAM_TIMEOUT = 900  # seconds; a cold load of a 26B model takes over a minute


def rewrite_body(path, body):
    """Return (body, rewritten): "think": false set on a chat/generate call whose body is a JSON object."""
    if path.split("?", 1)[0] not in REWRITE_PATHS or not body:
        return body, False
    try:
        data = json.loads(body)
    except ValueError:
        return body, False
    if not isinstance(data, dict):
        return body, False
    data["think"] = False
    return json.dumps(data).encode("utf-8"), True


def split_hostport(value):
    host, _, port = value.rpartition(":")
    return host, int(port)


def read_chunked(rfile):
    parts = []
    while True:
        size = int(rfile.readline().split(b";", 1)[0].strip() or b"0", 16)
        if size == 0:
            while rfile.readline() not in (b"\r\n", b"\n", b""):
                pass
            return b"".join(parts)
        parts.append(rfile.read(size))
        rfile.readline()


class Handler(http.server.BaseHTTPRequestHandler):
    upstream = ("127.0.0.1", 11434)

    def _forward(self):
        started = time.monotonic()
        if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
            body = read_chunked(self.rfile)
        else:
            body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        body, rewritten = rewrite_body(self.path, body)
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP_BY_HOP}
        if body or self.command in ("POST", "PUT", "PATCH"):
            headers["Content-Length"] = str(len(body))
        conn = http.client.HTTPConnection(*self.upstream, timeout=UPSTREAM_TIMEOUT)
        try:
            try:
                conn.request(self.command, self.path, body=body or None, headers=headers)
                resp = conn.getresponse()
            except OSError as exc:
                self.send_error(502, "upstream unreachable: %s" % exc)
                self._log(502, rewritten, started)
                return
            self.send_response(resp.status, resp.reason)
            for k, v in resp.getheaders():
                if k.lower() not in HOP_BY_HOP:
                    self.send_header(k, v)
            length = resp.getheader("Content-Length")
            if length is not None and not resp.chunked:
                self.send_header("Content-Length", length)
            self.send_header("Connection", "close")
            self.end_headers()
            if self.command != "HEAD":
                while True:
                    chunk = resp.read1(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
            self._log(resp.status, rewritten, started)
        except (BrokenPipeError, ConnectionResetError):
            self._log("client-gone", rewritten, started)
        finally:
            conn.close()

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = _forward

    def _log(self, status, rewritten, started):
        sys.stderr.write("%s %s %s %s think=%s %.1fs\n" % (
            self.log_date_time_string(), self.command, self.path, status,
            "false" if rewritten else "as-sent", time.monotonic() - started))

    def log_message(self, fmt, *args):
        pass  # one line per request comes from _log


def make_server(listen, upstream):
    handler = type("BoundHandler", (Handler,), {"upstream": upstream})
    server = http.server.ThreadingHTTPServer(listen, handler)
    server.daemon_threads = True
    return server


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--listen", default="0.0.0.0:11435")
    parser.add_argument("--upstream", default="127.0.0.1:11434")
    args = parser.parse_args(argv)
    server = make_server(split_hostport(args.listen), split_hostport(args.upstream))
    sys.stderr.write("listening on %s, upstream %s\n" % (args.listen, args.upstream))
    server.serve_forever()


if __name__ == "__main__":
    main()

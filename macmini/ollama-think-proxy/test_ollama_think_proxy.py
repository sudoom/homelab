"""Tests for ollama-think-proxy: python3 -m unittest discover -s macmini/ollama-think-proxy -v

The integration tests run the proxy against a fake Ollama on 127.0.0.1 (no Ollama needed).
"""
import http.client
import http.server
import importlib.util
import json
import os
import threading
import unittest

_spec = importlib.util.spec_from_file_location(
    "proxy", os.path.join(os.path.dirname(os.path.abspath(__file__)), "ollama-think-proxy.py"))
proxy = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(proxy)

CHAT = {"model": "gemma4:26b", "messages": [{"role": "user", "content": "Faktura 1/03/2025"}]}


class RewriteBody(unittest.TestCase):
    def test_sets_think_false_on_chat(self):
        body, rewritten = proxy.rewrite_body("/api/chat", json.dumps(CHAT).encode())
        self.assertTrue(rewritten)
        self.assertIs(json.loads(body)["think"], False)
        self.assertEqual(json.loads(body)["messages"], CHAT["messages"])

    def test_overrides_think_true_on_generate(self):
        body, rewritten = proxy.rewrite_body("/api/generate", b'{"model": "m", "prompt": "x", "think": true}')
        self.assertTrue(rewritten)
        self.assertIs(json.loads(body)["think"], False)

    def test_query_string_still_matches(self):
        _, rewritten = proxy.rewrite_body("/api/chat?x=1", b'{"model": "m"}')
        self.assertTrue(rewritten)

    def test_other_paths_untouched(self):
        raw = b'{"model": "bge-m3", "input": "tekst"}'
        self.assertEqual(proxy.rewrite_body("/api/embed", raw), (raw, False))

    def test_non_json_and_non_object_untouched(self):
        for raw in (b"not json", b"[1, 2]", b""):
            self.assertEqual(proxy.rewrite_body("/api/chat", raw), (raw, False))


class FakeOllama(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    received = []
    release = threading.Event()

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        FakeOllama.received.append((self.path, body))
        if self.path == "/api/chat":
            self.send_response(200)
            self.send_header("Content-Type", "application/x-ndjson")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for i, line in enumerate((b'{"n": 1}\n', b'{"n": 2}\n', b'{"done": true}\n')):
                self.wfile.write(b"%x\r\n%s\r\n" % (len(line), line))
                self.wfile.flush()
                if i == 0:
                    FakeOllama.release.wait(5)  # the proxy must deliver line 1 before this returns
            self.wfile.write(b"0\r\n\r\n")
        else:
            reply = b'{"embeddings": [[0.1]]}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(reply)))
            self.end_headers()
            self.wfile.write(reply)

    def log_message(self, fmt, *args):
        pass


def _serve(server):
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


class ThroughTheProxy(unittest.TestCase):
    def setUp(self):
        FakeOllama.received = []
        FakeOllama.release = threading.Event()
        self.upstream = _serve(http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeOllama))
        self.proxy = _serve(proxy.make_server(("127.0.0.1", 0), self.upstream.server_address))
        proxy.sys.stderr = open(os.devnull, "w")

    def tearDown(self):
        for s in (self.proxy, self.upstream):
            s.shutdown()
            s.server_close()
        proxy.sys.stderr.close()
        proxy.sys.stderr = proxy.sys.__stderr__

    def _post(self, path, payload):
        conn = http.client.HTTPConnection(*self.proxy.server_address, timeout=5)
        conn.request("POST", path, body=payload, headers={"Content-Type": "application/json"})
        return conn, conn.getresponse()

    def test_chat_reaches_ollama_with_think_false_and_streams(self):
        conn, resp = self._post("/api/chat", json.dumps(CHAT).encode())
        self.assertEqual(resp.status, 200)
        self.assertEqual(resp.readline(), b'{"n": 1}\n')  # arrives while upstream still holds the rest
        FakeOllama.release.set()
        self.assertEqual(resp.read(), b'{"n": 2}\n{"done": true}\n')
        conn.close()
        path, sent = FakeOllama.received[0]
        self.assertEqual(path, "/api/chat")
        self.assertIs(json.loads(sent)["think"], False)

    def test_embed_passes_through_unchanged(self):
        raw = b'{"model": "bge-m3", "input": "tekst"}'
        conn, resp = self._post("/api/embed", raw)
        self.assertEqual((resp.status, resp.read()), (200, b'{"embeddings": [[0.1]]}'))
        conn.close()
        self.assertEqual(FakeOllama.received[0], ("/api/embed", raw))

    def test_upstream_down_is_502(self):
        dead = proxy.make_server(("127.0.0.1", 0), ("127.0.0.1", 1))  # nothing listens on port 1
        _serve(dead)
        try:
            conn = http.client.HTTPConnection(*dead.server_address, timeout=5)
            conn.request("POST", "/api/chat", body=b'{"model": "m"}')
            self.assertEqual(conn.getresponse().status, 502)
            conn.close()
        finally:
            dead.shutdown()
            dead.server_close()


if __name__ == "__main__":
    unittest.main()

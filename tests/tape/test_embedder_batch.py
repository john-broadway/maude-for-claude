"""embed_batch: one validated client for the house's own /v1/embeddings (seeing-gap A1).

Proximo's validation, carried over (src/proximo/vectors.py at b74f1ce): the response's
indices must be a 0..n-1 permutation, every vector one dimension, under a ceiling, and
finite. A wrong answer is refused whole, never half-stored. A stdlib server stands in for
the house's embedder, so nothing here depends on one being up.
"""
from __future__ import annotations

import json
import pathlib
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

from maude_tape import embedder

MODE = {"kind": "ok"}
SEEN = []


class _Stub(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        inputs = body["input"] if isinstance(body["input"], list) else [body["input"]]
        SEEN.append(inputs)
        kind = MODE["kind"]
        if kind == "too-long" and any(len(t) > 50 for t in inputs):
            self.send_response(400); self.end_headers()
            self.wfile.write(b'{"error":{"code":400,"type":"exceed_context_size_error"}}')
            return
        rows = [{"index": i, "embedding": [float(len(t)), 1.0, 0.0]} for i, t in enumerate(inputs)]
        if kind == "bad-index" and len(rows) > 1:
            rows[0]["index"] = -1
        if kind == "ragged" and len(rows) > 1:
            rows[1]["embedding"] = [1.0]
        if kind == "nan":
            rows[0]["embedding"] = [float("nan"), 1.0, 0.0]
        if kind == "short":
            rows = rows[:-1]
        data = json.dumps({"data": rows, "model": "stub"}, allow_nan=True).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.end_headers(); self.wfile.write(data)


@pytest.fixture
def url():
    srv = HTTPServer(("127.0.0.1", 0), _Stub)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    MODE["kind"] = "ok"; SEEN.clear()
    yield f"http://127.0.0.1:{srv.server_port}/v1/embeddings"
    srv.shutdown()


def test_a_batch_comes_back_in_input_order_and_unit_length(url):
    vecs = embedder.embed_batch(url, ["ab", "abcd"])
    assert len(vecs) == 2 and all(abs(sum(x * x for x in v) - 1) < 1e-9 for v in vecs)
    assert vecs[0] != vecs[1]


def test_a_prefix_is_sent_with_every_text(url):
    embedder.embed_batch(url, ["one"], prefix="search_query: ")
    assert SEEN[-1] == ["search_query: one"]


@pytest.mark.parametrize("kind", ["bad-index", "ragged", "nan", "short"])
def test_a_wrong_answer_is_refused_whole(url, kind):
    MODE["kind"] = kind
    with pytest.raises(embedder.EmbedError):
        embedder.embed_batch(url, ["a", "bb", "ccc"])


def test_an_input_too_long_for_the_window_is_named(url):
    MODE["kind"] = "too-long"
    with pytest.raises(embedder.EmbedError, match="too long"):
        embedder.embed_batch(url, ["x" * 80])


def test_only_http_urls(url):
    with pytest.raises(embedder.EmbedError):
        embedder.embed_batch("file:///etc/passwd", ["a"])


def test_a_dead_endpoint_fails_inside_its_timeout():
    import time
    t = time.time()
    with pytest.raises(embedder.EmbedError):
        embedder.embed_batch("http://127.0.0.1:9/v1/embeddings", ["a"], timeout=1.0)
    assert time.time() - t < 3


# --- discover: the house's embedder, proven by one real request ------------------------

def _port(url):
    return int(url.split(":")[2].split("/")[0])


def test_discover_finds_the_embedder_on_a_loopback_port(url):
    found = embedder.discover(ports=(9, _port(url)))
    assert found == {"url": url, "model": "stub", "dim": 3}


def test_an_open_port_that_is_not_an_embedder_is_not_one():
    srv = HTTPServer(("127.0.0.1", 0), BaseHTTPRequestHandler)  # answers 501 to a POST
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        assert embedder.discover(ports=(srv.server_port,)) is None
    finally:
        srv.shutdown()


def test_nothing_listening_finds_nothing():
    assert embedder.discover(ports=(9,)) is None


def test_an_endpoint_the_user_named_is_used_and_still_proven(url, monkeypatch):
    monkeypatch.setenv(embedder.ENV_URL, url)
    assert embedder.discover(ports=())["url"] == url
    MODE["kind"] = "nan"
    assert embedder.discover(ports=()) is None


def test_no_model_name_is_sent_unless_asked(url, monkeypatch):
    sent = []
    real = embedder.urllib.request.Request
    monkeypatch.setattr(embedder.urllib.request, "Request",
                        lambda u, data=None, headers=None: sent.append(json.loads(data)) or real(u, data=data, headers=headers))
    embedder.embed_batch(url, ["a"])
    embedder.embed_batch(url, ["a"], model="nomic")
    assert "model" not in sent[0] and sent[1]["model"] == "nomic"

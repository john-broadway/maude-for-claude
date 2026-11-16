"""Optional BYO embedder — an OpenAI-style /v1/embeddings client for semantic recall.

The plugin ships NO embedding service and NO default endpoint. A sovereign installer who
already runs one points `MAUDE_TAPE_EMBED_URL` at it (or passes url=); without it, semantic
recall stays quiet and the tape runs sqlite-only. Uses stdlib urllib — brings nothing of its own.
"""
from __future__ import annotations

import json
import math
import os
import urllib.error
import urllib.request
from typing import Callable

ENV_URL = "MAUDE_TAPE_EMBED_URL"
_BATCH = 32
_MAX_DIM = 16384  # over every embedding model in common use; a misbehaving endpoint cannot inflate the store


class EmbedError(Exception):
    """The endpoint failed, or answered with something that cannot be trusted."""


def embed_batch(url: str, texts: list[str], *, model: str | None = None, prefix: str = "",
                timeout: float = 2.0, info: dict | None = None) -> list[list[float]]:
    """Unit vectors for `texts`, in their order, from an OpenAI-style /v1/embeddings `url`.

    Validated the way Proximo's vectors.py learned to (lens, 2026-08-01): the response's
    indices must be a 0..n-1 permutation (a count check let a vector land in the wrong
    text's slot), one dimension under a ceiling, every value finite. Anything else raises
    EmbedError and nothing is returned, so a half-answered batch never reaches a store.
    `prefix` goes on every text: asymmetric models (nomic, bge, Qwen3) want one on the query
    side and another on the documents.
    """
    if not url.lower().startswith(("http://", "https://")):
        raise EmbedError(f"embedder url must be http(s), got {url!r}")
    out: list[list[float]] = []
    for i in range(0, len(texts), _BATCH):
        chunk = [prefix + t for t in texts[i:i + _BATCH]]
        req = urllib.request.Request(  # noqa: S310 — scheme pinned to http(s) above
            # No model name unless one was asked for: llama-server echoes back whatever it is
            # sent, and the store's content hash must carry the model that really answered.
            url, data=json.dumps({"input": chunk, **({"model": model} if model else {})}).encode(),
            headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310
                payload = json.loads(resp.read())
        except urllib.error.HTTPError as exc:
            body = exc.read()[:300].decode("utf-8", "replace")
            if "context" in body or "too large" in body:
                raise EmbedError(f"input too long for the embedder's window: {body}") from exc
            raise EmbedError(f"embedder answered HTTP {exc.code}") from exc
        except Exception as exc:
            raise EmbedError(f"embedder unreachable: {type(exc).__name__}") from exc
        rows = payload.get("data") if isinstance(payload, dict) else None
        if info is not None and isinstance(payload, dict) and isinstance(payload.get("model"), str):
            info["model"] = payload["model"][:200]
        if not isinstance(rows, list) or len(rows) != len(chunk):
            raise EmbedError(f"embedder returned {len(rows) if isinstance(rows, list) else 'no'} "
                             f"vectors for {len(chunk)} inputs")
        if sorted(r.get("index") for r in rows if isinstance(r.get("index"), int)) != list(range(len(chunk))):
            raise EmbedError("embedder indices are not a 0..n-1 permutation")
        vecs = [r.get("embedding") for r in sorted(rows, key=lambda r: r["index"])]
        if any(not isinstance(v, list) or not v for v in vecs):
            raise EmbedError("embedder returned a malformed vector")
        dim = len(vecs[0])
        if dim > _MAX_DIM or any(len(v) != dim for v in vecs):
            raise EmbedError("embedder returned mixed or oversized dimensions")
        for v in vecs:
            if not all(isinstance(x, (int, float)) and math.isfinite(x) for x in v):
                raise EmbedError("embedder returned a non-finite value")
            norm = math.sqrt(sum(x * x for x in v))
            out.append([x / norm for x in v] if norm else v)
    return out


PROBE_PORTS = (8080, 11434, 8000, 8081)  # llama.cpp, ollama, vLLM, a second llama.cpp


def discover(ports: tuple[int, ...] = PROBE_PORTS, *, deadline: float = 2.5) -> dict | None:
    """The house's embedder, or None. Loopback only: a remote endpoint is used only when the
    user named it in MAUDE_TAPE_EMBED_URL (the sovereignty rule from the 2026-06-27 me-model
    build). An open port is not an embedder: each candidate must answer one real embeddings
    request through embed_batch's checks. Bounded by `deadline`, inside the SessionStart
    probe's 5 s."""
    import time
    stop = time.monotonic() + deadline
    named = os.environ.get(ENV_URL, "").strip()
    urls = ([named] if named else []) + [f"http://127.0.0.1:{p}/v1/embeddings" for p in ports]
    for url in urls:
        left = stop - time.monotonic()
        if left <= 0.05:
            return None
        info: dict = {}
        try:
            vec = embed_batch(url, ["maude probe"], timeout=min(1.0, left), info=info)[0]
        except EmbedError:
            continue
        return {"url": url, "model": info.get("model", "embedding"), "dim": len(vec)}
    return None


def http_embedder(
    url: str | None = None, model: str = "embedding", timeout: float = 10.0
) -> Callable[[str], list[float]]:
    """Return an embed(text)->vector bound to an OpenAI-compatible /v1/embeddings endpoint.

    url resolves from the argument, else $MAUDE_TAPE_EMBED_URL. No default — the installer
    supplies their own service, or semantic recall simply isn't wired.
    """
    url = url or os.environ.get(ENV_URL)
    if not url:
        raise ValueError(
            f"no embedder endpoint: set {ENV_URL} or pass url= (the plugin ships none by design)"
        )

    def embed(text: str) -> list[float]:
        body = json.dumps({"input": text, "model": model}).encode()
        req = urllib.request.Request(
            url, data=body, headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.load(resp)["data"][0]["embedding"]

    return embed

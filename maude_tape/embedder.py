"""Optional BYO embedder — an OpenAI-style /v1/embeddings client for semantic recall.

The plugin ships NO embedding service and NO default endpoint. A sovereign installer who
already runs one points `MAUDE_TAPE_EMBED_URL` at it (or passes url=); without it, semantic
recall stays quiet and the tape runs sqlite-only. Uses stdlib urllib — brings nothing of its own.
"""
from __future__ import annotations

import json
import os
import urllib.request
from typing import Callable

ENV_URL = "MAUDE_TAPE_EMBED_URL"


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

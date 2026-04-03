# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Shared utilities for Maude MCP servers."""

import logging
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import yaml

logger = logging.getLogger(__name__)


def load_credentials(section: str | None = None) -> dict[str, Any]:
    """Load credentials from ~/.credentials/secrets.yaml.

    Supports MAUDE_CREDENTIALS_PATH env var override for autonomous LXC
    deployments where credentials are at a non-default location.

    Args:
        section: Optional section name to return (e.g., 'proxmox', 'unifi').
                 If None, returns entire credentials dict.

    Returns:
        Credentials dictionary or section.

    Raises:
        FileNotFoundError: If credentials file doesn't exist.
        KeyError: If section doesn't exist in credentials.
    """
    default_path = str(Path.home() / ".credentials" / "secrets.yaml")
    creds_path = Path(os.environ.get("MAUDE_CREDENTIALS_PATH", default_path))

    if not creds_path.exists():
        raise FileNotFoundError(f"Credentials file not found: {creds_path}")

    creds = yaml.safe_load(creds_path.read_text()) or {}

    if section is None:
        return creds

    if section not in creds:
        raise KeyError(f"Section '{section}' not found in credentials file")

    return creds[section]


_DEFAULT_DB_HOST = "localhost"
_DEFAULT_QDRANT_HOST = "localhost"
_DEFAULT_VLLM_HOST = ""


def resolve_db_host() -> str:
    """Resolve PostgreSQL host from env var, credentials, or default.

    Priority: MAUDE_DB_HOST env var > database.postgres.host in secrets.yaml > default.
    """
    env = os.environ.get("MAUDE_DB_HOST", "")
    if env:
        return env
    try:
        creds = load_credentials()
        host = creds.get("database", {}).get("postgres", {}).get("host", "")
        if host:
            return host
        logger.warning(
            "No database.postgres.host in secrets.yaml and MAUDE_DB_HOST not set — "
            "falling back to default %s. Set MAUDE_DB_HOST for non-default sites.",
            _DEFAULT_DB_HOST,
        )
        return _DEFAULT_DB_HOST
    except Exception:
        logger.warning(
            "Failed to load credentials — falling back to default DB host %s",
            _DEFAULT_DB_HOST,
        )
        return _DEFAULT_DB_HOST


_DEFAULT_REDIS_HOST = "localhost"


def resolve_redis_host() -> str:
    """Resolve Redis host from env var, credentials, or default.

    Priority: MAUDE_REDIS_HOST env var > redis.host in secrets.yaml > default.
    """
    env = os.environ.get("MAUDE_REDIS_HOST", "")
    if env:
        return env
    try:
        creds = load_credentials()
        host = creds.get("redis", {}).get("host", "")
        if host:
            return host
        logger.warning(
            "No redis.host in secrets.yaml and MAUDE_REDIS_HOST not set — "
            "falling back to default %s. Set MAUDE_REDIS_HOST for non-default sites.",
            _DEFAULT_REDIS_HOST,
        )
        return _DEFAULT_REDIS_HOST
    except Exception:
        logger.warning(
            "Failed to load credentials — falling back to default Redis host %s",
            _DEFAULT_REDIS_HOST,
        )
        return _DEFAULT_REDIS_HOST


_DEFAULT_EMBEDDER_HOSTS = ["localhost:8001", "localhost:8001"]


def resolve_infra_hosts() -> dict[str, Any]:
    """Resolve infrastructure hosts for DB, Qdrant, vLLM, and Embedder.

    Each key checks its env var first, then credentials, then default.

    Returns:
        Dict with keys "db", "qdrant", "vllm", "vllm_hosts", "embedder_hosts".
        "vllm_hosts" and "embedder_hosts" are lists for Active-Active failover.
    """
    db = os.environ.get("MAUDE_DB_HOST", "")
    qdrant = os.environ.get("MAUDE_QDRANT_HOST", "")
    vllm = os.environ.get("MAUDE_VLLM_HOST", "")

    # Multi-host: MAUDE_VLLM_HOSTS env var (comma-separated)
    vllm_hosts_env = os.environ.get("MAUDE_VLLM_HOSTS", "")
    # Multi-host: MAUDE_EMBEDDER_HOSTS env var (comma-separated)
    embedder_hosts_env = os.environ.get("MAUDE_EMBEDDER_HOSTS", "")

    try:
        creds = load_credentials() or {}
    except Exception:
        creds = {}

    if not db:
        db = creds.get("database", {}).get("postgres", {}).get("host", _DEFAULT_DB_HOST)
    if not qdrant:
        qdrant = creds.get("qdrant", {}).get("host", _DEFAULT_QDRANT_HOST)
    if not vllm:
        vllm = creds.get("vllm", {}).get("host", _DEFAULT_VLLM_HOST)

    # Build vllm_hosts list: env var > secrets.yaml hosts > wrap single host
    vllm_hosts: list[str] = []
    if vllm_hosts_env:
        vllm_hosts = [h.strip() for h in vllm_hosts_env.split(",") if h.strip()]
    else:
        hosts_from_creds = creds.get("vllm", {}).get("hosts", [])
        if hosts_from_creds:
            vllm_hosts = [str(h) for h in hosts_from_creds]
        elif vllm:
            vllm_hosts = [vllm]

    # Build embedder_hosts list: env var > secrets.yaml > defaults (both GPU machines)
    embedder_hosts: list[str] = []
    if embedder_hosts_env:
        embedder_hosts = [h.strip() for h in embedder_hosts_env.split(",") if h.strip()]
    else:
        hosts_from_creds = creds.get("embedder", {}).get("hosts", [])
        if hosts_from_creds:
            embedder_hosts = [str(h) for h in hosts_from_creds]
        else:
            embedder_hosts = list(_DEFAULT_EMBEDDER_HOSTS)

    return {
        "db": db,
        "qdrant": qdrant,
        "vllm": vllm,
        "vllm_hosts": vllm_hosts,
        "embedder_hosts": embedder_hosts,
    }


def pg_pool_kwargs(
    db_host: str = "",
    database: str = "agent",
    min_size: int = 1,
    max_size: int = 3,
) -> dict[str, Any]:
    """Build kwargs dict for ``asyncpg.create_pool()``.

    Args:
        db_host: PostgreSQL host override.  Empty string resolves via
            :func:`resolve_db_host`.
        database: Database name.
        min_size: Minimum pool connections.
        max_size: Maximum pool connections.

    Returns:
        Dict suitable for ``asyncpg.create_pool(**kwargs)``.

    Raises:
        FileNotFoundError: If credentials file is missing.
        KeyError: If ``database`` section is missing from credentials.
    """
    host = db_host or resolve_db_host()
    db_creds = load_credentials("database")["postgres"]
    return {
        "host": host,
        "port": db_creds["port"],
        "database": database,
        "user": db_creds["user"],
        "password": db_creds["password"],
        "min_size": min_size,
        "max_size": max_size,
    }


def format_bytes(size_bytes: int) -> str:
    """Format bytes as human-readable string.

    Args:
        size_bytes: Size in bytes.

    Returns:
        Human-readable size string (e.g., "1.5 GB").
    """
    if size_bytes < 1024:
        return f"{size_bytes} B"
    elif size_bytes < 1024**2:
        return f"{size_bytes / 1024:.1f} KB"
    elif size_bytes < 1024**3:
        return f"{size_bytes / 1024**2:.1f} MB"
    elif size_bytes < 1024**4:
        return f"{size_bytes / 1024**3:.1f} GB"
    else:
        return f"{size_bytes / 1024**4:.1f} TB"


def format_timestamp(epoch: int | float | None) -> str:
    """Format Unix timestamp as ISO8601 string.

    Args:
        epoch: Unix timestamp (seconds since epoch).

    Returns:
        ISO8601 formatted string or "N/A" if None.
    """
    if epoch is None:
        return "N/A"
    return datetime.fromtimestamp(epoch, tz=timezone.utc).isoformat()


def format_uptime(seconds: int) -> str:
    """Format uptime in seconds as human-readable string.

    Args:
        seconds: Uptime in seconds.

    Returns:
        Human-readable string (e.g., "2d 5h 30m").
    """
    days, remainder = divmod(seconds, 86400)
    hours, remainder = divmod(remainder, 3600)
    minutes, _ = divmod(remainder, 60)

    parts = []
    if days:
        parts.append(f"{days}d")
    if hours:
        parts.append(f"{hours}h")
    if minutes or not parts:
        parts.append(f"{minutes}m")

    return " ".join(parts)

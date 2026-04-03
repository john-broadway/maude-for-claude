# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for maude.common — utility functions."""

from unittest.mock import patch

import pytest

from maude.daemon.common import (
    format_bytes,
    format_timestamp,
    format_uptime,
    load_credentials,
    pg_pool_kwargs,
    resolve_db_host,
    resolve_infra_hosts,
)

# ── format_bytes ─────────────────────────────────────────────────────


def test_format_bytes_zero():
    assert format_bytes(0) == "0 B"


def test_format_bytes_small():
    assert format_bytes(512) == "512 B"


def test_format_bytes_kb():
    assert format_bytes(2048) == "2.0 KB"


def test_format_bytes_mb():
    result = format_bytes(5 * 1024**2)
    assert result == "5.0 MB"


def test_format_bytes_gb():
    result = format_bytes(3 * 1024**3)
    assert result == "3.0 GB"


def test_format_bytes_tb():
    result = format_bytes(2 * 1024**4)
    assert result == "2.0 TB"


# ── format_timestamp ─────────────────────────────────────────────────


def test_format_timestamp_valid():
    # epoch 1706000000 is well into 2024 in any timezone
    result = format_timestamp(1706000000)
    assert "2024" in result


def test_format_timestamp_none():
    assert format_timestamp(None) == "N/A"


def test_format_timestamp_float():
    result = format_timestamp(1706000000.5)
    assert "2024" in result


# ── format_uptime ────────────────────────────────────────────────────


def test_format_uptime_zero():
    assert format_uptime(0) == "0m"


def test_format_uptime_minutes():
    assert format_uptime(300) == "5m"


def test_format_uptime_hours():
    result = format_uptime(7200)
    assert "2h" in result


def test_format_uptime_days():
    result = format_uptime(2 * 86400 + 3 * 3600 + 15 * 60)
    assert "2d" in result
    assert "3h" in result
    assert "15m" in result


# ── load_credentials ─────────────────────────────────────────────────


def test_load_credentials_missing_file(tmp_path):
    fake = tmp_path / "nope.yaml"
    with patch("maude.daemon.common.Path.home", return_value=tmp_path):
        with patch.dict("os.environ", {"MAUDE_CREDENTIALS_PATH": str(fake)}):
            with pytest.raises(FileNotFoundError):
                load_credentials()


def test_load_credentials_valid(tmp_path):
    creds_file = tmp_path / "secrets.yaml"
    creds_file.write_text("database:\n  postgres:\n    host: localhost\n")
    with patch.dict("os.environ", {"MAUDE_CREDENTIALS_PATH": str(creds_file)}):
        result = load_credentials()
    assert result["database"]["postgres"]["host"] == "localhost"


def test_load_credentials_section(tmp_path):
    creds_file = tmp_path / "secrets.yaml"
    creds_file.write_text("database:\n  postgres:\n    host: localhost\n")
    with patch.dict("os.environ", {"MAUDE_CREDENTIALS_PATH": str(creds_file)}):
        result = load_credentials("database")
    assert "postgres" in result


def test_load_credentials_missing_section(tmp_path):
    creds_file = tmp_path / "secrets.yaml"
    creds_file.write_text("database:\n  postgres:\n    host: x\n")
    with patch.dict("os.environ", {"MAUDE_CREDENTIALS_PATH": str(creds_file)}):
        with pytest.raises(KeyError, match="nope"):
            load_credentials("nope")


# ── resolve_db_host ─────────────────────────────────────────────────


def test_resolve_db_host_from_credentials(tmp_path):
    creds_file = tmp_path / "secrets.yaml"
    creds_file.write_text("database:\n  postgres:\n    host: 192.168.1.99\n")
    with patch.dict("os.environ", {"MAUDE_CREDENTIALS_PATH": str(creds_file), "MAUDE_DB_HOST": ""}):
        result = resolve_db_host()
    assert result == "192.168.1.99"


def test_resolve_db_host_env_override(tmp_path):
    creds_file = tmp_path / "secrets.yaml"
    creds_file.write_text("database:\n  postgres:\n    host: 192.168.1.99\n")
    env = {"MAUDE_CREDENTIALS_PATH": str(creds_file), "MAUDE_DB_HOST": "1.2.3.4"}
    with patch.dict("os.environ", env):
        result = resolve_db_host()
    assert result == "1.2.3.4"


def test_resolve_db_host_fallback():
    with patch.dict("os.environ", {"MAUDE_DB_HOST": ""}):
        with patch(
            "maude.daemon.common.load_credentials", side_effect=FileNotFoundError("no file")
        ):
            result = resolve_db_host()
    assert result == "localhost"


# ── resolve_infra_hosts ─────────────────────────────────────────────


def test_resolve_infra_hosts_from_credentials(tmp_path):
    creds_file = tmp_path / "secrets.yaml"
    creds_file.write_text(
        "database:\n  postgres:\n    host: 192.168.1.1\n"
        "qdrant:\n  host: 192.168.1.2\n"
        "vllm:\n  host: 192.168.1.3\n"
    )
    with patch.dict(
        "os.environ",
        {
            "MAUDE_CREDENTIALS_PATH": str(creds_file),
            "MAUDE_DB_HOST": "",
            "MAUDE_QDRANT_HOST": "",
            "MAUDE_VLLM_HOST": "",
        },
    ):
        result = resolve_infra_hosts()
    assert result["db"] == "192.168.1.1"
    assert result["qdrant"] == "192.168.1.2"
    assert result["vllm"] == "192.168.1.3"


def test_resolve_infra_hosts_env_overrides():
    with patch.dict(
        "os.environ",
        {
            "MAUDE_DB_HOST": "db.test",
            "MAUDE_QDRANT_HOST": "qdrant.test",
            "MAUDE_VLLM_HOST": "vllm.test",
        },
    ):
        result = resolve_infra_hosts()
    assert result["db"] == "db.test"
    assert result["qdrant"] == "qdrant.test"
    assert result["vllm"] == "vllm.test"


def test_resolve_infra_hosts_fallback():
    with patch.dict(
        "os.environ",
        {
            "MAUDE_DB_HOST": "",
            "MAUDE_QDRANT_HOST": "",
            "MAUDE_VLLM_HOST": "",
        },
    ):
        with patch(
            "maude.daemon.common.load_credentials", side_effect=FileNotFoundError("no file")
        ):
            result = resolve_infra_hosts()
    assert result["db"] == "localhost"
    assert result["qdrant"] == "localhost"
    assert result["vllm"] == ""


# ── pg_pool_kwargs ──────────────────────────────────────────────────


def test_pg_pool_kwargs_structure(tmp_path):
    creds_file = tmp_path / "secrets.yaml"
    creds_file.write_text(
        "database:\n  postgres:\n    host: localhost\n    port: 5432\n"
        "    user: support\n    password: secret\n"
    )
    with patch.dict("os.environ", {"MAUDE_CREDENTIALS_PATH": str(creds_file), "MAUDE_DB_HOST": ""}):
        kwargs = pg_pool_kwargs()
    assert kwargs["host"] == "localhost"
    assert kwargs["port"] == 5432
    assert kwargs["user"] == "support"
    assert kwargs["password"] == "secret"
    assert kwargs["database"] == "agent"
    assert kwargs["min_size"] == 1
    assert kwargs["max_size"] == 3


def test_pg_pool_kwargs_custom_host(tmp_path):
    creds_file = tmp_path / "secrets.yaml"
    creds_file.write_text(
        "database:\n  postgres:\n    port: 5432\n    user: support\n    password: pw\n"
    )
    with patch.dict("os.environ", {"MAUDE_CREDENTIALS_PATH": str(creds_file)}):
        kwargs = pg_pool_kwargs(db_host="custom.host")
    assert kwargs["host"] == "custom.host"


def test_pg_pool_kwargs_resolves_host(tmp_path):
    creds_file = tmp_path / "secrets.yaml"
    creds_file.write_text(
        "database:\n  postgres:\n    host: localhost\n    port: 5432\n"
        "    user: support\n    password: pw\n"
    )
    env = {"MAUDE_CREDENTIALS_PATH": str(creds_file), "MAUDE_DB_HOST": "9.9.9.9"}
    with patch.dict("os.environ", env):
        kwargs = pg_pool_kwargs()
    assert kwargs["host"] == "9.9.9.9"


def test_pg_pool_kwargs_custom_database(tmp_path):
    creds_file = tmp_path / "secrets.yaml"
    creds_file.write_text(
        "database:\n  postgres:\n    port: 5432\n    user: support\n    password: pw\n"
    )
    with patch.dict("os.environ", {"MAUDE_CREDENTIALS_PATH": str(creds_file)}):
        kwargs = pg_pool_kwargs(db_host="x", database="plc")
    assert kwargs["database"] == "plc"


def test_pg_pool_kwargs_raises_on_missing_creds():
    with patch("maude.daemon.common.load_credentials", side_effect=FileNotFoundError("no file")):
        with pytest.raises(FileNotFoundError):
            pg_pool_kwargs(db_host="x")


def test_pg_pool_kwargs_raises_on_missing_section():
    with patch("maude.daemon.common.load_credentials", side_effect=KeyError("database")):
        with pytest.raises(KeyError):
            pg_pool_kwargs(db_host="x")

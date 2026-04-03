# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Tests for maude.kill_switch — file-based read-only flag."""

import pytest

from maude.daemon.kill_switch import KillSwitch


@pytest.fixture
def ks(tmp_path, monkeypatch):
    """KillSwitch using a temp directory instead of /var/lib."""
    monkeypatch.setattr("maude.daemon.kill_switch.KILL_SWITCH_DIR", tmp_path)
    return KillSwitch(project="test-project")


def test_inactive_by_default(ks):
    assert not ks.active


def test_activate_creates_flag(ks):
    ks.activate("testing")
    assert ks.active
    assert ks.flag_path.exists()
    assert ks.flag_path.read_text() == "testing"


def test_deactivate_removes_flag(ks):
    ks.activate("testing")
    ks.deactivate()
    assert not ks.active
    assert not ks.flag_path.exists()


def test_deactivate_noop_when_inactive(ks):
    ks.deactivate()  # Should not raise
    assert not ks.active


def test_check_or_raise_when_active(ks):
    ks.activate("blocked")
    with pytest.raises(PermissionError, match="Kill switch active"):
        ks.check_or_raise()


def test_check_or_raise_when_inactive(ks):
    ks.check_or_raise()  # Should not raise


def test_status_dict_inactive(ks):
    status = ks.status()
    assert status["project"] == "test-project"
    assert status["active"] is False
    assert status["reason"] == ""


def test_status_dict_active(ks):
    ks.activate("maintenance")
    status = ks.status()
    assert status["active"] is True
    assert status["reason"] == "maintenance"

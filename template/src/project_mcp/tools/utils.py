# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Shared utilities for {{PROJECT_TITLE}} MCP tools."""

import json


def _format(data: dict | list) -> str:
    return json.dumps(data, indent=2, default=str)

# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

# Maude DB — JSON Formatting
#          Claude (Anthropic) <noreply@anthropic.com>
"""Shared JSON formatting for MCP tool responses.

Replaces the duplicated ``_format()`` function across 5+ modules.
"""

import json
from typing import Any


def format_json(data: dict[str, Any] | list[Any]) -> str:
    """Format data as pretty-printed JSON for MCP tool responses.

    Args:
        data: Dictionary or list to serialize.

    Returns:
        JSON string with 2-space indent and ``str`` fallback for
        non-serializable values (datetimes, etc.).
    """
    return json.dumps(data, indent=2, default=str)

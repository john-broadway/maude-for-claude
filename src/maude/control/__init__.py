# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0
# Version: 1.0
# Created: 2026-03-29 MST
# Authors: John Broadway, Claude (Anthropic)

"""Control plane — the operator of last resort.

When the health loop can't fix it and the Room Agent can't reason
through it, the control plane gives the human operator superpowers.

Fleet health, session persistence, disk audit, venv validation,
git status sweep, and cross-room briefings — all from one place.

    from maude.control import register_control_tools
"""

from maude.control.tools import register_control_tools as register_control_tools

__all__ = ["register_control_tools"]

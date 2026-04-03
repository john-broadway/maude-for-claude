# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Backward compatibility — audit moved to maude.memory.audit (The Operators).

The audit trail is the Operators' job — the tattoo scribes who make everything
permanent. This shim re-exports for backward compat.
"""

from maude.memory.audit import *  # noqa: F401,F403

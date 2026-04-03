# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Memory + audit — the permanent record.

She remembers everything. Don't test her.

Tier 1:   Markdown files (KnowledgeManager)
Tier 1.5: SQLite local store (LocalStore)
Tier 2:   PostgreSQL shared memory (MemoryStore)
Tier 3:   Qdrant vector search (MemoryStore)
Audit:    AuditLogger — every tool call goes in the book
"""

# Audit — the permanent record
from maude.memory.audit import AuditEntry as AuditEntry
from maude.memory.audit import AuditLogger as AuditLogger
from maude.memory.audit import active_caller as active_caller
from maude.memory.audit import elapsed as elapsed
from maude.memory.audit import timed as timed
from maude.memory.consolidator import (
    ConsolidationResult as ConsolidationResult,
)
from maude.memory.consolidator import (
    MemoryConsolidator as MemoryConsolidator,
)
from maude.memory.knowledge import KnowledgeManager as KnowledgeManager
from maude.memory.local_store import LocalStore as LocalStore
from maude.memory.store import Memory as Memory
from maude.memory.store import MemoryStore as MemoryStore
from maude.memory.sync import SyncWorker as SyncWorker

__all__ = [
    "AuditEntry",
    "AuditLogger",
    "ConsolidationResult",
    "KnowledgeManager",
    "LocalStore",
    "Memory",
    "MemoryConsolidator",
    "MemoryStore",
    "SyncWorker",
    "active_caller",
    "elapsed",
    "timed",
]

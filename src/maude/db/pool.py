# Maude DB — Lazy Connection Pool
# Authors: John Broadway <271895126+john-broadway@users.noreply.github.com>
#          Claude (Anthropic) <noreply@anthropic.com>
# Version: 1.0.0
# Updated: 2026-02-13
"""Lazy-initialized asyncpg connection pool.

Replaces the duplicated ``_ensure_pool()`` pattern across 9 modules.
Two modes: strict (propagates errors) and lenient (returns None).
"""

import asyncio
import logging
import time

import asyncpg

from maude.daemon.common import pg_pool_kwargs

logger = logging.getLogger(__name__)


class LazyPool:
    """Lazy-initialized asyncpg connection pool.

    Args:
        database: PostgreSQL database name.
        db_host: Override host. Empty resolves via ``resolve_db_host()``.
        min_size: Minimum pool connections.
        max_size: Maximum pool connections.
        suppress_errors: If True, log and return None on connection failure.
            If False, propagate the exception (strict mode).
        retry_cooldown: Seconds to wait after a failed connection before
            retrying. Prevents hammering a down PG every health loop cycle.
    """

    def __init__(
        self,
        database: str = "agent",
        db_host: str = "",
        min_size: int = 1,
        max_size: int = 3,
        *,
        suppress_errors: bool = True,
        retry_cooldown: float = 30.0,
    ) -> None:
        self._database = database
        self._db_host = db_host
        self._min_size = min_size
        self._max_size = max_size
        self._suppress_errors = suppress_errors
        self._retry_cooldown = retry_cooldown
        self._last_failure: float = 0.0
        self._pool: asyncpg.Pool | None = None
        self._lock = asyncio.Lock()

    async def get(self) -> asyncpg.Pool | None:
        """Get the connection pool, creating it lazily.

        Returns:
            The pool, or None if ``suppress_errors`` is True and creation failed.

        Raises:
            Exception: If ``suppress_errors`` is False and pool creation fails.
        """
        if self._pool is not None:
            return self._pool
        async with self._lock:
            # Double-check after acquiring lock
            if self._pool is not None:
                return self._pool
            elapsed = time.monotonic() - self._last_failure
            if self._last_failure and elapsed < self._retry_cooldown:
                return None
            try:
                kwargs = pg_pool_kwargs(
                    db_host=self._db_host,
                    database=self._database,
                    min_size=self._min_size,
                    max_size=self._max_size,
                )
                self._pool = await asyncpg.create_pool(**kwargs)
                self._last_failure = 0.0
                return self._pool
            except Exception:
                self._last_failure = time.monotonic()
                if not self._suppress_errors:
                    raise
                logger.warning(
                    "LazyPool(%s): PostgreSQL unavailable",
                    self._database,
                    exc_info=True,
                )
                return None

    async def close(self) -> None:
        """Close the connection pool."""
        if self._pool is not None:
            await self._pool.close()
            self._pool = None


class PoolRegistry:
    """Deduplicate LazyPool instances by (database, db_host) key.

    Components call ``PoolRegistry.get()`` instead of constructing
    ``LazyPool()`` directly. The first call for a given key creates
    the pool; subsequent calls return the same instance. This is
    synchronous because ``LazyPool.__init__`` does no I/O.

    Usage::

        db = PoolRegistry.get("agent")
        pool = await db.get()
        async with pool.acquire() as conn:
            ...
    """

    _pools: dict[tuple[str, str], LazyPool] = {}

    @classmethod
    def get(
        cls,
        database: str = "agent",
        db_host: str = "",
        min_size: int = 1,
        max_size: int = 3,
        suppress_errors: bool = True,
        retry_cooldown: float = 30.0,
    ) -> LazyPool:
        """Get or create a shared LazyPool for the given database/host.

        Args:
            database: PostgreSQL database name.
            db_host: Override host. Empty resolves via ``resolve_db_host()``.
            min_size: Minimum pool connections (first call only).
            max_size: Maximum pool connections (first call only).
            suppress_errors: Lenient mode (first call only).
            retry_cooldown: Seconds between retries (first call only).

        Returns:
            Shared LazyPool instance.
        """
        key = (database, db_host)
        if key not in cls._pools:
            cls._pools[key] = LazyPool(
                database=database,
                db_host=db_host,
                min_size=min_size,
                max_size=max_size,
                suppress_errors=suppress_errors,
                retry_cooldown=retry_cooldown,
            )
        return cls._pools[key]

    @classmethod
    async def close_all(cls) -> None:
        """Close all registered pools and clear the registry."""
        for pool in cls._pools.values():
            await pool.close()
        cls._pools.clear()

    @classmethod
    def pool_count(cls) -> int:
        """Return the number of registered pools."""
        return len(cls._pools)

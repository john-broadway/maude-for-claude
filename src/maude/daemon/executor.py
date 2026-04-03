# Maude - Autonomous Agent Framework
# Copyright (c) 2026 John Broadway
# Licensed under the Apache License, Version 2.0

"""Command executors for Maude MCP servers.

Provides SSHResult (shared data type) and two executor implementations:
- SSHExecutor: remote command execution via asyncssh
- LocalExecutor: local subprocess execution

Both implement the same interface: run(command) -> SSHResult, close() -> None.
Rooms choose based on executor_mode in config.

         Claude (Anthropic) <noreply@anthropic.com>
"""

import asyncio
import logging
from dataclasses import dataclass
from pathlib import Path

try:
    import asyncssh
except ImportError:
    asyncssh = None  # type: ignore[assignment]

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class SSHResult:
    """Result of a command execution (local or remote)."""

    stdout: str
    stderr: str
    exit_code: int

    @property
    def ok(self) -> bool:
        return self.exit_code == 0

    def to_dict(self) -> dict[str, str | int]:
        return {
            "stdout": self.stdout,
            "stderr": self.stderr,
            "exit_code": self.exit_code,
        }


class SSHExecutor:
    """Execute commands on a remote LXC via SSH.

    Uses asyncssh with ed25519 machine keys.
    Connections are lazy-initialized and reused.

    Args:
        host: SSH alias or IP address (e.g., "my-service", "localhost").
        username: SSH username. Defaults to "root".
        timeout: Command timeout in seconds. Defaults to 30.
        connect_timeout: Connection liveness check timeout. Defaults to 10.
    """

    def __init__(
        self,
        host: str,
        username: str = "root",
        timeout: float = 30.0,
        connect_timeout: float = 10.0,
    ) -> None:
        if asyncssh is None:
            raise ImportError(
                "asyncssh is required for SSH execution. Install with: pip install the-maude[ssh]"
            )
        self.host = host
        self.username = username
        self.timeout = timeout
        self.connect_timeout = connect_timeout
        self._conn: "asyncssh.SSHClientConnection | None" = None
        self._lock = asyncio.Lock()

    async def _ensure_connection(self) -> "asyncssh.SSHClientConnection":
        """Lazy-initialize SSH connection with reuse."""
        if self._conn is not None:
            try:
                # Test if connection is still alive
                result = await asyncio.wait_for(
                    self._conn.run("echo ok", check=False),
                    timeout=self.connect_timeout,
                )
                if result.exit_status == 0:
                    return self._conn
            except Exception:
                self._conn = None

        async with self._lock:
            # Double-check after acquiring lock
            if self._conn is not None:
                return self._conn

            ssh_key = Path.home() / ".ssh" / "id_ed25519"
            self._conn = await asyncio.wait_for(
                asyncssh.connect(
                    self.host,
                    username=self.username,
                    client_keys=[str(ssh_key)],
                    known_hosts=None,  # Internal network, managed keys
                ),
                timeout=self.connect_timeout,
            )
            logger.info("SSH connected to %s@%s", self.username, self.host)
            return self._conn

    async def run(self, command: str, timeout: float | None = None) -> SSHResult:
        """Execute a command on the remote host.

        Args:
            command: Shell command to execute.
            timeout: Override default timeout for this command.

        Returns:
            SSHResult with stdout, stderr, and exit code.
        """
        effective_timeout = self.timeout if timeout is None else timeout
        conn = await self._ensure_connection()

        try:
            result = await asyncio.wait_for(
                conn.run(command, check=False),
                timeout=effective_timeout,
            )
            return SSHResult(
                stdout=str(result.stdout).strip() if result.stdout else "",
                stderr=str(result.stderr).strip() if result.stderr else "",
                exit_code=result.exit_status or 0,
            )
        except asyncio.TimeoutError:
            return SSHResult(
                stdout="",
                stderr=f"Command timed out after {effective_timeout}s",
                exit_code=-1,
            )
        except Exception as e:
            # Connection may have died — reset for next attempt
            self._conn = None
            return SSHResult(
                stdout="",
                stderr=f"SSH error: {e}",
                exit_code=-1,
            )

    async def close(self) -> None:
        """Close the SSH connection."""
        if self._conn is not None:
            self._conn.close()
            self._conn = None


class LocalExecutor:
    """Execute commands locally via subprocess.

    Same interface as SSHExecutor: async run() returns SSHResult,
    async close() is a no-op.

    Args:
        timeout: Default command timeout in seconds.
    """

    def __init__(self, timeout: float = 30.0) -> None:
        self.timeout = timeout

    async def run(self, command: str, timeout: float | None = None) -> SSHResult:
        """Execute a shell command locally.

        Args:
            command: Shell command to execute.
            timeout: Override default timeout for this command.

        Returns:
            SSHResult with stdout, stderr, and exit code.
        """
        effective_timeout = self.timeout if timeout is None else timeout

        proc = None
        try:
            proc = await asyncio.create_subprocess_shell(
                command,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout_bytes, stderr_bytes = await asyncio.wait_for(
                proc.communicate(),
                timeout=effective_timeout,
            )
            return SSHResult(
                stdout=stdout_bytes.decode().strip() if stdout_bytes else "",
                stderr=stderr_bytes.decode().strip() if stderr_bytes else "",
                exit_code=proc.returncode or 0,
            )
        except asyncio.TimeoutError:
            if proc and proc.returncode is None:
                proc.kill()
                await proc.wait()
            return SSHResult(
                stdout="",
                stderr=f"Command timed out after {effective_timeout}s",
                exit_code=-1,
            )
        except Exception as e:
            return SSHResult(
                stdout="",
                stderr=f"Local exec error: {e}",
                exit_code=-1,
            )

    async def close(self) -> None:
        """No-op — no persistent connection to close."""

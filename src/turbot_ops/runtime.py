"""Low-level runtime helpers for process execution and filesystem state."""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import time
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import TypeVar

from .logging_utils import get_logger

LOGGER = get_logger(__name__)
T = TypeVar("T")


class CommandError(RuntimeError):
    """Raised when a subprocess fails."""


@dataclass(frozen=True)
class CompletedCommand:
    """Lightweight subprocess result used across the service layer."""

    returncode: int
    stdout: str


def repo_root() -> Path:
    """Return the repository root by searching for a pyproject.toml marker."""
    current = Path(__file__).resolve().parent
    for parent in (current, *current.parents):
        if (parent / "pyproject.toml").is_file():
            return parent
    # Fallback to the established N-parents if no marker is found.
    return Path(__file__).resolve().parents[2]


def runtime_env(extra: Mapping[str, str] | None = None) -> dict[str, str]:
    """Build a runtime environment that prefers vendored binaries on PATH."""
    vendor_bin = repo_root() / "vendor" / "bin"
    path_parts = [str(vendor_bin)] if vendor_bin.is_dir() else []
    path_parts.append(os.environ.get("PATH", ""))
    env = dict(os.environ)
    env["PATH"] = ":".join(part for part in path_parts if part)
    if extra:
        env.update(extra)
    return env


def run_command(
    args: Iterable[str],
    *,
    cwd: Path | None = None,
    check: bool = True,
    capture_output: bool = False,
    env: Mapping[str, str] | None = None,
) -> CompletedCommand:
    """Execute a subprocess and return its captured result."""
    command = tuple(args)
    LOGGER.debug(
        "running command", extra={"command": " ".join(command), "cwd": str(cwd) if cwd else ""}
    )
    try:
        completed = subprocess.run(
            list(command),
            cwd=str(cwd) if cwd else None,
            env=runtime_env(env),
            text=True,
            capture_output=capture_output,
            check=False,
        )
    except OSError as exc:
        LOGGER.error(
            "command execution failed",
            extra={"command": " ".join(command), "cwd": str(cwd) if cwd else ""},
        )
        raise CommandError(f"unable to execute command: {' '.join(command)}") from exc
    LOGGER.debug(
        "command completed",
        extra={"command": " ".join(command), "returncode": completed.returncode},
    )
    if check and completed.returncode != 0:
        stderr = completed.stderr or completed.stdout or ""
        LOGGER.error(
            "command failed",
            extra={"command": " ".join(command), "returncode": completed.returncode},
        )
        raise CommandError(
            f"command failed ({completed.returncode}): {' '.join(command)}\n{stderr.strip()}"
        )
    return CompletedCommand(returncode=completed.returncode, stdout=completed.stdout or "")


def command_exists(name: str) -> bool:
    """Return whether a command is available in the runtime environment."""
    return shutil.which(name, path=runtime_env().get("PATH")) is not None


def ensure_commands(names: Iterable[str]) -> None:
    """Raise when any required command is unavailable."""
    missing = tuple(name for name in names if not command_exists(name))
    if missing:
        LOGGER.error("missing commands", extra={"missing": ",".join(missing)})
        raise CommandError(f"missing commands: {', '.join(missing)}")


def wait_for_tcp(host: str, port: int, timeout_seconds: int) -> bool:
    """Wait until a TCP endpoint becomes reachable or the timeout expires."""
    LOGGER.info(
        "waiting for tcp endpoint",
        extra={"host": host, "port": port, "timeout_seconds": timeout_seconds},
    )
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.settimeout(1.0)
            if sock.connect_ex((host, port)) == 0:
                LOGGER.info("tcp endpoint reachable", extra={"host": host, "port": port})
                return True
        time.sleep(1)
    LOGGER.warning(
        "tcp endpoint wait timed out",
        extra={"host": host, "port": port, "timeout_seconds": timeout_seconds},
    )
    return False


def ensure_dir(path: Path) -> Path:
    """Create a directory tree if needed and return the resulting path."""
    path.mkdir(parents=True, exist_ok=True)
    LOGGER.debug("ensured directory", extra={"path": str(path)})
    return path


def write_text(path: Path, content: str, *, mode: int = 0o600) -> None:
    """Write UTF-8 text to disk with restrictive permissions, creating parents when needed."""
    ensure_dir(path.parent)
    path.write_text(content, encoding="utf-8")
    path.chmod(mode)
    LOGGER.debug(
        "wrote text file",
        extra={"path": str(path), "bytes": len(content.encode("utf-8")), "mode": oct(mode)},
    )


def replace_symlink(target: Path, link_path: Path, *, relative: bool = False) -> None:
    """Atomically replace a symlink, refusing to overwrite non-empty directories."""
    ensure_dir(link_path.parent)
    tmp_link = link_path.parent / f"{link_path.name}.tmp"
    if tmp_link.exists() or tmp_link.is_symlink():
        tmp_link.unlink()
    symlink_target = Path(target.name) if relative else target
    tmp_link.symlink_to(symlink_target)
    if link_path.is_symlink() or link_path.is_file():
        link_path.unlink()
    elif link_path.is_dir():
        try:
            link_path.rmdir()
        except OSError as exc:
            tmp_link.unlink(missing_ok=True)
            raise CommandError(f"refusing to replace non-empty directory: {link_path}") from exc
    tmp_link.replace(link_path)
    LOGGER.info(
        "updated symlink", extra={"link_path": str(link_path), "target": str(symlink_target)}
    )


def retry_operation[T](
    operation: Callable[[], T],
    *,
    attempts: int,
    delay_seconds: float,
    description: str,
    retriable_exceptions: tuple[type[Exception], ...] = (CommandError,),
) -> T:
    """Retry an operation a bounded number of times before surfacing the last error."""
    last_error: Exception | None = None
    for attempt in range(1, attempts + 1):
        try:
            return operation()
        except retriable_exceptions as exc:
            last_error = exc
            LOGGER.warning(
                "operation failed",
                extra={"description": description, "attempt": attempt, "attempts": attempts},
            )
            if attempt == attempts:
                break
            time.sleep(delay_seconds)
    if last_error is None:
        raise CommandError(f"{description} failed without an exception")
    raise CommandError(f"{description} failed after {attempts} attempts") from last_error

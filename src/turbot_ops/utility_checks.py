"""Dependency validation helpers for host and Compose workflows."""

from __future__ import annotations

import os
from pathlib import Path

from .logging_utils import get_logger
from .runtime import CommandError, command_exists
from .utility_support import parse_arg_value

LOGGER = get_logger(__name__)


class DependencyChecker:
    """Validate prerequisite commands and files for a named profile."""

    def __init__(self, profile: str) -> None:
        self.profile = profile

    @classmethod
    def from_args(cls, args: list[str]) -> DependencyChecker:
        """Construct a dependency checker from CLI arguments and environment."""
        profile = os.environ.get("PROFILE", "all")
        if "--profile" in args:
            profile = parse_arg_value(args, "--profile", profile)
        return cls(profile)

    def run(self) -> int:
        """Run all checks for the selected profile and report failures."""
        LOGGER.info("starting dependency check", extra={"profile": self.profile})
        failures: list[str] = []
        for name in (
            "bash",
            "awk",
            "cat",
            "cp",
            "date",
            "grep",
            "ln",
            "mkdir",
            "mv",
            "rm",
            "sed",
            "tr",
        ):
            self.need_command(name, failures)
        profile_map = {
            "common": lambda: None,
            "host": lambda: (
                tuple(
                    self.need_command(name, failures)
                    for name in ("powerpipe", "steampipe", "timeout", "pgrep", "pkill")
                ),
                self.need_one_of(("lsof", "ss"), failures),
            ),
            "compose": lambda: (
                self.need_command("docker", failures),
                self.check_home(failures),
                self.check_path(Path.home() / ".aws", "AWS config directory", failures),
            ),
            "tailpipe": lambda: (
                tuple(self.need_command(name, failures) for name in ("aws", "python3", "tailpipe")),
                self.check_home(failures),
                self.check_path(Path.home() / ".aws" / "config", "AWS shared config", failures),
            ),
            "task": lambda: self.need_command("task", failures),
            "all": lambda: tuple(
                profile_map[name]() for name in ("host", "compose", "tailpipe", "task")
            ),
        }
        if self.profile not in profile_map:
            raise CommandError(f"unsupported profile: {self.profile}")
        profile_map[self.profile]()
        if failures:
            LOGGER.warning(
                "dependency check failed",
                extra={"profile": self.profile, "failure_count": len(failures)},
            )
            raise CommandError("\n".join(failures))
        LOGGER.info("dependency check passed", extra={"profile": self.profile})
        return 0

    @staticmethod
    def need_command(name: str, failures: list[str]) -> None:
        """Append a failure when a required command is unavailable."""
        if not command_exists(name):
            failures.append(f"ERROR: missing command: {name}")

    @staticmethod
    def need_one_of(names: tuple[str, ...], failures: list[str]) -> None:
        """Append a failure unless at least one command from the set exists."""
        if not any(command_exists(name) for name in names):
            failures.append(f"ERROR: need one of: {' '.join(names)}")

    @staticmethod
    def check_home(failures: list[str]) -> None:
        """Append a failure when HOME is unreadable."""
        if not Path.home().is_dir():
            failures.append("ERROR: HOME is not set to a readable directory")

    @staticmethod
    def check_path(path: Path, label: str, failures: list[str]) -> None:
        """Append a failure when a required filesystem path is missing."""
        if not path.exists():
            failures.append(f"ERROR: missing {label}: {path}")

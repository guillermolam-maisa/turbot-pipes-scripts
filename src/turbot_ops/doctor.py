"""Readiness checks for local and Compose-backed workflows."""

from __future__ import annotations

import platform
from dataclasses import dataclass
from pathlib import Path

from .logging_utils import get_logger
from .runtime import command_exists, repo_root, run_command

LOGGER = get_logger(__name__)


@dataclass(slots=True)
class Doctor:
    """Evaluate whether the current machine is ready to run the repository."""

    def run(self) -> int:
        """Run the configured readiness checks and report any failures."""
        LOGGER.info("starting doctor checks")
        checks = self._checks()
        failures = tuple(message for ok, message in checks if not ok)
        tuple(print(message) for ok, message in checks if ok)
        tuple(print(message) for message in failures)
        LOGGER.info("doctor checks completed", extra={"failure_count": len(failures)})
        return 1 if failures else 0

    def _checks(self) -> tuple[tuple[bool, str], ...]:
        """Collect the readiness checks exposed by the doctor command."""
        root_dir = repo_root()
        platform_ok = (platform.system(), platform.machine()) in {
            ("Linux", "x86_64"),
            ("Linux", "amd64"),
        }
        docker_ok = (
            command_exists("docker")
            and run_command(("docker", "ps"), check=False, capture_output=True).returncode == 0
        )
        aws_dir = Path.home() / ".aws"
        aws_config = aws_dir / "config"
        steampipe_plugins = self._stdout_if_available(("steampipe", "plugin", "list"))
        tailpipe_plugins = self._stdout_if_available(("tailpipe", "plugin", "list"))
        powerpipe_mods = self._stdout_if_available(
            ("powerpipe", "mod", "list"), cwd=root_dir / "powerpipe"
        )
        common_checks_ok = (
            run_command(
                (
                    "bash",
                    str(root_dir / "scripts" / "check-dependencies.sh"),
                    "--profile",
                    "common",
                ),
                check=False,
            ).returncode
            == 0
        )
        return (
            *(
                (
                    command_exists(name),
                    f"{'PASS' if command_exists(name) else 'FAIL'}: command {name}",
                )
                for name in (
                    "bash",
                    "awk",
                    "curl",
                    "docker",
                    "aws",
                    "task",
                    "steampipe",
                    "powerpipe",
                    "tailpipe",
                )
            ),
            (
                platform_ok,
                (
                    f"{'PASS' if platform_ok else 'FAIL'}: supported bootstrap platform "
                    f"({platform.system()}/{platform.machine()})"
                ),
            ),
            (
                docker_ok,
                f"{'PASS' if docker_ok else 'FAIL'}: docker daemon reachable for automation",
            ),
            (aws_dir.exists(), f"{'PASS' if aws_dir.exists() else 'FAIL'}: {aws_dir} present"),
            (
                aws_config.exists(),
                f"{'PASS' if aws_config.exists() else 'FAIL'}: {aws_config} present",
            ),
            (
                "aws" in steampipe_plugins,
                (
                    f"{'PASS' if 'aws' in steampipe_plugins else 'FAIL'}: "
                    "Steampipe AWS plugin installed"
                ),
            ),
            (
                "aws" in tailpipe_plugins,
                f"{'PASS' if 'aws' in tailpipe_plugins else 'FAIL'}: Tailpipe AWS plugin installed",
            ),
            (
                "github.com/turbot/" in powerpipe_mods,
                (
                    f"{'PASS' if 'github.com/turbot/' in powerpipe_mods else 'FAIL'}: "
                    "Powerpipe mods installed"
                ),
            ),
            (
                common_checks_ok,
                (
                    "PASS: common dependency checks passed"
                    if common_checks_ok
                    else "FAIL: common dependency checks failed"
                ),
            ),
        )

    @staticmethod
    def _stdout_if_available(command: tuple[str, ...], cwd: Path | None = None) -> str:
        executable = command[0]
        if not command_exists(executable):
            return ""
        return run_command(command, cwd=cwd, capture_output=True, check=False).stdout

"""Compose-side Steampipe bootstrap and configuration generation."""

from __future__ import annotations

import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

from .config import ComposeSteampipeConfig
from .logging_utils import get_logger
from .runtime import CommandError, ensure_commands, ensure_dir, run_command, write_text
from .utility_support import slug

LOGGER = get_logger(__name__)


def _parse_aws_profiles(config_file: Path) -> tuple[tuple[str, str], ...]:
    """Read AWS shared config profiles and their regions from disk."""
    if not config_file.is_file():
        return tuple()
    profile_name = ""
    region_name = ""
    profiles: list[tuple[str, str]] = []
    for line in config_file.read_text(encoding="utf-8", errors="ignore").splitlines():
        stripped = line.strip()
        if stripped.startswith("[profile ") and stripped.endswith("]"):
            if profile_name:
                profiles.append((profile_name, region_name))
            profile_name = stripped[len("[profile ") : -1]
            region_name = ""
            continue
        if stripped.startswith("[") and stripped.endswith("]"):
            if profile_name:
                profiles.append((profile_name, region_name))
            profile_name = ""
            region_name = ""
            continue
        if profile_name and stripped.startswith("region"):
            _, _, region = stripped.partition("=")
            region_name = region.strip()
    if profile_name:
        profiles.append((profile_name, region_name))
    return tuple(profiles)


@dataclass(slots=True)
class ComposeSteampipeService:
    """Prepare and launch the Steampipe service inside Compose."""

    config: ComposeSteampipeConfig

    def run(self) -> int:
        """Write Steampipe config and start the foreground service."""
        LOGGER.info(
            "starting compose steampipe service", extra={"database_port": self.config.database_port}
        )
        ensure_commands(("steampipe",))
        ensure_dir(self.config.install_dir)
        ensure_dir(self.config.config_dir)
        ensure_dir(self.config.aws_config_dir)
        ensure_dir(Path("/tmp"))
        os.environ["AWS_SDK_LOAD_CONFIG"] = "1"
        self._sync_host_aws()
        self._seed_install_dir()
        self._write_options()
        self._write_generated_config()
        run_command(("steampipe", "service", "stop", "--force"), check=False)
        self._clear_stale_state()
        completed = subprocess.run(
            (
                "steampipe",
                "service",
                "start",
                "--foreground",
                "--database-listen",
                "network",
                "--database-port",
                str(self.config.database_port),
                "--database-password",
                self.config.database_password,
            ),
            env=os.environ.copy(),
            check=False,
            text=True,
        )
        LOGGER.info("compose steampipe service exited", extra={"returncode": completed.returncode})
        return completed.returncode

    def _sync_host_aws(self) -> None:
        if self.config.host_aws_dir.is_dir():
            shutil.copytree(
                self.config.host_aws_dir, self.config.aws_config_dir, dirs_exist_ok=True
            )

    def _seed_install_dir(self) -> None:
        plugins_dir = self.config.install_dir / "plugins"
        if self.config.seed_dir.is_dir() and not plugins_dir.exists():
            shutil.copytree(self.config.seed_dir, self.config.install_dir, dirs_exist_ok=True)

    def _write_options(self) -> None:
        write_text(
            self.config.default_options_file,
            "\n".join(
                (
                    'options "database" {',
                    f"  start_timeout = {self.config.database_start_timeout}",
                    "}",
                    "",
                    'options "plugin" {',
                    f"  start_timeout = {self.config.plugin_start_timeout}",
                    "}",
                    "",
                )
            ),
        )

    def _write_generated_config(self) -> None:
        self._clear_stale_configs()
        if self._try_write_host_config():
            return
        profiles = _parse_aws_profiles(self.config.aws_config_file)
        if not profiles:
            self._write_default_fallback_config()
            return
        self._write_profile_based_config(profiles)

    def _clear_stale_configs(self) -> None:
        for stale_name in (
            "aws.spc",
            "admin_only.spc",
            "all.spc",
            f"{self.config.all_connection_name}.spc",
            self.config.generated_config.name,
        ):
            (self.config.config_dir / stale_name).unlink(missing_ok=True)

    def _try_write_host_config(self) -> bool:
        if (
            self.config.host_config_file.is_file()
            and self.config.host_config_file.stat().st_size > 0
        ):
            content = self.config.host_config_file.read_text(encoding="utf-8", errors="ignore")
            content = content.replace(
                'plugin = "aws"', f'plugin = "aws@{self.config.aws_plugin_version}"'
            )
            content = content.replace(
                'connection "all"', f'connection "{self.config.all_connection_name}"'
            )
            if f'connection "{self.config.all_connection_name}"' not in content:
                raise CommandError(
                    "Expected aggregate connection "
                    f'"{self.config.all_connection_name}" in host Steampipe config'
                )
            write_text(self.config.generated_config, content)
            return True
        return False

    def _write_default_fallback_config(self) -> None:
        write_text(
            self.config.generated_config,
            "\n".join(
                (
                    'connection "aws" {',
                    f'  plugin = "aws@{self.config.aws_plugin_version}"',
                    "}",
                    "",
                    'connection "admin_only" {',
                    f'  plugin      = "aws@{self.config.aws_plugin_version}"',
                    '  type        = "aggregator"',
                    '  connections = ["aws"]',
                    "}",
                    "",
                    f'connection "{self.config.all_connection_name}" {{',
                    f'  plugin      = "aws@{self.config.aws_plugin_version}"',
                    '  type        = "aggregator"',
                    '  connections = ["aws"]',
                    "}",
                    "",
                )
            ),
        )

    def _write_profile_based_config(self, profiles: tuple[tuple[str, str], ...]) -> None:
        all_connections = tuple(
            (slug(profile_name), profile_name, region_name)
            for profile_name, region_name in profiles
        )
        admin_connections = tuple(
            connection
            for connection, profile_name, _ in all_connections
            if any(
                term in profile_name.lower()
                for term in ("administratoraccess", "developer-permission-set")
            )
        )
        selected_admin = admin_connections or tuple(
            connection for connection, _, _ in all_connections
        )
        connection_blocks = tuple(
            "\n".join(
                filter(
                    None,
                    (
                        f'connection "{connection}" {{',
                        f'  plugin  = "aws@{self.config.aws_plugin_version}"',
                        f'  profile = "{profile_name}"',
                        f'  regions = ["{region_name}"]' if region_name else "",
                        "}",
                        "",
                    ),
                )
            )
            for connection, profile_name, region_name in all_connections
        )
        aggregators = (
            self._aggregator_block("admin_only", selected_admin),
            self._aggregator_block(
                self.config.all_connection_name,
                tuple(connection for connection, _, _ in all_connections),
            ),
        )
        write_text(self.config.generated_config, "\n".join((*connection_blocks, *aggregators)))

    def _aggregator_block(self, name: str, connections: tuple[str, ...]) -> str:
        lines = (
            f'connection "{name}" {{',
            f'  plugin      = "aws@{self.config.aws_plugin_version}"',
            '  type        = "aggregator"',
            "  connections = [",
            *(f'    "{connection}",' for connection in connections),
            "  ]",
            "}",
            "",
        )
        return "\n".join(lines)

    def _clear_stale_state(self) -> None:
        if self.config.db_root.is_dir():
            stale_names = {
                f".s.PGSQL.{self.config.database_port}",
                f".s.PGSQL.{self.config.database_port}.lock",
                "postmaster.pid",
                "postmaster.opts",
                "postmaster.log",
            }
            for candidate in self.config.db_root.rglob("*"):
                if candidate.name in stale_names:
                    candidate.unlink(missing_ok=True)
        (self.config.install_dir / "internal" / "plugin_manager.json").unlink(missing_ok=True)

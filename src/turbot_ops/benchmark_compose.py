"""Compose-side benchmark and Powerpipe server orchestration."""

from __future__ import annotations

import os
import shutil
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

from .benchmark_common import have_primary_exports, write_compose_metadata
from .config import ComposeBenchmarkConfig, ComposePowerpipeConfig
from .logging_utils import get_logger
from .runtime import (
    CommandError,
    ensure_commands,
    ensure_dir,
    replace_symlink,
    run_command,
    wait_for_tcp,
    write_text,
)

LOGGER = get_logger(__name__)


@dataclass(slots=True)
class ComposeBenchmarkRunner:
    """Run a benchmark inside the Compose-managed runtime workspace."""

    config: ComposeBenchmarkConfig

    def run(self) -> int:
        """Execute the full Compose benchmark lifecycle and persist artifacts."""
        LOGGER.info(
            "starting compose benchmark",
            extra={"benchmark": self.config.benchmark, "search_path": self.config.search_path},
        )
        ensure_commands(("bash", "mkdir", "powerpipe", "psql", "rm", "ln", "mv", "rg", "timeout"))
        ensure_dir(self.config.config_dir)
        ensure_dir(self.config.home_dir / ".aws")
        ensure_dir(self.config.results_dir)
        ensure_dir(self.config.run_dir)
        self._sync_host_aws()
        self._prepare_runtime_workspace()
        self._write_configs()
        self._install_mods()
        write_compose_metadata(self.config)
        self._wait_for_steampipe()
        self._validate_benchmark()
        run_code = self._run_benchmark()
        final_code = 0 if self._accept_findings(run_code) else run_code
        if not have_primary_exports(self.config.run_dir):
            self._write_partial_marker(run_code)
        if run_code in (0, 2) or have_primary_exports(self.config.run_dir):
            replace_symlink(self.config.run_dir, self.config.latest_link)
        LOGGER.info(
            "compose benchmark finished",
            extra={"returncode": final_code, "run_dir": str(self.config.run_dir)},
        )
        return final_code

    def _sync_host_aws(self) -> None:
        if self.config.host_aws_dir.is_dir():
            shutil.copytree(
                self.config.host_aws_dir, self.config.home_dir / ".aws", dirs_exist_ok=True
            )

    def _prepare_runtime_workspace(self) -> None:
        if self.config.workdir.exists():
            shutil.rmtree(self.config.workdir)
        shutil.copytree(self.config.source_workdir, self.config.workdir)
        shutil.rmtree(self.config.workdir / ".powerpipe", ignore_errors=True)
        shutil.rmtree(self.config.workdir / "results", ignore_errors=True)
        (self.config.workdir / "results").symlink_to(self.config.results_dir)

    def _write_configs(self) -> None:
        connection_block = "\n".join(
            (
                'connection "steampipe" "default" {',
                f'  host     = "{self.config.database_host}"',
                f"  port     = {self.config.steampipe_database_port}",
                f'  password = "{self.config.steampipe_database_password}"',
                "}",
                "",
            )
        )
        write_text(
            self.config.connections_file,
            connection_block,
        )
        write_text(
            self.config.workspaces_file,
            "\n".join(
                (
                    f'workspace "{self.config.workspace_name}" {{',
                    '  listen            = "network"',
                    f"  port              = {self.config.port}",
                    "  watch             = false",
                    f"  query_timeout     = {self.config.query_timeout}",
                    f"  max_parallel      = {self.config.max_parallel}",
                    f"  benchmark_timeout = {self.config.benchmark_timeout}",
                    "}",
                    "",
                )
            ),
        )

    def _install_mods(self) -> None:
        if self.config.install_mods:
            run_command(
                ("powerpipe", "mod", "install", "--pull", self.config.mod_pull),
                cwd=self.config.workdir,
            )

    def _wait_for_steampipe(self) -> None:
        if not wait_for_tcp("steampipe", self.config.steampipe_database_port, 60):
            raise CommandError("Steampipe is not reachable")
        deadline = time.time() + 60
        while time.time() < deadline:
            query = (
                "select count(*) from information_schema.tables where table_name = 'aws_account';"
            )
            result = run_command(
                ("psql", self.config.database_url, "-Atqc", query), capture_output=True, check=False
            )
            if result.stdout.strip().isdigit() and int(result.stdout.strip()) > 0:
                return
            time.sleep(2)
        raise CommandError("Steampipe backend did not expose aws_account within 60 seconds")

    def _validate_benchmark(self) -> None:
        run_command(
            (
                "powerpipe",
                "benchmark",
                "show",
                self.config.benchmark,
                "--workspace",
                self.config.workspace_name,
                "--mod-location",
                str(self.config.workdir),
            )
        )

    def _run_benchmark(self) -> int:
        LOGGER.info(
            "running compose benchmark command",
            extra={
                "benchmark": self.config.benchmark,
                "workspace": self.config.workspace_name,
                "search_path": self.config.search_path,
            },
        )
        stdout_log = self.config.run_dir / "benchmark.stdout.log"
        export_dir = Path("results") / self.config.run_dir.name
        with stdout_log.open("w", encoding="utf-8") as handle:
            completed = subprocess.run(
                (
                    "timeout",
                    "--foreground",
                    "--signal=INT",
                    "--kill-after=30",
                    str(self.config.benchmark_timeout),
                    "powerpipe",
                    "benchmark",
                    "run",
                    self.config.benchmark,
                    "--workspace",
                    self.config.workspace_name,
                    "--mod-location",
                    str(self.config.workdir),
                    "--search-path",
                    self.config.search_path,
                    "--max-parallel",
                    str(self.config.max_parallel),
                    "--query-timeout",
                    str(self.config.query_timeout),
                    "--benchmark-timeout",
                    str(self.config.benchmark_timeout),
                    "--progress=true",
                    "--output",
                    "brief",
                    "--export",
                    str(export_dir / "benchmark.json"),
                    "--export",
                    str(export_dir / "benchmark.html"),
                    "--export",
                    str(export_dir / "benchmark.md"),
                    "--export",
                    str(export_dir / "benchmark.pps"),
                ),
                stdout=handle,
                stderr=handle,
                env=os.environ.copy(),
                check=False,
                text=True,
                cwd=self.config.workdir,
            )
        return completed.returncode

    def _accept_findings(self, run_code: int) -> bool:
        if not self.config.accept_findings or run_code == 0:
            return False
        if not have_primary_exports(self.config.run_dir):
            return False
        stdout = (self.config.run_dir / "benchmark.stdout.log").read_text(
            encoding="utf-8", errors="ignore"
        )
        return "ERROR:" not in stdout

    def _write_partial_marker(self, run_code: int) -> None:
        write_text(
            self.config.run_dir / "partial-artifacts.txt",
            "\n".join(
                (
                    "Benchmark did not complete cleanly.",
                    f"Exit code: {run_code}",
                    f"Benchmark: {self.config.benchmark}",
                    f"Search path: {self.config.search_path}",
                    "",
                    "Available diagnostics:",
                    f"- {self.config.run_dir / 'benchmark.stdout.log'}",
                    f"- {self.config.run_dir / 'run.env'}",
                )
            )
            + "\n",
        )


@dataclass(slots=True)
class ComposePowerpipeServer:
    """Start the long-lived Compose Powerpipe server process."""

    config: ComposePowerpipeConfig

    def run(self) -> int:
        """Prepare the runtime workspace and launch the Powerpipe server."""
        LOGGER.info(
            "starting compose powerpipe server",
            extra={"workspace": self.config.workspace_name, "port": self.config.port},
        )
        ensure_dir(self.config.config_dir)
        ensure_dir(self.config.aws_config_dir)
        ensure_dir(self.config.results_dir)
        self._sync_host_aws()
        self._prepare_runtime_workspace()
        self._write_configs()
        if self.config.install_mods:
            run_command(
                ("powerpipe", "mod", "install", "--pull", self.config.mod_pull),
                cwd=self.config.workdir,
            )
        completed = subprocess.run(
            (
                "powerpipe",
                "server",
                "--workspace",
                self.config.workspace_name,
                "--listen",
                self.config.listen,
                "--port",
                str(self.config.port),
                "--mod-location",
                str(self.config.workdir),
            ),
            env=os.environ.copy(),
            check=False,
            text=True,
            cwd=self.config.workdir,
        )
        LOGGER.info("compose powerpipe server exited", extra={"returncode": completed.returncode})
        return completed.returncode

    def _sync_host_aws(self) -> None:
        if self.config.host_aws_dir.is_dir():
            shutil.copytree(
                self.config.host_aws_dir, self.config.aws_config_dir, dirs_exist_ok=True
            )

    def _prepare_runtime_workspace(self) -> None:
        if self.config.workdir.exists():
            shutil.rmtree(self.config.workdir)
        shutil.copytree(self.config.source_workdir, self.config.workdir)
        shutil.rmtree(self.config.workdir / ".powerpipe", ignore_errors=True)
        shutil.rmtree(self.config.workdir / "results", ignore_errors=True)
        (self.config.workdir / "results").symlink_to(self.config.results_dir)

    def _write_configs(self) -> None:
        connection_block = "\n".join(
            (
                'connection "steampipe" "default" {',
                f'  host     = "{self.config.database_host}"',
                f"  port     = {self.config.database_port}",
                f'  password = "{self.config.database_password}"',
                "}",
                "",
            )
        )
        write_text(
            self.config.connections_file,
            connection_block,
        )
        write_text(
            self.config.workspaces_file,
            "\n".join(
                (
                    f'workspace "{self.config.workspace_name}" {{',
                    f'  listen            = "{self.config.listen}"',
                    f"  port              = {self.config.port}",
                    "  watch             = false",
                    f"  query_timeout     = {self.config.query_timeout}",
                    f"  max_parallel      = {self.config.max_parallel}",
                    f"  benchmark_timeout = {self.config.benchmark_timeout}",
                    "}",
                    "",
                )
            ),
        )

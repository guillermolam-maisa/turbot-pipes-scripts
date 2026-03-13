"""Host-side benchmark orchestration and diagnostics capture."""

from __future__ import annotations

import os
import subprocess
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from .benchmark_common import (
    have_primary_exports,
    read_log_excerpt,
    resolve_search_path,
    run_steampipe_query,
    write_host_metadata,
)
from .config import HostBenchmarkConfig
from .logging_utils import get_logger
from .runtime import (
    CommandError,
    ensure_commands,
    ensure_dir,
    replace_symlink,
    retry_operation,
    run_command,
    wait_for_tcp,
    write_text,
)
from .utility_support import PortSelector

LOGGER = get_logger(__name__)


@dataclass(slots=True)
class HostBenchmarkRunner:
    """Run a benchmark directly on the host with conservative safety defaults."""

    config: HostBenchmarkConfig

    def run(self) -> int:
        """Execute the full host benchmark lifecycle and persist artifacts."""
        LOGGER.info(
            "starting host benchmark",
            extra={"benchmark": self.config.benchmark, "search_path": self.config.search_path},
        )
        ensure_commands(
            (
                "steampipe",
                "powerpipe",
                "pgrep",
                "pkill",
                "mkdir",
                "ps",
                "lsof",
                "timeout",
                "sed",
                "tee",
            )
        )
        self.config = HostBenchmarkConfig(
            workdir=self.config.workdir,
            results_dir=self.config.results_dir,
            run_dir=self.config.run_dir,
            latest_link=self.config.latest_link,
            benchmark=self.config.benchmark,
            search_path=self.config.search_path,
            max_parallel=self.config.max_parallel,
            query_timeout=self.config.query_timeout,
            benchmark_timeout=self.config.benchmark_timeout,
            port=self._select_listen_port(),
            service_timeout=self.config.service_timeout,
            powerpipe_server_wait=self.config.powerpipe_server_wait,
            steampipe_ready_timeout=self.config.steampipe_ready_timeout,
        )
        ensure_dir(self.config.results_dir)
        ensure_dir(self.config.run_dir)
        write_host_metadata(self.config)
        run_command(("pkill", "-f", "powerpipe benchmark run"), check=False)
        run_command(("pkill", "-f", "powerpipe server"), check=False)
        self._restart_steampipe()
        self._validate_benchmark()
        self._ensure_powerpipe_server()
        self._capture_diagnostics("pre-run")
        run_code = self._run_benchmark()
        self._capture_diagnostics("post-run")
        if not have_primary_exports(self.config.run_dir):
            self._write_partial_marker(run_code)
        if run_code == 0 or have_primary_exports(self.config.run_dir):
            replace_symlink(self.config.run_dir, self.config.latest_link)
        LOGGER.info(
            "host benchmark finished",
            extra={"returncode": run_code, "run_dir": str(self.config.run_dir)},
        )
        return run_code

    def _validate_benchmark(self) -> None:
        run_command(("powerpipe", "benchmark", "show", self.config.benchmark))

    def _select_listen_port(self) -> int:
        selector = PortSelector(self.config.port, self.config.port)
        if selector.port_available(self.config.port):
            return self.config.port
        command = self._listening_command(self.config.port)
        if "powerpipe server" in command:
            LOGGER.info("reusing existing powerpipe server", extra={"port": self.config.port})
            return self.config.port
        raise CommandError(f"port {self.config.port} is in use by another process: {command}")

    def _restart_steampipe(self) -> None:
        run_command(
            (
                "timeout",
                "15",
                "steampipe",
                "query",
                (
                    "select pid, application_name, pg_terminate_backend(pid) as terminated "
                    "from pg_stat_activity where datname = 'steampipe' and pid <> "
                    "pg_backend_pid() and application_name not like 'steampipe_service_%';"
                ),
            ),
            check=False,
        )
        run_command(
            ("timeout", str(self.config.service_timeout), "steampipe", "service", "restart"),
            check=False,
        )
        status = run_command(("timeout", "15", "steampipe", "service", "status"), check=False)
        if status.returncode != 0:
            run_command(
                ("timeout", str(self.config.service_timeout), "steampipe", "service", "start"),
                check=False,
            )
        if self._wait_for_steampipe():
            return
        self._capture_diagnostics("pre-reset")
        run_command(("timeout", "20", "steampipe", "service", "stop", "--force"), check=False)
        for command in (
            ("pkill", "-9", "-f", f"{Path.home()}/.steampipe/db/.*/postgres"),
            ("pkill", "-9", "-f", "steampipe plugin-manager"),
            ("pkill", "-9", "-f", "steampipe-plugin-aws.plugin"),
        ):
            run_command(command, check=False)
        run_command(("timeout", str(self.config.service_timeout), "steampipe", "service", "start"))
        if not self._wait_for_steampipe():
            self._capture_diagnostics("failed-reset")
            raise CommandError("unable to restart Steampipe cleanly")

    def _wait_for_steampipe(self) -> bool:
        deadline = time.time() + self.config.steampipe_ready_timeout
        while time.time() < deadline:
            if (
                run_command(
                    ("timeout", "15", "steampipe", "query", "select 1 as ok;"), check=False
                ).returncode
                == 0
            ):
                return True
            time.sleep(2)
        return False

    def _ensure_powerpipe_server(self) -> None:
        pid = self._listening_pid(self.config.port)
        if pid:
            command = self._listening_command(self.config.port)
            if "powerpipe server" in command:
                if wait_for_tcp("127.0.0.1", self.config.port, 3):
                    return
                LOGGER.warning(
                    "stale powerpipe listener detected",
                    extra={"port": self.config.port, "pid": pid},
                )
                run_command(("pkill", "-f", "powerpipe server"), check=False)
            else:
                raise CommandError(
                    f"port {self.config.port} is in use by another process: {command}"
                )
        server_log = self.config.run_dir / "powerpipe-server.log"
        retry_operation(
            lambda: self._start_powerpipe_server(server_log),
            attempts=2,
            delay_seconds=2,
            description="start powerpipe server",
        )

    def _start_powerpipe_server(self, server_log: Path) -> None:
        with server_log.open("w", encoding="utf-8") as handle:
            subprocess.Popen(
                ("nohup", "powerpipe", "server", "--port", str(self.config.port)),
                stdout=handle,
                stderr=handle,
                env=os.environ.copy(),
            )
        if not wait_for_tcp("127.0.0.1", self.config.port, self.config.powerpipe_server_wait):
            raise CommandError(f"powerpipe server did not start on port {self.config.port}")

    @staticmethod
    def _listening_pid(port: int) -> str:
        return run_command(
            ("bash", "-lc", f"lsof -tiTCP:{port} -sTCP:LISTEN | head -n 1"),
            capture_output=True,
            check=False,
        ).stdout.strip()

    def _listening_command(self, port: int) -> str:
        pid = self._listening_pid(port)
        if not pid:
            return ""
        return run_command(("ps", "-p", pid, "-o", "command="), capture_output=True).stdout.strip()

    def _capture_diagnostics(self, prefix: str) -> None:
        LOGGER.info(
            "capturing diagnostics", extra={"prefix": prefix, "run_dir": str(self.config.run_dir)}
        )
        resolved_search_path = resolve_search_path(self.config.search_path)
        for sql, output in (
            (
                (
                    "select pid, application_name, state, wait_event_type, wait_event, "
                    "left(query, 160) as query from pg_stat_activity where "
                    "datname = 'steampipe' order by pid;"
                ),
                self.config.run_dir / f"{prefix}-pg-activity.txt",
            ),
            (
                (
                    "select application_name, state, wait_event_type, wait_event, "
                    "count(*) as sessions from pg_stat_activity where "
                    "datname = 'steampipe' group by 1,2,3,4 order by "
                    "sessions desc, application_name;"
                ),
                self.config.run_dir / f"{prefix}-pg-summary.txt",
            ),
        ):
            try:
                run_steampipe_query(sql, output=output)
            except CommandError:
                pass
        try:
            run_steampipe_query(
                "select * from aws_caller_identity;",
                output=self.config.run_dir / f"{prefix}-caller-identity.json",
                extra_args=("--search-path", resolved_search_path, "--output", "json"),
            )
        except CommandError:
            pass
        today = datetime.now().strftime("%Y-%m-%d")
        write_text(
            self.config.run_dir / f"{prefix}-steampipe.log",
            read_log_excerpt(Path.home() / ".steampipe" / "logs" / f"steampipe-{today}.log", 200),
        )
        write_text(
            self.config.run_dir / f"{prefix}-plugin.log",
            read_log_excerpt(Path.home() / ".steampipe" / "logs" / f"plugin-{today}.log", 240),
        )

    def _run_benchmark(self) -> int:
        LOGGER.info(
            "running host benchmark command",
            extra={
                "benchmark": self.config.benchmark,
                "search_path": self.config.search_path,
                "max_parallel": self.config.max_parallel,
                "query_timeout": self.config.query_timeout,
                "benchmark_timeout": self.config.benchmark_timeout,
            },
        )
        resolved_search_path = resolve_search_path(self.config.search_path)
        stdout_log = self.config.run_dir / "benchmark.stdout.log"
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
                    "--search-path",
                    resolved_search_path,
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
                    str(self.config.run_dir / "benchmark.json"),
                    "--export",
                    str(self.config.run_dir / "benchmark.html"),
                    "--export",
                    str(self.config.run_dir / "benchmark.md"),
                    "--export",
                    str(self.config.run_dir / "benchmark.pps"),
                ),
                stdout=handle,
                stderr=handle,
                env=os.environ.copy(),
                check=False,
                text=True,
            )
        return completed.returncode

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
                    f"- {self.config.run_dir / 'post-run-pg-activity.txt'}",
                    f"- {self.config.run_dir / 'post-run-pg-summary.txt'}",
                    f"- {self.config.run_dir / 'post-run-caller-identity.json'}",
                    f"- {self.config.run_dir / 'post-run-steampipe.log'}",
                    f"- {self.config.run_dir / 'post-run-plugin.log'}",
                )
            )
            + "\n",
        )

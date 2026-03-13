"""Shared helpers for host and Compose benchmark execution."""

from __future__ import annotations

from pathlib import Path

from .config import ComposeBenchmarkConfig, HostBenchmarkConfig
from .runtime import CommandError, run_command, write_text


def read_log_excerpt(path: Path, limit: int) -> str:
    """Return the first ``limit`` lines from a log file when it exists."""
    if not path.is_file():
        return ""
    return "".join(
        path.read_text(encoding="utf-8", errors="ignore").splitlines(keepends=True)[:limit]
    )


def write_host_metadata(config: HostBenchmarkConfig) -> None:
    """Persist host benchmark runtime metadata alongside the run artifacts."""
    write_text(
        config.run_dir / "run.env",
        "\n".join(
            (
                f"WORKDIR={config.workdir}",
                f"RUN_DIR={config.run_dir}",
                f"BENCHMARK={config.benchmark}",
                f"SEARCH_PATH={config.search_path}",
                f"MAX_PARALLEL={config.max_parallel}",
                f"QUERY_TIMEOUT={config.query_timeout}",
                f"BENCHMARK_TIMEOUT={config.benchmark_timeout}",
                f"PORT={config.port}",
            )
        )
        + "\n",
        mode=0o600,
    )


def write_compose_metadata(config: ComposeBenchmarkConfig) -> None:
    """Persist Compose benchmark runtime metadata alongside the run artifacts."""
    write_text(
        config.run_dir / "run.env",
        "\n".join(
            (
                f"WORKDIR={config.workdir}",
                f"RUN_DIR={config.run_dir}",
                f"BENCHMARK={config.benchmark}",
                f"SEARCH_PATH={config.search_path}",
                f"MAX_PARALLEL={config.max_parallel}",
                f"QUERY_TIMEOUT={config.query_timeout}",
                f"BENCHMARK_TIMEOUT={config.benchmark_timeout}",
                f"PORT={config.port}",
            )
        )
        + "\n",
        mode=0o600,
    )


def have_primary_exports(run_dir: Path) -> bool:
    """Return whether the benchmark produced any primary exported artifact."""
    return any(
        (run_dir / name).is_file() and (run_dir / name).stat().st_size > 0
        for name in ("benchmark.json", "benchmark.html", "benchmark.md", "benchmark.pps")
    )


def run_steampipe_query(
    sql: str, *, output: Path | None = None, extra_args: tuple[str, ...] = ()
) -> str:
    """Run a Steampipe query and optionally persist its stdout to a file."""
    result = run_command(("steampipe", "query", *extra_args, sql), capture_output=True, check=False)
    if output:
        write_text(output, result.stdout)
    if result.returncode != 0:
        raise CommandError(f"steampipe query failed: {sql}")
    return result.stdout


def resolve_search_path(search_path: str) -> str:
    """Expand a named aggregate connection to its member connections when available."""
    if "," in search_path:
        return search_path
    config_file = Path.home() / ".steampipe" / "config" / "aws.spc"
    if not config_file.is_file():
        return search_path
    lines = config_file.read_text(encoding="utf-8", errors="ignore").splitlines()
    in_block = False
    in_list = False
    collected: list[str] = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith(f'connection "{search_path}"') and stripped.endswith("{"):
            in_block = True
            continue
        if in_block and stripped == "}":
            break
        if in_block and stripped.startswith("connections") and "[" in stripped:
            in_list = True
            continue
        if in_list:
            collected.extend(part.strip().strip('",') for part in stripped.split() if '"' in part)
            if "]" in stripped:
                in_list = False
    return ",".join(filter(None, collected)) or search_path

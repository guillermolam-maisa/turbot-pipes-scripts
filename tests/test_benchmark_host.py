from __future__ import annotations

from pathlib import Path

import pytest

from turbot_ops.benchmark_host import HostBenchmarkRunner
from turbot_ops.config import HostBenchmarkConfig
from turbot_ops.runtime import CommandError


def build_config(tmp_path: Path) -> HostBenchmarkConfig:
    return HostBenchmarkConfig(
        workdir=tmp_path / "powerpipe",
        results_dir=tmp_path / "results",
        run_dir=tmp_path / "results" / "20260101-000000",
        latest_link=tmp_path / "results" / "latest",
        benchmark="aws_compliance.benchmark.all_controls",
        search_path="admin_only",
        max_parallel=1,
        query_timeout=90,
        benchmark_timeout=2700,
        port=9033,
        service_timeout=30,
        powerpipe_server_wait=30,
        steampipe_ready_timeout=60,
    )


def test_select_listen_port_reuses_existing_powerpipe_server(monkeypatch, tmp_path: Path) -> None:
    runner = HostBenchmarkRunner(build_config(tmp_path))
    monkeypatch.setattr(
        "turbot_ops.benchmark_host.PortSelector.port_available", lambda self, port: False
    )
    monkeypatch.setattr(
        HostBenchmarkRunner,
        "_listening_command",
        lambda self, port: "powerpipe server --port 9033",
    )
    assert runner._select_listen_port() == 9033


def test_select_listen_port_rejects_non_powerpipe_listener(monkeypatch, tmp_path: Path) -> None:
    runner = HostBenchmarkRunner(build_config(tmp_path))
    monkeypatch.setattr(
        "turbot_ops.benchmark_host.PortSelector.port_available", lambda self, port: False
    )
    monkeypatch.setattr(
        HostBenchmarkRunner,
        "_listening_command",
        lambda self, port: "python -m http.server 9033",
    )
    with pytest.raises(CommandError, match="port 9033 is in use by another process"):
        runner._select_listen_port()

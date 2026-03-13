from __future__ import annotations

import pytest

from turbot_ops.config import ComposeBenchmarkConfig, HostBenchmarkConfig, env_int


def test_env_int_accepts_positive_values(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("MAX_PARALLEL", "3")
    assert env_int("MAX_PARALLEL", 1) == 3


@pytest.mark.parametrize("raw_value", ("0", "-1", "abc"))
def test_env_int_rejects_invalid_values(monkeypatch: pytest.MonkeyPatch, raw_value: str) -> None:
    monkeypatch.setenv("MAX_PARALLEL", raw_value)
    with pytest.raises(ValueError):
        env_int("MAX_PARALLEL", 1)


def test_host_benchmark_config_uses_conservative_defaults(monkeypatch: pytest.MonkeyPatch) -> None:
    for name in ("MAX_PARALLEL", "QUERY_TIMEOUT", "BENCHMARK_TIMEOUT", "PORT", "STAMP"):
        monkeypatch.delenv(name, raising=False)
    config = HostBenchmarkConfig.from_env()
    assert config.max_parallel == 1
    assert config.query_timeout == 90
    assert config.benchmark_timeout == 2700
    assert config.port == 9033


def test_compose_benchmark_config_reads_feature_flags(
    monkeypatch: pytest.MonkeyPatch, tmp_path
) -> None:
    monkeypatch.setenv("WORKDIR", str(tmp_path / "workdir"))
    monkeypatch.setenv("RESULTS_DIR", str(tmp_path / "results"))
    monkeypatch.setenv("SOURCE_WORKDIR", str(tmp_path / "source"))
    monkeypatch.setenv("POWERPIPE_INSTALL_MODS", "false")
    monkeypatch.setenv("BENCHMARK_ACCEPT_FINDINGS", "true")
    monkeypatch.setenv("STAMP", "20260101-000000")
    config = ComposeBenchmarkConfig.from_env()
    assert config.install_mods is False
    assert config.accept_findings is True
    assert config.run_dir.name == "20260101-000000"

from __future__ import annotations

from pathlib import Path

from turbot_ops.benchmark_common import resolve_search_path


def test_resolve_search_path_returns_original_when_config_missing(monkeypatch) -> None:
    monkeypatch.setattr(Path, "home", lambda: Path("/tmp/nonexistent-home"))
    assert resolve_search_path("admin_only") == "admin_only"

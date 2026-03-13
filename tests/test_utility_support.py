from __future__ import annotations

from pathlib import Path

from turbot_ops.utility_support import ComposeEnvWriter


def test_compose_env_writer_host_identity_without_sudo(monkeypatch) -> None:
    monkeypatch.delenv("SUDO_USER", raising=False)
    monkeypatch.setattr(Path, "home", lambda: Path("/home/test-user"))
    monkeypatch.setattr("os.getuid", lambda: 1000)
    monkeypatch.setattr("os.getgid", lambda: 1001)
    writer = ComposeEnvWriter(
        runtime_dir=Path("/tmp/runtime"),
        env_file=Path("/tmp/runtime/compose.env"),
        preferred_host_port=9033,
    )
    assert writer.host_identity() == ("/home/test-user", "1000", "1001")

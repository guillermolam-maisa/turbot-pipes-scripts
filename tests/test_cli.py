from __future__ import annotations

from turbot_ops import cli
from turbot_ops.runtime import CommandError


def test_main_returns_failure_for_command_errors(monkeypatch) -> None:
    monkeypatch.setattr("sys.argv", ["turbot-ops", "doctor"])
    monkeypatch.setattr(cli, "configure_logging", lambda: None)
    monkeypatch.setattr(cli, "build_parser", cli.build_parser)
    monkeypatch.setattr(
        cli,
        "Doctor",
        lambda: type(
            "DoctorStub",
            (),
            {"run": lambda self: (_ for _ in ()).throw(CommandError("broken"))},
        )(),
    )
    assert cli.main() == 1

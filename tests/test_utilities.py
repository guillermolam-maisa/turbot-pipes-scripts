from __future__ import annotations

import pytest

from turbot_ops.runtime import CommandError, retry_operation
from turbot_ops.utilities import DependencyChecker, PortSelector


def test_port_selector_rejects_invalid_ranges() -> None:
    with pytest.raises(CommandError):
        PortSelector(preferred_port=0, max_port=10).run()


def test_port_selector_from_args_parses_values() -> None:
    selector = PortSelector.from_args(["--preferred", "9033", "--max", "9040"])
    assert selector.preferred_port == 9033
    assert selector.max_port == 9040


def test_dependency_checker_rejects_unknown_profiles() -> None:
    checker = DependencyChecker(profile="nope")
    with pytest.raises(CommandError):
        checker.run()


def test_retry_operation_succeeds_after_transient_failure() -> None:
    attempts: list[int] = []

    def operation() -> str:
        attempts.append(1)
        if len(attempts) == 1:
            raise CommandError("transient")
        return "ok"

    assert (
        retry_operation(operation, attempts=2, delay_seconds=0, description="test operation")
        == "ok"
    )


def test_retry_operation_raises_after_exhaustion() -> None:
    with pytest.raises(CommandError, match="failed after 2 attempts"):
        retry_operation(
            lambda: (_ for _ in ()).throw(CommandError("still broken")),
            attempts=2,
            delay_seconds=0,
            description="test operation",
        )

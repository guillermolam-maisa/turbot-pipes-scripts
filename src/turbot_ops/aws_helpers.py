"""AWS-specific helpers shared by discovery and benchmark workflows."""

from __future__ import annotations

import time

from .runtime import CompletedCommand, run_command


def safe_text(value: str) -> str:
    """Normalize null-like AWS CLI text output to an empty string."""
    return "" if value in {"", "None", "null"} else value


def profile_selected(profile_name: str, selector: str) -> bool:
    """Return whether a profile name matches the configured selector."""
    lowered = profile_name.lower()
    return {
        "all": lambda: True,
        "admin_only": lambda: any(
            term in lowered for term in ("administratoraccess", "developer-permission-set")
        ),
    }.get(selector, lambda: selector in lowered)()


def aws_retry_capture(args: tuple[str, ...], attempts: int, base_delay: int) -> CompletedCommand:
    """Run an AWS CLI command with exponential backoff and captured output."""
    delay = base_delay
    final_result = CompletedCommand(returncode=1, stdout="")
    for attempt in range(1, attempts + 1):
        final_result = run_command(args, capture_output=True, check=False)
        if final_result.returncode == 0:
            return final_result
        if attempt < attempts:
            time.sleep(delay)
            delay *= 2
    return final_result

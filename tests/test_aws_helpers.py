from __future__ import annotations

from turbot_ops.aws_helpers import profile_selected, safe_text


def test_profile_selected_handles_named_selectors() -> None:
    assert profile_selected("AdministratorAccess-prod", "admin_only") is True
    assert profile_selected("developer", "admin_only") is False
    assert profile_selected("anything", "all") is True
    assert profile_selected("team-admin-prod", "admin") is True


def test_safe_text_normalizes_empty_like_values() -> None:
    assert safe_text("") == ""
    assert safe_text("None") == ""
    assert safe_text("null") == ""
    assert safe_text("value") == "value"

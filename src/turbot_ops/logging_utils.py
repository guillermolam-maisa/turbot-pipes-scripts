"""Centralized logging configuration for Turbot operational services."""

from __future__ import annotations

import logging
import os
import sys

RESERVED_LOG_RECORD_KEYS = set(logging.LogRecord("", 0, "", 0, "", (), None).__dict__) | {
    "asctime",
    "message",
}


class ContextFormatter(logging.Formatter):
    """Append non-standard log record attributes as inline context."""

    def format(self, record: logging.LogRecord) -> str:
        rendered = super().format(record)
        extras = {
            key: value
            for key, value in record.__dict__.items()
            if key not in RESERVED_LOG_RECORD_KEYS
        }
        if not extras:
            return rendered
        context = " ".join(f"{key}={value}" for key, value in sorted(extras.items()))
        return f"{rendered} {context}"


def configure_logging() -> None:
    """Configure package-wide stderr logging for CLI entrypoints."""
    level_name = os.environ.get("TURBOT_OPS_LOG_LEVEL", "INFO").upper()
    level = getattr(logging, level_name, logging.INFO)
    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(ContextFormatter("%(asctime)s %(levelname)s %(name)s %(message)s"))
    logging.basicConfig(level=level, handlers=[handler], force=True)


def get_logger(name: str) -> logging.Logger:
    """Return a namespaced logger for the calling module."""
    return logging.getLogger(name)

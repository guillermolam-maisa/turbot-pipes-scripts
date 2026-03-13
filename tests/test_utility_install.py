from __future__ import annotations

from pathlib import Path

import pytest

from turbot_ops.runtime import CommandError
from turbot_ops.utility_install import HostInstaller


def build_installer(tmp_path: Path) -> HostInstaller:
    return HostInstaller(
        install_dir=tmp_path,
        versions={"steampipe": "2.4.0"},
        checksum_file=tmp_path / "tool_checksums.txt",
        archive_arch="linux_amd64",
        download_timeout_seconds=1,
        download_attempts=2,
        download_delay_seconds=0,
    )


def test_download_archive_retries_after_transient_failure(monkeypatch, tmp_path: Path) -> None:
    installer = build_installer(tmp_path)
    attempts: list[int] = []

    def fake_download(url: str) -> bytes:
        attempts.append(1)
        if len(attempts) == 1:
            raise CommandError("transient")
        return b"archive"

    monkeypatch.setattr(HostInstaller, "_download_bytes", lambda self, url: fake_download(url))
    assert installer._download_archive("steampipe", "2.4.0") == b"archive"


def test_download_archive_raises_after_retry_exhaustion(monkeypatch, tmp_path: Path) -> None:
    installer = build_installer(tmp_path)
    monkeypatch.setattr(
        HostInstaller,
        "_download_bytes",
        lambda self, url: (_ for _ in ()).throw(CommandError("offline")),
    )
    with pytest.raises(CommandError, match="download steampipe 2.4.0 failed after 2 attempts"):
        installer._download_archive("steampipe", "2.4.0")

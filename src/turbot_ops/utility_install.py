"""Host installation and vendoring helpers for Turbot binaries."""

from __future__ import annotations

import json
import os
import platform
import shutil
from dataclasses import dataclass
from pathlib import Path
from urllib.request import urlopen

from .logging_utils import get_logger
from .runtime import (
    CommandError,
    command_exists,
    ensure_dir,
    repo_root,
    retry_operation,
    run_command,
    runtime_env,
    write_text,
)
from .utility_support import parse_arg_value

LOGGER = get_logger(__name__)


def _sha256_digest(path: Path) -> str:
    """Return the SHA-256 digest of a file."""
    import hashlib

    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _read_expected_checksum(checksum_file: Path, archive_name: str) -> str:
    """Read the expected checksum for a downloaded archive."""
    for line in checksum_file.read_text(encoding="utf-8").splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1] == archive_name:
            return parts[0]
    raise CommandError(f"missing checksum for {archive_name} in {checksum_file}")


def _archive_url(tool_name: str, version: str, archive_arch: str) -> str:
    """Return the release archive URL for a pinned tool version."""
    return {
        "steampipe": f"https://github.com/turbot/steampipe/releases/download/v{version}/steampipe_{archive_arch}.tar.gz",
        "powerpipe": f"https://github.com/turbot/powerpipe/releases/download/v{version}/powerpipe.linux.amd64.tar.gz",
        "tailpipe": f"https://github.com/turbot/tailpipe/releases/download/v{version}/tailpipe.linux.amd64.tar.gz",
    }[tool_name]


@dataclass(slots=True)
class HostInstaller:
    """Download and install pinned Turbot binaries into a target directory."""

    install_dir: Path
    versions: dict[str, str]
    checksum_file: Path
    archive_arch: str
    download_timeout_seconds: int
    download_attempts: int
    download_delay_seconds: int

    @classmethod
    def from_args(cls, args: list[str]) -> HostInstaller:
        """Construct a host installer from CLI arguments and environment."""
        root_dir = repo_root()
        return cls(
            install_dir=Path(
                parse_arg_value(
                    args,
                    "--install-dir",
                    os.environ.get("INSTALL_DIR", str(root_dir / "vendor" / "bin")),
                )
            ),
            versions={
                "steampipe": os.environ.get("STEAMPIPE_VERSION", "2.4.0"),
                "powerpipe": os.environ.get("POWERPIPE_VERSION", "1.5.0"),
                "tailpipe": os.environ.get("TAILPIPE_VERSION", "0.7.2"),
            },
            checksum_file=root_dir / "vendor" / "bin" / "tool_checksums.txt",
            archive_arch=os.environ.get("ARCHIVE_ARCH", "linux_amd64"),
            download_timeout_seconds=int(os.environ.get("DOWNLOAD_TIMEOUT_SECONDS", "30")),
            download_attempts=int(os.environ.get("DOWNLOAD_ATTEMPTS", "3")),
            download_delay_seconds=int(os.environ.get("DOWNLOAD_DELAY_SECONDS", "2")),
        )

    def run(self) -> int:
        """Install all configured tools into the selected directory."""
        LOGGER.info("starting host installer", extra={"install_dir": str(self.install_dir)})
        if (platform.system(), platform.machine(), self.archive_arch) not in {
            ("Linux", "x86_64", "linux_amd64"),
            ("Linux", "amd64", "linux_amd64"),
        }:
            raise CommandError(
                "bootstrap currently supports Linux x86_64/amd64 only, got "
                f"{platform.system()}/{platform.machine()}"
            )
        if not command_exists("tar"):
            raise CommandError("missing command: tar")
        ensure_dir(self.install_dir)
        for name, version in self.versions.items():
            self.install_tool(name, version)
        LOGGER.info("host installer completed", extra={"install_dir": str(self.install_dir)})
        return 0

    def install_tool(self, tool_name: str, version: str) -> None:
        """Install one tool version when the target binary is missing or stale."""
        target_path = self.install_dir / tool_name
        if target_path.is_file():
            version_result = run_command(
                (str(target_path), "--version"), capture_output=True, check=False
            )
            if version in version_result.stdout:
                return
        archive_name = f"{tool_name}_v{version}.tar.gz"
        expected = _read_expected_checksum(self.checksum_file, archive_name)
        data = self._download_archive(tool_name, version)
        tmp_file = self.install_dir / f".{archive_name}"
        tmp_file.write_bytes(data)
        tmp_file.chmod(0o600)
        if _sha256_digest(tmp_file) != expected:
            tmp_file.unlink(missing_ok=True)
            raise CommandError(f"checksum mismatch for {tool_name} {version}")
        run_command(("tar", "-xzf", str(tmp_file), "-C", str(self.install_dir)))
        tmp_file.unlink(missing_ok=True)
        run_command((str(self.install_dir / tool_name), "--version"))

    def _download_archive(self, tool_name: str, version: str) -> bytes:
        url = _archive_url(tool_name, version, self.archive_arch)
        return retry_operation(
            lambda: self._download_bytes(url),
            attempts=self.download_attempts,
            delay_seconds=self.download_delay_seconds,
            description=f"download {tool_name} {version}",
            retriable_exceptions=(CommandError,),
        )

    def _download_bytes(self, url: str) -> bytes:
        try:
            with urlopen(url, timeout=self.download_timeout_seconds) as response:
                return response.read()
        except OSError as exc:
            raise CommandError(f"failed to download {url}") from exc


@dataclass(slots=True)
class VendorBinaries:
    """Copy locally installed binaries and plugin seeds into the repo vendor tree."""

    root_dir: Path

    @classmethod
    def from_repo(cls) -> VendorBinaries:
        """Construct a vendoring service rooted at the current repository."""
        return cls(root_dir=repo_root())

    def run(self) -> int:
        """Vendor binaries and the Steampipe AWS plugin seed into the repo."""
        LOGGER.info("starting vendoring", extra={"root_dir": str(self.root_dir)})
        vendor_dir = self.root_dir / "vendor" / "bin"
        plugin_source_root = Path.home() / ".steampipe" / "plugins"
        plugin_vendor_root = self.root_dir / "vendor" / "steampipe-plugins"
        ensure_dir(vendor_dir)
        for name in ("steampipe", "powerpipe", "tailpipe"):
            self.copy_binary(name, vendor_dir)
        self.sync_steampipe_plugin_seed(plugin_source_root, plugin_vendor_root)
        print(f"Vendored binaries in {vendor_dir}")
        LOGGER.info("vendoring completed", extra={"vendor_dir": str(vendor_dir)})
        return 0

    def copy_binary(self, name: str, vendor_dir: Path) -> None:
        """Copy one binary into the vendor directory when the version changed."""
        source = shutil.which(name, path=runtime_env().get("PATH"))
        if not source:
            raise CommandError(f"missing command: {name}")
        source_path = Path(source)
        current_version = run_command(
            (str(source_path), "--version"), capture_output=True
        ).stdout.strip()
        manifest_path = vendor_dir / f"{name}.manifest"
        target_path = vendor_dir / name
        if (
            target_path.is_file()
            and manifest_path.is_file()
            and manifest_path.read_text(encoding="utf-8").strip() == current_version
        ):
            return
        shutil.copy2(source_path, target_path)
        target_path.chmod(0o755)
        write_text(manifest_path, f"{current_version}\n")

    def sync_steampipe_plugin_seed(self, source_root: Path, vendor_root: Path) -> None:
        """Refresh the vendored Steampipe AWS plugin seed from the host install."""
        source_plugin_dir = source_root / "hub.steampipe.io" / "plugins" / "turbot" / "aws@latest"
        source_versions_file = source_root / "versions.json"
        version_file = source_plugin_dir / "version.json"
        vendored_manifest = vendor_root / "aws-plugin.manifest"
        vendored_latest_dir = vendor_root / "hub.steampipe.io" / "plugins" / "turbot" / "aws@latest"
        if not (
            source_plugin_dir.is_dir() and version_file.is_file() and source_versions_file.is_file()
        ):
            if vendored_latest_dir.is_dir() and vendored_manifest.is_file():
                return
            raise CommandError(
                f"host Steampipe AWS plugin seed not found under {source_plugin_dir}"
            )
        metadata = json.loads(version_file.read_text(encoding="utf-8"))
        versioned_name = metadata.get("version")
        if not versioned_name:
            raise CommandError(f"failed to parse Steampipe AWS plugin version from {version_file}")
        vendored_versioned_dir = (
            vendor_root / "hub.steampipe.io" / "plugins" / "turbot" / f"aws@{versioned_name}"
        )
        shutil.rmtree(vendor_root, ignore_errors=True)
        ensure_dir(vendored_latest_dir.parent)
        shutil.copytree(source_plugin_dir, vendored_latest_dir)
        shutil.copytree(source_plugin_dir, vendored_versioned_dir)
        shutil.copy2(source_versions_file, vendor_root / "versions.json")
        write_text(
            vendored_manifest,
            "\n".join(
                (
                    f"version={metadata.get('version', '')}",
                    f"installed_from={metadata.get('installed_from', '')}",
                    f"image_digest={metadata.get('image_digest', '')}",
                    f"binary_digest={metadata.get('binary_digest', '')}",
                    "",
                )
            ),
        )

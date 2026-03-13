"""Bootstrap workflow for preparing a host workspace."""

from __future__ import annotations

from dataclasses import dataclass

from .config import BootstrapConfig
from .logging_utils import get_logger
from .runtime import CommandError, command_exists, retry_operation, run_command

LOGGER = get_logger(__name__)


@dataclass(slots=True)
class BootstrapWorkspace:
    """Install required local assets and validate the workspace state."""

    config: BootstrapConfig

    def run(self) -> int:
        """Execute the bootstrap sequence for the current repository."""
        LOGGER.info("starting bootstrap workspace", extra={"root_dir": str(self.config.root_dir)})
        run_command(("bash", str(self.config.root_dir / "scripts" / "install-host-deps.sh")))
        if not all(command_exists(name) for name in ("steampipe", "powerpipe", "tailpipe")):
            raise CommandError("required Turbot binaries are not available after install")
        self._ensure_steampipe_plugin()
        self._ensure_powerpipe_mods()
        self._ensure_tailpipe_plugin()
        run_command(("bash", str(self.config.root_dir / "scripts" / "vendor-local-binaries.sh")))
        run_command(("bash", str(self.config.root_dir / "scripts" / "validate-workspace.sh")))
        LOGGER.info("bootstrap workspace completed", extra={"root_dir": str(self.config.root_dir)})
        return 0

    def _ensure_steampipe_plugin(self) -> None:
        """Install the Steampipe AWS plugin when it is not already present."""
        self._ensure_listed_asset(
            list_command=("steampipe", "plugin", "list"),
            install_command=("steampipe", "plugin", "install", "aws"),
            expected_token="aws",
            description="Steampipe AWS plugin",
        )

    def _ensure_powerpipe_mods(self) -> None:
        """Install Powerpipe mods when the workspace has not been initialized yet."""
        self._ensure_listed_asset(
            list_command=("powerpipe", "mod", "list"),
            install_command=("powerpipe", "mod", "install"),
            expected_token="github.com/turbot/",
            description="Powerpipe mods",
            cwd=self.config.root_dir / "powerpipe",
        )

    def _ensure_tailpipe_plugin(self) -> None:
        """Install the Tailpipe AWS plugin when it is not already present."""
        self._ensure_listed_asset(
            list_command=("tailpipe", "plugin", "list"),
            install_command=("tailpipe", "plugin", "install", "aws"),
            expected_token="aws",
            description="Tailpipe AWS plugin",
        )

    def _ensure_listed_asset(
        self,
        *,
        list_command: tuple[str, ...],
        install_command: tuple[str, ...],
        expected_token: str,
        description: str,
        cwd=None,
    ) -> None:
        if (
            expected_token
            in run_command(list_command, capture_output=True, check=False, cwd=cwd).stdout
        ):
            return
        retry_operation(
            lambda: self._install_and_verify(
                list_command=list_command,
                install_command=install_command,
                expected_token=expected_token,
                description=description,
                cwd=cwd,
            ),
            attempts=2,
            delay_seconds=2,
            description=f"install {description}",
        )

    @staticmethod
    def _install_and_verify(
        *,
        list_command: tuple[str, ...],
        install_command: tuple[str, ...],
        expected_token: str,
        description: str,
        cwd=None,
    ) -> None:
        run_command(install_command, cwd=cwd)
        listing = run_command(list_command, capture_output=True, check=False, cwd=cwd).stdout
        if expected_token not in listing:
            raise CommandError(f"{description} is still unavailable after install")

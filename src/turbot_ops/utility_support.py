"""Utility services that support CLI wrappers and runtime setup."""

from __future__ import annotations

import os
import pwd
import socket
import sys
from pathlib import Path

from .logging_utils import get_logger
from .runtime import (
    CommandError,
    command_exists,
    ensure_dir,
    repo_root,
    run_command,
    runtime_env,
    write_text,
)

LOGGER = get_logger(__name__)


def slug(value: str) -> str:
    """Normalize a string for use as a configuration identifier (slug)."""
    normalized = "".join(char.lower() if char.isalnum() else "_" for char in value)
    collapsed = "_".join(part for part in normalized.split("_") if part)
    return collapsed or "aws"


def parse_arg_value(args: list[str], flag: str, default: str) -> str:
    """Return the value that follows a CLI flag, or a default when absent."""
    if flag not in args:
        return default
    index = args.index(flag)
    try:
        return args[index + 1]
    except IndexError as exc:
        raise CommandError(f"{flag} requires a value") from exc


class PortSelector:
    """Select an available TCP port in a configured range."""

    def __init__(self, preferred_port: int, max_port: int) -> None:
        self.preferred_port = preferred_port
        self.max_port = max_port

    @classmethod
    def from_args(cls, args: list[str]) -> PortSelector:
        """Construct a port selector from CLI arguments and environment."""
        preferred = int(
            parse_arg_value(args, "--preferred", os.environ.get("PREFERRED_PORT", "9033"))
        )
        maximum = int(parse_arg_value(args, "--max", os.environ.get("MAX_PORT", "65535")))
        return cls(preferred, maximum)

    def run(self) -> int:
        """Print the first available port in the configured range."""
        if self.preferred_port < 1 or self.max_port > 65535 or self.preferred_port > self.max_port:
            raise CommandError(f"invalid port range {self.preferred_port}-{self.max_port}")
        for port in range(self.preferred_port, self.max_port + 1):
            if self.port_available(port):
                LOGGER.info("selected free port", extra={"port": port})
                print(port)
                return 0
        raise CommandError(
            f"no free TCP ports found in range {self.preferred_port}-{self.max_port}"
        )

    def port_available(self, port: int) -> bool:
        """Return whether a TCP port is currently unused on the local host."""
        if command_exists("ss"):
            result = run_command(("ss", "-ltnH"), capture_output=True, check=False)
            return f":{port}" not in result.stdout
        if command_exists("lsof"):
            return (
                run_command(
                    ("lsof", f"-iTCP:{port}", "-sTCP:LISTEN"), check=False, capture_output=True
                ).returncode
                != 0
            )
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                return sock.connect_ex(("127.0.0.1", port)) != 0
        except PermissionError as exc:
            raise CommandError(
                "need either ss or lsof to detect used ports in this environment"
            ) from exc


class ComposeEnvWriter:
    """Write the Compose environment file consumed by task and Docker flows."""

    def __init__(self, runtime_dir: Path, env_file: Path, preferred_host_port: int) -> None:
        self.runtime_dir = runtime_dir
        self.env_file = env_file
        self.preferred_host_port = preferred_host_port

    @classmethod
    def from_env(cls) -> ComposeEnvWriter:
        """Construct a compose env writer from environment variables."""
        runtime_dir = Path(os.environ.get("RUNTIME_DIR", "/tmp/turbot-runtime"))
        return cls(
            runtime_dir=runtime_dir,
            env_file=runtime_dir / "compose.env",
            preferred_host_port=int(
                os.environ.get(
                    "PREFERRED_POWERPIPE_HOST_PORT", os.environ.get("POWERPIPE_HOST_PORT", "9033")
                )
            ),
        )

    def run(self) -> int:
        """Generate the runtime compose.env file and print its path."""
        LOGGER.info("writing compose env", extra={"env_file": str(self.env_file)})
        ensure_dir(self.runtime_dir)
        host_home, host_uid, host_gid = self.host_identity()
        selected_port = self._selected_port()
        write_text(
            self.env_file,
            "\n".join(
                (
                    f"HOST_HOME={host_home}",
                    f"HOST_UID={host_uid}",
                    f"HOST_GID={host_gid}",
                    f"POWERPIPE_HOST_PORT={selected_port}",
                    "",
                )
            ),
        )
        print(self.env_file)
        LOGGER.info("compose env written", extra={"env_file": str(self.env_file)})
        return 0

    def _selected_port(self) -> int:
        selector = PortSelector(self.preferred_host_port, 65535)
        for port in range(selector.preferred_port, selector.max_port + 1):
            if selector.port_available(port):
                return port
        raise CommandError(
            f"no free TCP ports found in range {selector.preferred_port}-{selector.max_port}"
        )

    def host_identity(self) -> tuple[str, str, str]:
        """Resolve the effective host home directory and UID/GID."""
        sudo_user = os.environ.get("SUDO_USER")
        if not sudo_user:
            return str(Path.home()), str(os.getuid()), str(os.getgid())
        try:
            entry = pwd.getpwnam(sudo_user)
            return entry.pw_dir, str(entry.pw_uid), str(entry.pw_gid)
        except KeyError as exc:
            raise CommandError(f"unable to resolve identity for sudo user {sudo_user}") from exc


class RuntimeCleanup:
    """Stop local benchmark-related processes and tear down Compose state."""

    def __init__(self, root_dir: Path) -> None:
        self.root_dir = root_dir

    @classmethod
    def from_repo(cls) -> RuntimeCleanup:
        """Construct a cleanup service rooted at the current repository."""
        return cls(repo_root())

    def run(self) -> int:
        """Terminate local runtime processes and bring Compose down."""
        LOGGER.info("starting runtime cleanup", extra={"root_dir": str(self.root_dir)})
        for pattern in ("powerpipe benchmark run", "powerpipe server"):
            run_command(("pkill", "-f", pattern), check=False)
        if command_exists("docker"):
            docker_wrapper = self.root_dir / "scripts" / "docker-compose.sh"
            run_command(
                (
                    "bash",
                    str(docker_wrapper),
                    "-f",
                    str(self.root_dir / "compose.yaml"),
                    "down",
                    "--remove-orphans",
                ),
                check=False,
            )
        LOGGER.info("runtime cleanup completed", extra={"root_dir": str(self.root_dir)})
        return 0


class DockerComposeWrapper:
    """Invoke docker compose directly or through sudo when needed."""

    def __init__(self, args: list[str], use_sudo: str) -> None:
        self.args = args
        self.use_sudo = use_sudo

    @classmethod
    def from_args(cls, args: list[str]) -> DockerComposeWrapper:
        """Construct a docker compose wrapper from CLI arguments."""
        return cls(args, os.environ.get("DOCKER_COMPOSE_USE_SUDO", "auto"))

    def run(self) -> int:
        """Execute docker compose with the minimum required privilege level."""
        LOGGER.info(
            "invoking docker compose wrapper",
            extra={"compose_args": " ".join(self.args), "use_sudo": self.use_sudo},
        )
        if not command_exists("docker"):
            raise CommandError("docker is not installed")
        if self.subcommand() in {"config", "version"}:
            os.execvpe("docker", ("docker", "compose", *self.args), runtime_env())
        if self.use_sudo == "never":
            os.execvpe("docker", ("docker", "compose", *self.args), runtime_env())
        if run_command(("docker", "ps"), check=False, capture_output=True).returncode == 0:
            os.execvpe("docker", ("docker", "compose", *self.args), runtime_env())
        if self.use_sudo == "always" and command_exists("sudo"):
            os.execvpe("sudo", ("sudo", "docker", "compose", *self.args), runtime_env())
        if self.use_sudo == "auto" and command_exists("sudo"):
            if (
                run_command(
                    ("sudo", "-n", "docker", "ps"), check=False, capture_output=True
                ).returncode
                == 0
            ):
                os.execvpe("sudo", ("sudo", "docker", "compose", *self.args), runtime_env())
            if sys.stdin.isatty() and sys.stdout.isatty():
                os.execvpe("sudo", ("sudo", "docker", "compose", *self.args), runtime_env())
        raise CommandError("docker daemon requires elevated privileges for this user")

    def subcommand(self) -> str:
        """Return the first non-option compose subcommand from raw arguments."""
        skip_next = False
        for arg in self.args:
            if skip_next:
                skip_next = False
                continue
            if arg in {"-f", "--file", "--env-file", "--profile", "--project-name"}:
                skip_next = True
                continue
            if not arg.startswith("-"):
                return arg
        return ""

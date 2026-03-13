"""Command-line entrypoint for Turbot operational workflows."""

from __future__ import annotations

import argparse

from .benchmark import ComposeBenchmarkRunner, ComposePowerpipeServer, HostBenchmarkRunner
from .bootstrap import BootstrapWorkspace
from .config import (
    BootstrapConfig,
    ComposeBenchmarkConfig,
    ComposePowerpipeConfig,
    ComposeSteampipeConfig,
    ComposeTailpipeConfig,
    HostBenchmarkConfig,
    TailpipeDiscoveryConfig,
)
from .doctor import Doctor
from .logging_utils import configure_logging, get_logger
from .runtime import CommandError
from .steampipe import ComposeSteampipeService
from .tailpipe import ComposeTailpipeService, TailpipeDiscovery
from .utilities import (
    ComposeEnvWriter,
    DependencyChecker,
    DockerComposeWrapper,
    HostInstaller,
    PortSelector,
    RuntimeCleanup,
    VendorBinaries,
)

LOGGER = get_logger(__name__)


def build_parser() -> argparse.ArgumentParser:
    """Build the top-level CLI parser and subcommand registry."""
    parser = argparse.ArgumentParser(prog="turbot-ops")
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in (
        "host-benchmark",
        "compose-benchmark",
        "compose-powerpipe",
        "compose-steampipe",
        "tailpipe-discover",
        "compose-tailpipe",
        "bootstrap",
        "doctor",
        "install-host-deps",
        "vendor-binaries",
        "check-dependencies",
        "write-compose-env",
        "select-port",
        "cleanup-runtime",
        "docker-compose",
    ):
        subparsers.add_parser(name)
    return parser


def main() -> int:
    """Dispatch a CLI command to the matching service object."""
    configure_logging()
    parser = build_parser()
    args, extra_args = parser.parse_known_args()
    LOGGER.info("dispatching command", extra={"command": args.command})
    command_map = {
        "host-benchmark": lambda: HostBenchmarkRunner(HostBenchmarkConfig.from_env()).run(),
        "compose-benchmark": lambda: ComposeBenchmarkRunner(
            ComposeBenchmarkConfig.from_env()
        ).run(),
        "compose-powerpipe": lambda: ComposePowerpipeServer(
            ComposePowerpipeConfig.from_env()
        ).run(),
        "compose-steampipe": lambda: ComposeSteampipeService(
            ComposeSteampipeConfig.from_env()
        ).run(),
        "tailpipe-discover": lambda: TailpipeDiscovery(TailpipeDiscoveryConfig.from_env()).run(),
        "compose-tailpipe": lambda: ComposeTailpipeService(ComposeTailpipeConfig.from_env()).run(),
        "bootstrap": lambda: BootstrapWorkspace(BootstrapConfig.from_repo()).run(),
        "doctor": lambda: Doctor().run(),
        "install-host-deps": lambda: HostInstaller.from_args(extra_args).run(),
        "vendor-binaries": lambda: VendorBinaries.from_repo().run(),
        "check-dependencies": lambda: DependencyChecker.from_args(extra_args).run(),
        "write-compose-env": lambda: ComposeEnvWriter.from_env().run(),
        "select-port": lambda: PortSelector.from_args(extra_args).run(),
        "cleanup-runtime": lambda: RuntimeCleanup.from_repo().run(),
        "docker-compose": lambda: DockerComposeWrapper.from_args(extra_args).run(),
    }
    try:
        return command_map[args.command]()
    except CommandError as exc:
        LOGGER.error("command failed", extra={"command": args.command, "error": str(exc)})
        return 1
    except Exception:
        LOGGER.exception("unexpected command failure", extra={"command": args.command})
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

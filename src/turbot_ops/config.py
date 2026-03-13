"""Immutable configuration objects derived from environment variables."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


def env_int(name: str, default: int) -> int:
    """Read a positive integer environment variable or fall back to a default."""
    raw_value = os.environ.get(name, str(default))
    if not raw_value.isdigit() or int(raw_value) <= 0:
        raise ValueError(f"{name} must be a positive integer, got: {raw_value}")
    return int(raw_value)


@dataclass(frozen=True)
class HostBenchmarkConfig:
    """Runtime settings for host-side benchmark execution."""

    workdir: Path
    results_dir: Path
    run_dir: Path
    latest_link: Path
    benchmark: str
    search_path: str
    max_parallel: int
    query_timeout: int
    benchmark_timeout: int
    port: int
    service_timeout: int
    powerpipe_server_wait: int
    steampipe_ready_timeout: int

    @classmethod
    def from_env(cls) -> HostBenchmarkConfig:
        """Construct a host benchmark configuration from environment variables."""
        workdir = Path(__file__).resolve().parents[2] / "powerpipe"
        results_dir = workdir / "results"
        stamp = os.environ.get("STAMP") or __import__("datetime").datetime.now().strftime(
            "%Y%m%d-%H%M%S"
        )
        run_dir = results_dir / stamp
        return cls(
            workdir=workdir,
            results_dir=results_dir,
            run_dir=run_dir,
            latest_link=results_dir / "latest",
            benchmark=os.environ.get("BENCHMARK", "aws_compliance.benchmark.all_controls"),
            search_path=os.environ.get("SEARCH_PATH", "admin_only"),
            max_parallel=env_int("MAX_PARALLEL", 1),
            query_timeout=env_int("QUERY_TIMEOUT", 90),
            benchmark_timeout=env_int("BENCHMARK_TIMEOUT", 2700),
            port=env_int("PORT", 9033),
            service_timeout=env_int("SERVICE_TIMEOUT", 30),
            powerpipe_server_wait=env_int("POWERPIPE_SERVER_WAIT", 30),
            steampipe_ready_timeout=env_int("STEAMPIPE_READY_TIMEOUT", 60),
        )


@dataclass(frozen=True)
class ComposeBenchmarkConfig:
    """Runtime settings for Compose-based benchmark execution."""

    workdir: Path
    source_workdir: Path
    results_dir: Path
    run_dir: Path
    latest_link: Path
    home_dir: Path
    host_aws_dir: Path
    config_dir: Path
    connections_file: Path
    workspaces_file: Path
    workspace_name: str
    database_url: str
    database_host: str
    port: int
    host_port: int
    search_path: str
    benchmark: str
    max_parallel: int
    query_timeout: int
    benchmark_timeout: int
    install_mods: bool
    mod_pull: str
    accept_findings: bool
    steampipe_database_port: int
    steampipe_database_password: str

    @classmethod
    def from_env(cls) -> ComposeBenchmarkConfig:
        """Construct a Compose benchmark configuration from environment variables."""
        workdir = Path(os.environ.get("WORKDIR", "/workspace/powerpipe"))
        results_dir = Path(os.environ.get("RESULTS_DIR", str(workdir / "results")))
        stamp = os.environ.get("STAMP") or __import__("datetime").datetime.now().strftime(
            "%Y%m%d-%H%M%S"
        )
        home_dir = Path(os.environ.get("HOME", "/home/powerpipe"))
        config_dir = home_dir / ".powerpipe" / "config"
        return cls(
            workdir=workdir,
            source_workdir=Path(os.environ.get("SOURCE_WORKDIR", "/workspace-src/powerpipe")),
            results_dir=results_dir,
            run_dir=results_dir / stamp,
            latest_link=results_dir / "latest",
            home_dir=home_dir,
            host_aws_dir=Path(os.environ.get("HOST_AWS_DIR", "/host-aws")),
            config_dir=config_dir,
            connections_file=config_dir / "connections.ppc",
            workspaces_file=config_dir / "workspaces.ppc",
            workspace_name=os.environ.get("POWERPIPE_WORKSPACE", "compose"),
            database_url=os.environ.get(
                "POWERPIPE_DATABASE_URL",
                (
                    "postgres://steampipe:"
                    f"{os.environ.get('STEAMPIPE_DATABASE_PASSWORD', 'steampipe')}"
                    "@steampipe:"
                    f"{os.environ.get('STEAMPIPE_DATABASE_PORT', '9193')}"
                    "/steampipe?sslmode=disable"
                ),
            ),
            database_host=os.environ.get("POWERPIPE_DATABASE_HOST", "steampipe"),
            port=env_int("PORT", 9033),
            host_port=env_int("POWERPIPE_HOST_PORT", env_int("PORT", 9033)),
            search_path=os.environ.get("SEARCH_PATH", "admin_only"),
            benchmark=os.environ.get("BENCHMARK", "aws_compliance.benchmark.all_controls"),
            max_parallel=env_int("MAX_PARALLEL", 1),
            query_timeout=env_int("QUERY_TIMEOUT", 90),
            benchmark_timeout=env_int("BENCHMARK_TIMEOUT", 2700),
            install_mods=os.environ.get("POWERPIPE_INSTALL_MODS", "true") == "true",
            mod_pull=os.environ.get("POWERPIPE_MOD_PULL", "latest"),
            accept_findings=os.environ.get("BENCHMARK_ACCEPT_FINDINGS", "false") == "true",
            steampipe_database_port=env_int("STEAMPIPE_DATABASE_PORT", 9193),
            steampipe_database_password=os.environ.get("STEAMPIPE_DATABASE_PASSWORD", "steampipe"),
        )


@dataclass(frozen=True)
class ComposePowerpipeConfig:
    """Runtime settings for the long-lived Compose Powerpipe server."""

    workdir: Path
    source_workdir: Path
    results_dir: Path
    home_dir: Path
    host_aws_dir: Path
    config_dir: Path
    aws_config_dir: Path
    connections_file: Path
    workspaces_file: Path
    workspace_name: str
    port: int
    listen: str
    max_parallel: int
    query_timeout: int
    benchmark_timeout: int
    install_mods: bool
    mod_pull: str
    database_host: str
    database_port: int
    database_password: str

    @classmethod
    def from_env(cls) -> ComposePowerpipeConfig:
        """Construct a Compose Powerpipe server configuration from environment variables."""
        home_dir = Path(os.environ.get("HOME", "/home/powerpipe"))
        config_dir = home_dir / ".powerpipe" / "config"
        return cls(
            workdir=Path(os.environ.get("WORKDIR", "/tmp/powerpipe-runtime-workspace")),
            source_workdir=Path(os.environ.get("SOURCE_WORKDIR", "/workspace-src/powerpipe")),
            results_dir=Path(os.environ.get("RESULTS_DIR", "/workspace-results")),
            home_dir=home_dir,
            host_aws_dir=Path(os.environ.get("HOST_AWS_DIR", "/host-aws")),
            config_dir=config_dir,
            aws_config_dir=home_dir / ".aws",
            connections_file=config_dir / "connections.ppc",
            workspaces_file=config_dir / "workspaces.ppc",
            workspace_name=os.environ.get("POWERPIPE_WORKSPACE", "compose"),
            port=env_int("PORT", 9033),
            listen=os.environ.get("POWERPIPE_LISTEN", "network"),
            max_parallel=env_int("MAX_PARALLEL", 1),
            query_timeout=env_int("QUERY_TIMEOUT", 90),
            benchmark_timeout=env_int("BENCHMARK_TIMEOUT", 2700),
            install_mods=os.environ.get("POWERPIPE_INSTALL_MODS", "true") == "true",
            mod_pull=os.environ.get("POWERPIPE_MOD_PULL", "latest"),
            database_host=os.environ.get("POWERPIPE_DATABASE_HOST", "steampipe"),
            database_port=env_int("STEAMPIPE_DATABASE_PORT", 9193),
            database_password=os.environ.get("STEAMPIPE_DATABASE_PASSWORD", "steampipe"),
        )


@dataclass(frozen=True)
class BootstrapConfig:
    """Feature flags and repository paths for workspace bootstrap."""

    root_dir: Path

    @classmethod
    def from_repo(cls) -> BootstrapConfig:
        """Construct bootstrap configuration from the checked-out repository."""
        return cls(root_dir=Path(__file__).resolve().parents[2])


@dataclass(frozen=True)
class ComposeSteampipeConfig:
    """Runtime settings for the Compose Steampipe service."""

    home_dir: Path
    install_dir: Path
    config_dir: Path
    host_aws_dir: Path
    database_port: int
    database_password: str
    seed_dir: Path
    aws_plugin_version: str
    aws_config_dir: Path
    aws_config_file: Path
    generated_config: Path
    host_config_file: Path
    default_options_file: Path
    database_start_timeout: int
    plugin_start_timeout: int
    all_connection_name: str
    db_root: Path

    @classmethod
    def from_env(cls) -> ComposeSteampipeConfig:
        """Construct a Compose Steampipe configuration from environment variables."""
        home_dir = Path(os.environ.get("HOME", "/home/powerpipe"))
        install_dir = Path(os.environ.get("STEAMPIPE_INSTALL_DIR", str(home_dir / ".steampipe")))
        config_dir = install_dir / "config"
        aws_config_dir = home_dir / ".aws"
        return cls(
            home_dir=home_dir,
            install_dir=install_dir,
            config_dir=config_dir,
            host_aws_dir=Path(os.environ.get("HOST_AWS_DIR", "/host-aws")),
            database_port=env_int("STEAMPIPE_DATABASE_PORT", 9193),
            database_password=os.environ.get("STEAMPIPE_DATABASE_PASSWORD", "steampipe"),
            seed_dir=Path(os.environ.get("STEAMPIPE_SEED_DIR", "/opt/steampipe-seed")),
            aws_plugin_version=os.environ.get("STEAMPIPE_AWS_PLUGIN_VERSION", "1.30.0"),
            aws_config_dir=aws_config_dir,
            aws_config_file=aws_config_dir / "config",
            generated_config=config_dir / "aws-profiles.spc",
            host_config_file=Path(
                os.environ.get("HOST_STEAMPIPE_CONFIG_FILE", "/host-steampipe-config/aws.spc")
            ),
            default_options_file=config_dir / "default.spc",
            database_start_timeout=env_int("STEAMPIPE_DATABASE_START_TIMEOUT", 180),
            plugin_start_timeout=env_int("STEAMPIPE_PLUGIN_START_TIMEOUT", 120),
            all_connection_name=os.environ.get("STEAMPIPE_ALL_CONNECTION_NAME", "aws_all"),
            db_root=install_dir / "db",
        )


@dataclass(frozen=True)
class TailpipeDiscoveryConfig:
    """Runtime settings for host-side Tailpipe discovery."""

    home_dir: Path
    aws_config_file: Path
    profile_selector: str
    discovery_root: Path
    run_dir: Path
    latest_link: Path
    summary_file: Path
    cloudtrail_tsv: Path
    s3_logging_tsv: Path
    profile_tsv: Path
    s3_bucket_limit_per_profile: int
    aws_retry_attempts: int
    aws_retry_base_delay: int

    @classmethod
    def from_env(cls) -> TailpipeDiscoveryConfig:
        """Construct Tailpipe discovery configuration from environment variables."""
        home_dir = Path(os.environ.get("HOME", str(Path.cwd())))
        discovery_root = Path(
            os.environ.get("DISCOVERY_ROOT", "/workspace/powerpipe/results/discovery")
        )
        stamp = os.environ.get("STAMP") or __import__("datetime").datetime.now().strftime(
            "%Y%m%d-%H%M%S"
        )
        run_dir = discovery_root / stamp
        return cls(
            home_dir=home_dir,
            aws_config_file=Path(
                os.environ.get("AWS_CONFIG_FILE", str(home_dir / ".aws" / "config"))
            ),
            profile_selector=os.environ.get("PROFILE_SELECTOR", "admin_only"),
            discovery_root=discovery_root,
            run_dir=run_dir,
            latest_link=discovery_root / "latest",
            summary_file=run_dir / "summary.txt",
            cloudtrail_tsv=run_dir / "cloudtrail.tsv",
            s3_logging_tsv=run_dir / "s3_server_access_logging.tsv",
            profile_tsv=run_dir / "profiles.tsv",
            s3_bucket_limit_per_profile=env_int("DISCOVERY_S3_BUCKET_LIMIT_PER_PROFILE", 250),
            aws_retry_attempts=env_int("AWS_RETRY_ATTEMPTS", 4),
            aws_retry_base_delay=env_int("AWS_RETRY_BASE_DELAY", 2),
        )


@dataclass(frozen=True)
class ComposeTailpipeConfig:
    """Runtime settings for the Compose Tailpipe service."""

    home_dir: Path
    host_aws_dir: Path
    mode: str
    config_dir: Path
    generated_config: Path
    query_file: Path
    collect_from: str
    seed_dir: Path
    pipes_seed_dir: Path
    pipes_install_dir: Path
    discovery_dir: Path
    cloudtrail_discovery_file: Path

    @classmethod
    def from_env(cls) -> ComposeTailpipeConfig:
        """Construct a Compose Tailpipe configuration from environment variables."""
        home_dir = Path(os.environ.get("HOME", "/home/powerpipe"))
        discovery_dir = Path(
            os.environ.get(
                "TAILPIPE_DISCOVERY_DIR", "/workspace/powerpipe/results/discovery/latest"
            )
        )
        return cls(
            home_dir=home_dir,
            host_aws_dir=Path(os.environ.get("HOST_AWS_DIR", "/host-aws")),
            mode=os.environ.get("TAILPIPE_MODE", "idle"),
            config_dir=home_dir / ".tailpipe" / "config",
            generated_config=(home_dir / ".tailpipe" / "config" / "aws.tpc"),
            query_file=Path(
                os.environ.get(
                    "TAILPIPE_QUERY_FILE", "/workspace/tailpipe/queries/cloudtrail_summary.sql"
                )
            ),
            collect_from=os.environ.get("TAILPIPE_COLLECT_FROM", "7d"),
            seed_dir=Path(os.environ.get("TAILPIPE_SEED_DIR", "/opt/tailpipe-seed/home")),
            pipes_seed_dir=Path(
                os.environ.get("TAILPIPE_PIPES_SEED_DIR", "/opt/tailpipe-seed/pipes")
            ),
            pipes_install_dir=Path(os.environ.get("PIPES_INSTALL_DIR", str(home_dir / ".pipes"))),
            discovery_dir=discovery_dir,
            cloudtrail_discovery_file=Path(
                os.environ.get(
                    "TAILPIPE_CLOUDTRAIL_DISCOVERY_FILE", str(discovery_dir / "cloudtrail.tsv")
                )
            ),
        )

"""Tailpipe discovery and Compose runtime services."""

from __future__ import annotations

import csv
import os
import shutil
import time
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path

from .aws_helpers import aws_retry_capture, profile_selected, safe_text
from .config import ComposeTailpipeConfig, TailpipeDiscoveryConfig
from .logging_utils import get_logger
from .runtime import (
    CommandError,
    ensure_commands,
    ensure_dir,
    replace_symlink,
    run_command,
    write_text,
)
from .utility_support import slug

LOGGER = get_logger(__name__)


def _resolve_collect_from(value: str) -> str:
    """Normalize collection windows like ``7d`` into ISO timestamps."""
    if len(value) >= 2 and value[:-1].isdigit() and value[-1] in "smhdw":
        amount = int(value[:-1])
        delta = {
            "s": timedelta(seconds=amount),
            "m": timedelta(minutes=amount),
            "h": timedelta(hours=amount),
            "d": timedelta(days=amount),
            "w": timedelta(weeks=amount),
        }[value[-1]]
        return (datetime.now(UTC) - delta).strftime("%Y-%m-%dT%H:%M:%SZ")
    return value


@dataclass(slots=True)
class TailpipeDiscovery:
    """Discover CloudTrail and S3 logging sources across AWS profiles."""

    config: TailpipeDiscoveryConfig

    def run(self) -> int:
        """Execute discovery and write timestamped TSV outputs."""
        LOGGER.info(
            "starting tailpipe discovery",
            extra={"selector": self.config.profile_selector, "run_dir": str(self.config.run_dir)},
        )
        ensure_commands(("aws",))
        if not self.config.aws_config_file.is_file():
            raise CommandError(f"AWS config not found: {self.config.aws_config_file}")
        ensure_dir(self.config.run_dir)
        self._init_tsv_files()
        summary = self._discover()
        self._write_summary(summary)
        if summary["usable_profiles"] == 0:
            raise CommandError(
                "No usable AWS profiles were authenticated for selector "
                f"{self.config.profile_selector}"
            )
        replace_symlink(self.config.run_dir, self.config.latest_link, relative=True)
        print(self.config.run_dir)
        LOGGER.info("tailpipe discovery completed", extra={"run_dir": str(self.config.run_dir)})
        return 0

    def _init_tsv_files(self) -> None:
        """Create TSV files with headers using the csv module."""
        for path, headers in (
            (self.config.profile_tsv, ("profile", "account_id", "role_arn", "selector")),
            (
                self.config.cloudtrail_tsv,
                (
                    "profile",
                    "account_id",
                    "trail_name",
                    "bucket",
                    "prefix",
                    "home_region",
                    "is_multi_region",
                ),
            ),
            (
                self.config.s3_logging_tsv,
                (
                    "profile",
                    "account_id",
                    "source_bucket",
                    "source_region",
                    "target_bucket",
                    "target_prefix",
                ),
            ),
        ):
            with path.open("w", encoding="utf-8", newline="") as handle:
                writer = csv.writer(handle, delimiter="\t")
                writer.writerow(headers)
            path.chmod(0o600)

    def _write_summary(self, summary: dict[str, int]) -> None:
        """Write the discovery run summary to disk."""
        write_text(
            self.config.summary_file,
            "\n".join(
                (
                    f"Profiles selected: {summary['selected_count']}",
                    f"Profiles usable: {summary['usable_profiles']}",
                    f"CloudTrail rows: {summary['cloudtrail_rows']}",
                    f"S3 access logging rows: {summary['s3_logging_rows']}",
                    f"S3 buckets checked: {summary['s3_bucket_checks']}",
                    f"S3 buckets skipped by limit: {summary['s3_bucket_skipped']}",
                    f"S3 bucket limit per profile: {self.config.s3_bucket_limit_per_profile}",
                    f"Run directory: {self.config.run_dir}",
                    "",
                )
            ),
        )

    def _discover(self) -> dict[str, int]:
        stats = {
            "selected_count": 0,
            "usable_profiles": 0,
            "cloudtrail_rows": 0,
            "s3_logging_rows": 0,
            "s3_bucket_checks": 0,
            "s3_bucket_skipped": 0,
        }
        profiles_result = aws_retry_capture(
            ("aws", "configure", "list-profiles"),
            self.config.aws_retry_attempts,
            self.config.aws_retry_base_delay,
        )
        profiles = tuple(filter(None, profiles_result.stdout.splitlines()))
        for profile_name in filter(
            lambda name: profile_selected(name, self.config.profile_selector), profiles
        ):
            stats["selected_count"] += 1
            account_id, arn = self._get_identity(profile_name)
            if not account_id:
                continue
            stats["usable_profiles"] += 1
            self._append_profile(profile_name, account_id, arn)
            stats["cloudtrail_rows"] += self._discover_trails(profile_name, account_id)
            bucket_stats = self._discover_buckets(profile_name, account_id)
            stats["s3_logging_rows"] += bucket_stats["logging_rows"]
            stats["s3_bucket_checks"] += bucket_stats["checks"]
            stats["s3_bucket_skipped"] += bucket_stats["skipped"]
        return stats

    def _get_identity(self, profile_name: str) -> tuple[str, str]:
        """Return the account ID and ARN for the given profile."""
        account = aws_retry_capture(
            (
                "aws",
                "sts",
                "get-caller-identity",
                "--profile",
                profile_name,
                "--query",
                "Account",
                "--output",
                "text",
            ),
            self.config.aws_retry_attempts,
            self.config.aws_retry_base_delay,
        ).stdout.strip()
        if not account or account == "None":
            return "", ""
        arn = aws_retry_capture(
            (
                "aws",
                "sts",
                "get-caller-identity",
                "--profile",
                profile_name,
                "--query",
                "Arn",
                "--output",
                "text",
            ),
            self.config.aws_retry_attempts,
            self.config.aws_retry_base_delay,
        ).stdout.strip()
        return account, safe_text(arn)

    def _append_profile(self, profile_name: str, account_id: str, arn: str) -> None:
        with self.config.profile_tsv.open("a", encoding="utf-8", newline="") as handle:
            csv.writer(handle, delimiter="\t").writerow(
                (profile_name, account_id, arn, self.config.profile_selector)
            )

    def _discover_trails(self, profile_name: str, account_id: str) -> int:
        """Discover CloudTrail trails and append them to the TSV."""
        output = aws_retry_capture(
            (
                "aws",
                "cloudtrail",
                "describe-trails",
                "--profile",
                profile_name,
                "--include-shadow-trails",
                "--query",
                "trailList[?S3BucketName!=null].[Name,S3BucketName,S3KeyPrefix,HomeRegion,IsMultiRegionTrail,IsOrganizationTrail]",
                "--output",
                "text",
            ),
            self.config.aws_retry_attempts,
            self.config.aws_retry_base_delay,
        ).stdout
        if not output.strip():
            return 0
        rows = tuple(filter(None, output.splitlines()))
        added = 0
        with self.config.cloudtrail_tsv.open("a", encoding="utf-8", newline="") as handle:
            writer = csv.writer(handle, delimiter="\t")
            for line in rows:
                parts = tuple(line.split("\t"))
                if len(parts) >= 5 and parts[0] and parts[1]:
                    writer.writerow(
                        (
                            profile_name,
                            account_id,
                            safe_text(parts[0]),
                            safe_text(parts[1]),
                            safe_text(parts[2]),
                            safe_text(parts[3]),
                            safe_text(parts[4]),
                        )
                    )
                    added += 1
        return added

    def _discover_buckets(self, profile_name: str, account_id: str) -> dict[str, int]:
        """Discover S3 buckets and their logging status."""
        stats = {"logging_rows": 0, "checks": 0, "skipped": 0}
        bucket_list = aws_retry_capture(
            (
                "aws",
                "s3api",
                "list-buckets",
                "--profile",
                profile_name,
                "--query",
                "Buckets[].Name",
                "--output",
                "text",
            ),
            self.config.aws_retry_attempts,
            self.config.aws_retry_base_delay,
        ).stdout.split()

        with self.config.s3_logging_tsv.open("a", encoding="utf-8", newline="") as handle:
            writer = csv.writer(handle, delimiter="\t")
            for bucket_name in bucket_list:
                if (
                    self.config.s3_bucket_limit_per_profile > 0
                    and stats["checks"] >= self.config.s3_bucket_limit_per_profile
                ):
                    stats["skipped"] += 1
                    continue
                stats["checks"] += 1
                region = self._get_bucket_region(profile_name, bucket_name)
                target_bucket, target_prefix = self._get_bucket_logging(profile_name, bucket_name)
                if target_bucket:
                    writer.writerow(
                        (
                            profile_name,
                            account_id,
                            safe_text(bucket_name),
                            safe_text(region),
                            safe_text(target_bucket),
                            safe_text(target_prefix),
                        )
                    )
                    stats["logging_rows"] += 1
        return stats

    def _get_bucket_region(self, profile_name: str, bucket_name: str) -> str:
        region = aws_retry_capture(
            (
                "aws",
                "s3api",
                "get-bucket-location",
                "--profile",
                profile_name,
                "--bucket",
                bucket_name,
                "--query",
                "LocationConstraint",
                "--output",
                "text",
            ),
            self.config.aws_retry_attempts,
            self.config.aws_retry_base_delay,
        ).stdout.strip()
        return "us-east-1" if region == "None" else region

    def _get_bucket_logging(self, profile_name: str, bucket_name: str) -> tuple[str, str]:
        target = aws_retry_capture(
            (
                "aws",
                "s3api",
                "get-bucket-logging",
                "--profile",
                profile_name,
                "--bucket",
                bucket_name,
                "--query",
                "LoggingEnabled.TargetBucket",
                "--output",
                "text",
            ),
            self.config.aws_retry_attempts,
            self.config.aws_retry_base_delay,
        ).stdout.strip()
        if not target or target == "None":
            return "", ""
        prefix = aws_retry_capture(
            (
                "aws",
                "s3api",
                "get-bucket-logging",
                "--profile",
                profile_name,
                "--bucket",
                bucket_name,
                "--query",
                "LoggingEnabled.TargetPrefix",
                "--output",
                "text",
            ),
            self.config.aws_retry_attempts,
            self.config.aws_retry_base_delay,
        ).stdout.strip()
        return target, safe_text(prefix)


@dataclass(slots=True)
class ComposeTailpipeService:
    """Configure and run Tailpipe inside the Compose environment."""

    config: ComposeTailpipeConfig

    def run(self) -> int:
        """Dispatch the configured Tailpipe runtime mode."""
        LOGGER.info("starting compose tailpipe service", extra={"mode": self.config.mode})
        ensure_commands(("tailpipe", "python3"))
        os.environ["AWS_SDK_LOAD_CONFIG"] = "1"
        ensure_dir(self.config.home_dir / ".tailpipe")
        ensure_dir(self.config.config_dir)
        ensure_dir(self.config.home_dir / ".aws")
        ensure_dir(self.config.pipes_install_dir / "extensions" / "duckdb")
        ensure_dir(Path("/tmp"))
        self._sync_host_aws()
        self._seed_tailpipe_home()
        self._build_tailpipe_config()
        selected_mode = {
            "smoke": self._run_smoke,
            "query-file": self._run_query_file,
            "idle": self._run_idle,
        }.get(self.config.mode)
        if selected_mode is None:
            raise CommandError(f"Unsupported TAILPIPE_MODE={self.config.mode}")
        return selected_mode()

    def _sync_host_aws(self) -> None:
        if self.config.host_aws_dir.is_dir():
            shutil.copytree(
                self.config.host_aws_dir, self.config.home_dir / ".aws", dirs_exist_ok=True
            )

    def _seed_tailpipe_home(self) -> None:
        if (
            self.config.seed_dir.is_dir()
            and not (self.config.home_dir / ".tailpipe" / "plugins").exists()
        ):
            shutil.copytree(
                self.config.seed_dir, self.config.home_dir / ".tailpipe", dirs_exist_ok=True
            )
        if (
            self.config.pipes_seed_dir.is_dir()
            and not (self.config.pipes_install_dir / "plugins").exists()
        ):
            shutil.copytree(
                self.config.pipes_seed_dir, self.config.pipes_install_dir, dirs_exist_ok=True
            )

    def _build_tailpipe_config(self) -> None:
        if not self.config.cloudtrail_discovery_file.is_file():
            raise CommandError(
                f"CloudTrail discovery file not found: {self.config.cloudtrail_discovery_file}"
            )
        rows = tuple(
            filter(
                None,
                self.config.cloudtrail_discovery_file.read_text(
                    encoding="utf-8", errors="ignore"
                ).splitlines()[1:],
            )
        )
        if not rows:
            raise CommandError(
                f"No discovered CloudTrail sources found in {self.config.cloudtrail_discovery_file}"
            )
        blocks: list[str] = []
        current_connection = ""
        partitions_added = 0
        for row in rows:
            profile_name, account_id, trail_name, bucket_name, bucket_prefix, *_ = (
                row.split("\t") + ["", "", ""]
            )[:7]
            if not (profile_name and trail_name and bucket_name):
                continue
            connection_name = slug(profile_name)
            if connection_name != current_connection:
                blocks.append(
                    "\n".join(
                        (
                            f'connection "aws" "{connection_name}" {{',
                            f'  profile = "{profile_name}"',
                            "}",
                            "",
                        )
                    )
                )
                current_connection = connection_name
            partition_name = slug(f"{profile_name}_{trail_name}")
            file_layout = (
                f"AWSLogs/(%{{DATA:org_id}}/)?{account_id}/CloudTrail/%{{DATA:region}}/%{{YEAR:year}}/%{{MONTHNUM:month}}/%{{MONTHDAY:day}}/%{{DATA}}.json.gz"
                if account_id
                else ""
            )
            partition_lines = [
                f'partition "aws_cloudtrail_log" "{partition_name}" {{',
                '  source "aws_s3_bucket" {',
                f"    connection = connection.aws.{connection_name}",
                f'    bucket     = "{bucket_name}"',
            ]
            if file_layout:
                partition_lines.append(f"    file_layout = `{file_layout}`")
            elif bucket_prefix:
                partition_lines.append(f'    prefix     = "{bucket_prefix}"')
            partition_lines.extend(("  }", "}", ""))
            blocks.append("\n".join(partition_lines))
            partitions_added += 1
        if partitions_added == 0:
            raise CommandError(
                "No CloudTrail-backed Tailpipe partitions were generated from "
                f"{self.config.cloudtrail_discovery_file}"
            )
        write_text(self.config.generated_config, "\n".join(blocks))

    def _run_query_file(self) -> int:
        if not self.config.query_file.is_file():
            raise CommandError(f"Tailpipe query file not found: {self.config.query_file}")
        query = self.config.query_file.read_text(encoding="utf-8", errors="ignore").replace(
            "\n", " "
        )
        LOGGER.info(
            "running tailpipe query file", extra={"query_file": str(self.config.query_file)}
        )
        return run_command(("tailpipe", "query", query)).returncode

    def _run_smoke(self) -> int:
        LOGGER.info(
            "running tailpipe smoke collection", extra={"collect_from": self.config.collect_from}
        )
        run_command(
            (
                "tailpipe",
                "collect",
                "aws_cloudtrail_log",
                "--from",
                _resolve_collect_from(self.config.collect_from),
                "--progress=false",
            )
        )
        return self._run_query_file()

    def _run_idle(self) -> int:
        while True:
            time.sleep(3600)

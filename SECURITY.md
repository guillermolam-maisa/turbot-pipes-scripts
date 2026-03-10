# Security Posture

This workspace is an operational benchmark runner, not a general-purpose web application. "Production ready" here means predictable execution, controlled secrets handling, repeatable artifacts, and minimized local attack surface.

## Baseline controls

- The benchmark runner is idempotent: every run creates a timestamped result directory and only promotes `results/latest` after a completed run or a run that produced exported artifacts.
- Benchmark defaults stay constrained: `MAX_PARALLEL=1`, `QUERY_TIMEOUT=90`, and `BENCHMARK_TIMEOUT=2700`.
- Docker Compose runs as a non-root user, drops all Linux capabilities, uses `no-new-privileges`, and keeps the container root filesystem read-only.
- AWS credentials are mounted read-only in Compose. Steampipe state stays isolated under the mounted `${HOME_DIR}/.steampipe`.
- Benchmark execution writes audit-friendly artifacts under `results/<timestamp>/`.

## OWASP-aligned hardening

- Broken access control: run with least-privilege AWS profiles and keep `admin_only` as the first validation path.
- Cryptographic failures: do not bake AWS credentials into scripts, images, or repository files.
- Injection: shell entrypoints validate command presence and avoid `eval`.
- Insecure design: orchestration is file-based and repeatable through `Taskfile.yml`, not manual copy/paste shell sessions.
- Security misconfiguration: compose services run non-root with a read-only root filesystem and dropped capabilities.
- Vulnerable components: `scripts/vendor-local-binaries.sh` snapshots the exact local Powerpipe and Steampipe binaries used for the container build.
- Identification and authentication failures: credential material is externalized to mounted host configuration.
- Software and data integrity failures: validation and vendoring scripts make the local runtime explicit before compose execution.
- Security logging and monitoring failures: each run captures benchmark logs plus Steampipe and plugin diagnostics.
- SSRF and related outbound abuse: the workspace only needs AWS and local Steampipe connectivity; the compose setup avoids extra service exposure beyond the optional dashboard port.

## MITRE ATT&CK-aligned mitigations

The request referenced "mttr attack framework". This has been interpreted as MITRE ATT&CK.

- Credential access: AWS credentials are mounted read-only and never copied into result artifacts.
- Persistence: repeated runs kill stale benchmark and dashboard processes before execution.
- Defense evasion: the validation script checks the exact local script set and container wiring before execution.
- Discovery and lateral movement: compose services expose only the optional dashboard port and otherwise rely on local mounted state.
- Impact: result promotion is gated so incomplete runs do not silently replace the last known-good artifact set.

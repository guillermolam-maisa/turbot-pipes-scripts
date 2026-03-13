# Turbot Pipes Scripts

Private repository for Turbot Pipes-related scripts, queries, dashboards, benchmarks, workflows, detections, and supporting documentation.

## Purpose

This repository centralizes assets used across the Turbot Pipes ecosystem so they can be managed as code with version control, peer review, traceability, portability, and disaster recovery in mind.

## Scope

- `steampipe/` for queries, mods, and inventory-related SQL assets
- `powerpipe/` for dashboards, controls, benchmarks, and reporting assets
- `flowpipe/` for workflow-as-code automation
- `tailpipe/` for log analysis, detections, and related artifacts
- `docs/` for operational and contributor documentation

## Getting Started

Add assets under the relevant service directory and document any repository-specific workflows in `docs/`.

## Benchmark Operations

Host bootstrap automation in this repository currently targets Linux `x86_64/amd64`. Other platforms require manual installation of the host prerequisites before using the repo workflows.

Core orchestration is now implemented as a Python 3.13 project under `src/turbot_ops` with Poetry metadata in [`pyproject.toml`](/home/kali-user/turbot/pyproject.toml). The legacy shell entrypoints remain in place as thin compatibility wrappers for existing task and Compose interfaces.

This repository now includes a production-oriented AWS compliance benchmark runner under [powerpipe/run-all-controls-safe.sh](/home/kali-user/turbot/powerpipe/run-all-controls-safe.sh). The runner is designed to be idempotent, safe to invoke with `bash`, and aligned with the local process-hygiene requirements used for Powerpipe and Steampipe.

Primary entrypoints:

- `bash ./scripts/bootstrap-workspace.sh`
- `bash ./scripts/doctor.sh`
- `cd ./powerpipe && powerpipe mod install`
- `bash ./scripts/validate-workspace.sh`
- `bash ./scripts/vendor-local-binaries.sh`
- `bash ./powerpipe/run-all-controls-safe.sh`
- `task bootstrap`
- `task doctor`
- `task benchmark:smoke`
- `task benchmark:admin`
- `task benchmark:all`

Container orchestration is defined in `compose.yaml`, and hardening notes are documented in `SECURITY.md`.

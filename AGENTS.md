# Powerpipe / Steampipe working rules

## Safety and shell behavior
- Never tell me to paste a script body directly into the current shell.
- Always write scripts to files, then run them with `bash <file>` or `chmod +x <file> && ./<file>`.
- Never use `source` for generated scripts.
- Refuse to add `exit`, `return`, or `set -euo pipefail` to my interactive shell session.

## Process hygiene
Before any benchmark run:
- `pkill -f "powerpipe benchmark run" || true`
- `pkill -f "powerpipe server" || true`
- `steampipe service restart`

Before starting `powerpipe server`:
- check whether port 9033 is already in use
- if already in use by Powerpipe, reuse it
- if in use by another process, stop and explain

## Benchmark defaults
- Prefer `SEARCH_PATH=admin_only` first for clean validation.
- Only use `SEARCH_PATH=all` after the admin-only path is working.
- Default to `MAX_PARALLEL=1`.
- Default to `QUERY_TIMEOUT=90`.
- Default to `BENCHMARK_TIMEOUT=2700`.
- Do not raise parallelism unless you prove it is stable.

## Success criteria
- Script is idempotent.
- Script does not close my interactive bash shell.
- `admin_only` benchmark/control runs succeed cleanly.
- `all` runs do not exhaust Steampipe connection slots.
- Results go to a timestamped directory.
- `results/latest` is updated only after a run completes.

## Working style
- Reproduce the issue first.
- Make one focused change at a time.
- Re-run the exact failing command after each fix.
- Summarize what changed and why.

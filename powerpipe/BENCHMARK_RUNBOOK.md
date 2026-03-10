# Benchmark Runner

Use the runner with `bash`, not `source`.

From the repository root:

```bash
cd /path/to/turbot-pipes-scripts
```

Admin-only validation:

```bash
SEARCH_PATH=admin_only MAX_PARALLEL=1 QUERY_TIMEOUT=90 BENCHMARK_TIMEOUT=2700 bash ./powerpipe/run-all-controls-safe.sh
```

All-accounts validation:

```bash
SEARCH_PATH=all MAX_PARALLEL=1 QUERY_TIMEOUT=90 BENCHMARK_TIMEOUT=2700 bash ./powerpipe/run-all-controls-safe.sh
```

Optional narrower smoke test with the same safety wrapper:

```bash
SEARCH_PATH=admin_only BENCHMARK=aws_compliance.benchmark.all_controls_account MAX_PARALLEL=1 QUERY_TIMEOUT=90 BENCHMARK_TIMEOUT=2700 bash ./powerpipe/run-all-controls-safe.sh
```

Each run writes a timestamped directory under `powerpipe/results/`. `powerpipe/results/latest` is updated only after the run returns and only when the run completed cleanly or produced exported artifacts.

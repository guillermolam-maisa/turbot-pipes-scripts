# Benchmark Runner

Use the local wrapper with `bash`, not `source`, when you want host-managed processes:

```bash
cd /home/kali-user/turbot
SEARCH_PATH=admin_only MAX_PARALLEL=1 QUERY_TIMEOUT=90 BENCHMARK_TIMEOUT=2700 bash ./powerpipe/run-all-controls-safe.sh
```

Use Docker Compose when you want service lifecycle control that mirrors the later Helm split:

```bash
cd /home/kali-user/turbot
bash ./scripts/vendor-local-binaries.sh
docker compose up -d steampipe powerpipe
docker compose --profile runner run --rm -e SEARCH_PATH=admin_only -e BENCHMARK=aws_compliance.benchmark.all_controls_account -e BENCHMARK_ACCEPT_FINDINGS=true runner
```

Optional Tailpipe toolbox container for CloudTrail collection and query using profiles from `~/.aws/config`:

```bash
cd /home/kali-user/turbot
env PROFILE_SELECTOR=admin_only DISCOVERY_ROOT=powerpipe/results/discovery bash ./scripts/discover-tailpipe-sources.sh
docker compose --profile tailpipe run --rm -e TAILPIPE_MODE=smoke tailpipe
```

Each benchmark run writes a timestamped directory under `results/`. `results/latest` is updated only after a run returns with exported artifacts.

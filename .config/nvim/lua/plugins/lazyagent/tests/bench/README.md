# ACP benchmark harness

This headless harness uses only deterministic fake agents and temporary fixtures. It does not read the user cache, contact a network service, or enforce performance thresholds.

Run from the plugin root with an explicit output path:

```sh
LAZYAGENT_BENCH_OUT=/tmp/lazyagent-acp-bench.json \
LAZYAGENT_BENCH_WARMUP=1 \
LAZYAGENT_BENCH_SAMPLES=3 \
LAZYAGENT_BENCH_LIFECYCLE_LOOPS=50 \
nvim --headless --clean -u NONE -l tests/bench/run.lua
```

The JSON records environment metadata, fixed-GC memory points, resource counts, total p50/p95/max time, provider/RPC wall time, and separately instrumented LazyAgent handler time. These intervals are reported independently and are not assumed to add up. Scenarios cover cold load/first command, new/resume/load activation, Cockpit at 10/100/500 threads, 100/1,000 replay updates, ten-turn growth, repeated open/close, and provider-switch/resession snapshot work.

Compare only runs from the same machine and settings. Keep raw output under an explicit temporary path; commit only a concise reviewed summary.

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

## Visible transcript streaming

```sh
LAZYAGENT_BENCH_OUT=/tmp/lazyagent-view-stream.json \
nvim --headless --clean -u NONE -l tests/bench/view_stream.lua
```

This separate process creates real visible transcript buffers and flushes 16
appends at 1,000 and 12,020 source lines, with and without the 12,000-line limit.
It reports actual full buffer replacements, tail invocations, buffer-to-Lua line
transfers, flush p50/max time, and retained Lua heap delta after GC. Footer
animation is disabled and follow is paused for repeatability. It does not measure
physical display frame times, provider RSS, or Neovim native memory. Inspect max
as well as p50: leaving headroom amortizes a limit rebuild but does not eliminate
its individual latency.

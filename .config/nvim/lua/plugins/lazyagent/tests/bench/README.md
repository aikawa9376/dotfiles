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

`resources.lua` counts actual live libuv handles, loaded/valid buffers, terminals,
autocommands by group, Lua heap, and Neovim process RSS. Closing handles are
excluded. RSS includes native allocations and allocator reserves; it excludes
the agent child's RSS. The replay-update scenarios hydrate without rendering.

Compare only runs from the same machine and settings. Keep raw output under an explicit temporary path; commit only a concise reviewed summary.

## Visible backend lifetime

```sh
LAZYAGENT_BENCH_OUT=/tmp/lazyagent-lifecycle.json \
LAZYAGENT_BENCH_LIFECYCLE_LOOPS=20 \
nvim --headless --clean -u NONE -l tests/bench/lifecycle.lua
```

This starts real local fake ACP child processes and real transcript windows.
Each iteration tests an empty new-thread close and a prompted thread's
resume/load, explicit hide, three native window closes/reopens, and final close.
It checks session/client ownership, callback release, weak client references,
UI queues, view buffers/layout/configuration, global buffers, autocommands,
timers, watchers and child handles. It preserves one growing history thread in
a temporary store; empty promptless threads must be deleted.
The cache lives beside the workspace, outside the snapshot root. Putting it
inside the workspace causes the journal to capture its own growing history and
distorts both memory and shutdown measurements.

Samples run two full GC passes, allowing finalizers and their released references
to settle. The runner also fires `SafeState`: headless `-l` and `vim.wait` do not
enter the ordinary editor input loop, so otherwise the standard matchparen
plugin's one-shot idle callbacks accumulate artificially. The close probe waits
for the bounded one-second session-close fallback before checking references.
Post-GC heap/RSS changes remain measurements, without memory thresholds; this
fixture does not reproduce every installed plugin or a real provider session.

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

## Transcript focus with a pending reply

```sh
LAZYAGENT_BENCH_OUT=/tmp/lazyagent-view-focus.json \
nvim --headless --clean -u NONE -l tests/bench/view_focus.lua
```

This requires installed Markdown and Lua parsers and uses a generated 4,950-line
code history. It measures synchronous BufEnter/WinEnter processing when moving
from the source window into an already visible transcript with a batched reply
pending. Capture lookup counts distinguish viewport work from parsing old code
throughout the history. Three entries cover the initial and subsequent visits;
each checks that the pending response was flushed and retained. The fixture
does not contact a provider or use user transcripts. This headless test does
not send physical mouse input. For same-machine comparisons,
`LAZYAGENT_FOCUS_BASELINE_DIR` may point to saved `view_diff.lua` and `updates.lua`
modules from the previous implementation.

## Large thread manifest saves

```sh
LAZYAGENT_BENCH_OUT=/tmp/lazyagent-thread-store.json \
nvim --headless --clean -u NONE -l tests/bench/thread_store.lua
```

This creates 223 synthetic closed threads with roughly 96KB of detail each,
then reads the manifest and saves one thread's view state ten times. Optional
`LAZYAGENT_BENCH_THREADS` and `LAZYAGENT_BENCH_RECORD_BYTES` adjust the fixture.
It measures operation time, Lua heap and process RSS immediately after each
operation, and Lua heap after GC. These samples are not continuous peak memory
measurements. Fixture generation occurs before measurement; user history and
providers are never accessed. The on-disk schema remains v1. Large manifests
still retain decoded records and cached per-record JSON; this benchmark does
not establish that retention is bounded independently of history size.

## Footer animation

```sh
LAZYAGENT_BENCH_OUT=/tmp/lazyagent-footer.json \
nvim --headless --clean -u NONE -l tests/bench/footer.lua
```

This drives 200 timer frames with real buffers/extmarks and 500 hidden buffers.
It records extmark writes, buffer/window scans, highlight lookups, padding writes,
CPU wall time, and retained Lua heap delta. To compare an earlier implementation,
set `LAZYAGENT_FOOTER_BASELINE` to a saved copy of `view_footer.lua`; the harness
also checks equality of rendered frames across resize, metadata/state changes,
appends, namespace clearing, and color changes. The timer is manually driven for
repeatability, so these timings are processing cost rather than display FPS.

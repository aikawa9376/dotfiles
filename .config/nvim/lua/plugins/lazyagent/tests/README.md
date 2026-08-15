# LazyAgent tests

The reproducible ACP performance harness is documented in [bench/README.md](bench/README.md). It is intentionally excluded from `tests/run.lua` and writes only to an explicit `LAZYAGENT_BENCH_OUT` path.

The credential-sensitive real-provider harness is separately documented in [e2e/README.md](e2e/README.md). It defaults to dry-run, is excluded from the unit suite, and requires explicit provider and authorization gates before spawning anything except the deterministic fake agent.

Run the headless contract suite from the plugin root:

```sh
nvim --headless --clean -u NONE -l tests/run.lua
```

The suite count is intentionally not fixed. Every new suite must be registered in `tests/run.lua`
so this command remains the complete contract run.

`tests/acp/fake_agent.lua` runs as a real child process over stdio. The suite intentionally exercises
fragmented and batched JSON-RPC messages, unknown updates, host requests, capability negotiation,
request timeout/cancellation, session lifecycle methods, and process teardown without requiring a
real ACP provider or external test framework.

# LazyAgent tests

Run the headless contract suite from the plugin root:

```sh
nvim --headless --clean -u NONE -l tests/run.lua
```

`tests/acp/fake_agent.lua` runs as a real child process over stdio. The suite intentionally exercises
fragmented and batched JSON-RPC messages, unknown updates, host requests, capability negotiation,
request timeout/cancellation, session lifecycle methods, and process teardown without requiring a
real ACP provider or external test framework.

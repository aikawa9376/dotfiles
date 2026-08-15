# Opt-in ACP interoperability harness

This harness is excluded from `tests/run.lua`. It always requires an explicit output path and defaults to a no-process dry run:

```sh
LAZYAGENT_E2E_OUT=/tmp/lazyagent-e2e-dry.json \
nvim --headless --clean -u NONE -l tests/e2e/run.lua
```

The deterministic fake-agent validation is also offline and credential-free:

```sh
LAZYAGENT_E2E_OUT=/tmp/lazyagent-e2e-fake.json \
LAZYAGENT_E2E_PROVIDER=fake \
nvim --headless --clean -u NONE -l tests/e2e/run.lua
```

Real providers are allowlisted as `codex`, `claude`, `gemini`, or `copilot`. Execution additionally requires `LAZYAGENT_E2E_AUTHORIZED=I_UNDERSTAND`, an argv-only JSON command in `LAZYAGENT_E2E_COMMAND_JSON`, and explicit user authorization outside the harness. Mutation requires the separate scenario and `LAZYAGENT_E2E_MUTATION_AUTHORIZED=I_UNDERSTAND_MUTATION`. Never put credentials in the command JSON or output.

For real providers, `read-only-smoke` performs initialize/new, a fixed no-tool prompt, cancel, capability-gated list/load/resume, and close. `mutation` asks the agent to create only `e2e-marker.txt` in the isolated workspace, verifies its exact contents, and removes the whole workspace during cleanup. The host filesystem handler allowlists only that marker path and does not provide a terminal handler.

Results contain only redacted version, platform, capability, scope, per-operation status, update count, and mutation source. `unsupported` is written only after an advertised capability snapshot; a missing install remains `not-run`. A mutation result cannot pass unless the exact marker was observed; operations that were not exercised remain `not-run`.

## Failure lifecycle harness

High-risk process interruption is isolated in `run_failure.lua` and is not part of the default suite or the ordinary smoke harness. Its allowlist is limited to `fake`, `codex`, and `copilot`; a real provider requires `LAZYAGENT_E2E_FAILURE_AUTHORIZED=I_UNDERSTAND_FAILURE`. `pending-permission-close` additionally requires `LAZYAGENT_E2E_MUTATION_AUTHORIZED=I_UNDERSTAND_MUTATION`.

The four explicit scenarios are `restart-reopen`, `owned-process-crash`, `timeout-late-update`, and `pending-permission-close`. Process termination is performed only through the `Client.process` handle created by the harness. Every scenario checks that process, stdio, callbacks, timers, and pending host requests return to zero and deletes its isolated temporary workspace.

Run the deterministic offline fixtures first:

```sh
for scenario in restart-reopen owned-process-crash timeout-late-update pending-permission-close; do
  LAZYAGENT_E2E_OUT="/tmp/lazyagent-e2e-fake-${scenario}.json" \
  LAZYAGENT_E2E_PROVIDER=fake \
  LAZYAGENT_E2E_SCENARIO="$scenario" \
  nvim --headless --clean -u NONE -l tests/e2e/run_failure.lua
done
```

For an authorized provider, also pass an argv-only `LAZYAGENT_E2E_COMMAND_JSON`, the failure authorization token, and the mutation token for the permission scenario. The Codex fixture sets only the new session's mode to `read-only`, where edits require approval, before requesting the isolated marker. It does not change global or account configuration. A provider that still does not request permission records `close_pending_permission=not-run`.

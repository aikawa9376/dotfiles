---
name: lazyagent-team-builder
description: Design, create, and refine task-specific LazyAgent Teams in `.lazyagent/teams.json`. Use when the user asks to assemble an optimal team for a request, choose LazyAgent roles or reporting structure, generate or update a Teams JSON catalog, or prepare a project to run `LazyAgentTeam`.
---

# LazyAgent Team Builder

Turn a concrete request into the smallest useful LazyAgent Team, write it into the project's
`.lazyagent/teams.json`, and validate it with LazyAgent's own config loader.

## Workflow

1. Identify the project root and the request the team will execute.
2. Inspect the repository enough to understand work boundaries, languages, tests, and likely
   file overlap. Read an existing `.lazyagent/teams.json` before proposing changes.
3. Discover available LazyAgent provider IDs from existing project/user configuration when
   practical. Never invent provider, model, or effort IDs. Omit optional `model` and `effort`
   when availability is uncertain.
4. Decide whether a team is warranted:
   - Use one member for small, tightly coupled, or sequential work.
   - Add a member only for an independently delegable outcome, distinct expertise, or
     independent verification.
   - Prefer 2–4 members. Ask before exceeding four unless the request explicitly requires a
     larger organization.
5. Define one lead responsible for scope, delegation, integration, and the final response.
   Give every non-lead exactly one manager through `reports`.
6. Minimize write conflicts:
   - Let one implementation role own tightly coupled files.
   - Use research/review roles without worktrees when they only inspect.
   - Enable separate worktrees only for independent code changes that can be integrated cleanly.
7. Write concise, outcome-oriented role instructions. Put long or reusable instructions in
   `.lazyagent/roles/<role>.md`; otherwise use inline `instructions`.
8. Merge the team into the existing catalog. Preserve unrelated teams and root settings.
   Set `default_team` only when creating the first catalog or when the user asks to change it.
9. Read [references/teams-json.md](references/teams-json.md), then validate:

   ```bash
   nvim --headless -u NONE -l \
     path/to/lazyagent-team-builder/scripts/validate.lua \
     /absolute/project/.lazyagent/teams.json
   ```

10. Fix every validation error before presenting the result. Summarize the chosen hierarchy,
    why each member exists, worktree usage, and the command to start it.

## Composition Rules

- Optimize for coordination cost, not maximum parallelism.
- Do not create both an architect and a lead when their responsibilities would duplicate.
- Do not give multiple implementers overlapping file ownership without an explicit integration
  boundary.
- Prefer an independent reviewer for high-risk changes; otherwise let the lead review.
- Match effort to responsibility: stronger reasoning for ambiguous integration work, lower effort
  for bounded implementation or mechanical verification. Only set values supported by the
  selected provider.
- Keep `reports` as a shallow tree unless an intermediate manager genuinely aggregates multiple
  workers.
- State deliverables, constraints, owned scope, required verification, and report content in each
  role. Do not restate the runtime's `team_delegate`/`team_report` protocol.

## Editing and Launching

Use a stable, descriptive team ID such as `feature-delivery`, `incident-debug`, or
`security-review`. When updating an existing team, preserve its ID unless the user requests a new
variant.

Creating or editing the JSON does not authorize starting agents. Run `:LazyAgentTeam <team-id>`
only when the user also asks to launch or execute the team. If another team is active, do not stop
or replace it without explicit authorization.

After writing the config, report the exact file path and a launch command:

```vim
:LazyAgentTeam <team-id>
```

If the user supplied the execution request and asked to start immediately:

```vim
:LazyAgentTeam <team-id> <request>
```

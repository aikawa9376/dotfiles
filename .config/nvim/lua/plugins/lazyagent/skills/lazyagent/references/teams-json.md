# LazyAgent Teams JSON

## Location and catalog

Prefer the project file `.lazyagent/teams.json`. LazyAgent searches the project and its parents,
then its global data/config fallbacks.

```json
{
  "version": 1,
  "default_team": "feature-delivery",
  "worktree": false,
  "teams": {
    "feature-delivery": {
      "name": "Feature Delivery",
      "lead": "lead",
      "members": {
        "lead": {
          "agent": "Codex",
          "role": "Technical Lead",
          "instructions": "Plan, delegate independent work, integrate results, and verify the final outcome.",
          "reports": ["implementer"]
        },
        "implementer": {
          "agent": "Codex",
          "role": "Implementation Engineer",
          "instructions": "Implement the assigned scope, run focused tests, and report changed files and risks.",
          "reports": []
        }
      }
    }
  }
}
```

The legacy single-team root form is supported, but write the catalog form for new files so future
teams can be added without migration.

## Fields

Root fields:

- `version`: required; currently `1`.
- `default_team`: optional team ID present in `teams`.
- `worktree`: optional default inherited by teams.
- `teams`: object keyed by team ID.

Team fields:

- `name`: optional display name; defaults to its ID.
- `lead`: required member ID.
- `members`: required object keyed by member ID.
- `worktree`: optional boolean or worktree object inherited by members.

Member fields:

- `agent`: required configured LazyAgent provider ID.
- `role`: optional human-readable role.
- `instructions`: optional inline instructions.
- `instructions_file`: optional project-relative Markdown path, confined to the project and at most
  64 KiB. It is combined with inline instructions.
- `model`, `effort`: optional ACP config values advertised by the provider. Omit unverified values.
- `worktree`: optional team-level override.
- `reports`: array of direct child member IDs; use `[]` for leaves.

Worktree objects accept `enabled`, `path`, `branch`, `base`, and `timeout_ms`. Paths may use
`{team}`, `{role}`, and `{id}` placeholders.

## Structural constraints

- Team and member IDs may contain letters, numbers, `_`, `-`, and `.` and must start with an
  alphanumeric character.
- The lead must exist and must not report to another member.
- Every non-lead member must have exactly one parent.
- The graph must have no cycles and every member must be reachable from the lead.
- Every `reports` target must exist.
- Every `agent` must be configured and ACP-capable when the team starts.
- Worktree-enabled roles require a suitable Git repository.

## Common shapes

Use a single member for a focused request:

```text
lead
```

Use a flat team for independently delegated work:

```text
lead
├── implementer
└── reviewer
```

Add an intermediate manager only when it aggregates several related workers:

```text
lead
└── backend-lead
    ├── api
    └── database
```

Avoid chains that merely pass messages and teams where multiple roles edit the same files.

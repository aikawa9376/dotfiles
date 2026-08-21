# Upstream Obsidian Skills

The format knowledge in this skill follows Steph Ango's MIT-licensed
[`kepano/obsidian-skills`](https://github.com/kepano/obsidian-skills), the
reference Agent Skills repository maintained by Obsidian's creator and CEO.

## Responsibility Boundary

- Upstream is authoritative for Obsidian Markdown, Bases, JSON Canvas,
  Obsidian CLI, and Defuddle syntax and capabilities.
- This skill is authoritative for the local vault layout, note properties,
  `obsidian.nvim` commands, LazyAgent workflows, and the locally bundled
  Defuddle launcher.
- Prefer current Obsidian documentation over either source when behavior has
  changed. Treat the local references as a maintained operational subset, not
  a frozen copy of the product manual.

## Mapping

| Upstream skill | Local reference |
| --- | --- |
| `obsidian-markdown` | `markdown.md` |
| `obsidian-bases` | `bases.md` |
| `json-canvas` | `canvas.md` |
| `obsidian-cli` | `commands.md` |
| `defuddle` | `web-capture.md` |

The local workflow and vault-specific additions live in `conventions.md`,
`workflows.md`, and `html-artifacts.md` and should not be overwritten during
an upstream refresh.

## Refresh Procedure

1. Compare the five upstream `SKILL.md` files and their references with the
   mapped local references above.
2. Bring across semantic changes, new syntax, validation rules, and corrected
   examples. Do not blindly replace local workflow guidance.
3. Check the official Obsidian documentation linked by upstream for features
   that may have changed since the last refresh.
4. Validate example Markdown, YAML, and JSON, then run the LazyAgent test
   suite relevant to skill installation and mounting.
5. Record the reviewed upstream commit below.

## Last Reviewed Revision

- Repository: `https://github.com/kepano/obsidian-skills`
- Commit: `a1dc48e68138490d522c04cbf5822214c6eb1202`
- Reviewed: 2026-08-21

This file records provenance and synchronization intent; it does not imply
that local files are byte-for-byte vendored copies.

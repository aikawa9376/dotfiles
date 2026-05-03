# brain Command Reference

```bash
BRAIN="$LAZYAGENTBIN/ai-memory-cli"
```

## search

```bash
$BRAIN search <QUERY> [OPTIONS]
```

Perform a hybrid search over past conversation history (vector + FTS5 + RRF).

| Argument / Option | Description |
|-------------------|-------------|
| `<QUERY>` | Search query (natural language; Japanese recommended) |
| `--current-project` | Restrict to the current git repository's data |
| `--db-path <PATH>` | Specify the DB file path |

```bash
$BRAIN search "How to fix Rust lifetime errors"
$BRAIN search "sqlx migrate" --current-project
```

## save

```bash
echo '<HOOK_PAYLOAD_JSON>' | $BRAIN save [OPTIONS]
```

Accepts a Gemini CLI SessionEnd Hook payload from stdin and saves the conversation.

| Option | Description |
|-------|-------------|
| `--project <NAME>` | Override project name |
| `--branch <NAME>` | Override branch name |
| `--db-path <PATH>` | Specify DB file path |

## init

```bash
$BRAIN init
```

Initialize the DB (first-time setup; normally created automatically when `save` runs).

## Global Options

| Option | Description |
|--------|-------------|
| `-d, --db-path <PATH>` | DB path (default: `~/.local/share/ai-memory-cli/memory.db`) |
| `-h, --help` | Show help |
| `-V, --version` | Show version |

## Model Specs

| Item | Value |
|------|-------|
| Model | ruri-v3-30m (int8-quantized ONNX) |
| Dimensions | 256 |
| Prefix (on save) | `検索文書: ` |
| Prefix (on search) | `検索クエリ: ` |
| Model files | `~/.local/share/ai-memory-cli/ruri-v3-30m/` |
| DB | `~/.local/share/ai-memory-cli/memory.db` |

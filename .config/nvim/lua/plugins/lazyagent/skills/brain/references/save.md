# brain save — Save Conversation History

Save command invoked from the Gemini CLI SessionEnd Hook.
Normally **the Hook runs automatically**, so manual action is not required.

## Hook Configuration (automatic saves)

If you add the following to `~/.gemini/settings.json`, sessions will be saved automatically on session end:

```json
{
  "hooks": {
    "SessionEnd": [
      {
        "name": "save-memory",
        "type": "command",
        "command": "/bin/sh -lc '$LAZYAGENTBIN/ai-memory-cli save'"
      }
    ]
  }
}
```

If your hook runner does not preserve `LAZYAGENTBIN`, replace
`$LAZYAGENTBIN/ai-memory-cli` with the concrete path from `echo $LAZYAGENTBIN`.

## Manual Save

To save manually without the Hook, pass the Hook payload JSON to stdin:

```bash
BRAIN="$LAZYAGENTBIN/ai-memory-cli"

echo '{
  "session_id": "my-session",
  "transcript_path": "/path/to/transcript.json"
}' | $BRAIN save
```

## Options

| Option | Description |
|--------|-------------|
| `--project <NAME>` | Override project name (default: git repository name) |
| `--branch <NAME>` | Manually specify branch name (default: current git branch) |
| `--db-path <PATH>` | Manually specify DB path |

## What gets saved

- Saves each User/AI pair in the conversation as one record
- Generates embedding vectors with ruri-v3-30m (int8-quantized ONNX), 256 dimensions
- Documents are saved with the `検索文書: ` prefix
- DB: `~/.local/share/ai-memory-cli/memory.db`

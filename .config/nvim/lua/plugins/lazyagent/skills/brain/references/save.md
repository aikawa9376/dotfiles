# brain save — Save Conversation History

In ACP mode, prefer lazyagent's built-in post-turn save instead of provider-native hooks.

## ACP auto-save

Enable this in lazyagent:

```lua
require("lazyagent").setup({
  acp = {
    enabled = true,
    brain_save = {
      enabled = true,
      -- command = { "/absolute/path/to/ai-memory-cli", "save" },
    },
  },
})
```

When `command` is omitted, lazyagent tries `$LAZYAGENTBIN/ai-memory-cli save`.
The payload is sent directly over stdin, so no intermediate transcript JSON is required.

## Provider-native hooks

For non-ACP / direct CLI workflows, provider hooks are still usable. Example for Gemini:

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

## Manual Save

To save manually without hooks, pass the payload JSON to stdin:

```bash
BRAIN="$LAZYAGENTBIN/ai-memory-cli"

echo '{
  "session_id": "my-session",
  "cwd": "/path/to/project",
  "interactions": [
    {
      "user_input": "fix the failing test",
      "assistant_output": "updated the matcher and explained why"
    }
  ]
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

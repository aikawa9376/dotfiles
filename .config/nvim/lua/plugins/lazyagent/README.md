# lazyagent.nvim

Neovim から Gemini / Claude / Codex / Copilot / Cursor などの agent CLI に指示を送るためのローカルプラグインです。

scratch buffer に依頼を書き、tmux pane または ACP transcript buffer に送信します。プロジェクトごとの履歴保存、会話 checkpoint、ACP の model/mode/config picker、MCP hooks による編集後アクションも扱えます。

## 主な機能

| 機能 | 内容 |
| --- | --- |
| Scratch input | float / vsplit の入力バッファから agent に送信 |
| Interactive agents | tmux backend で CLI TUI を管理 |
| ACP mode | ACP 対応 CLI と JSON-RPC で通信し、transcript を tmux または Neovim buffer に表示 |
| History / conversation | scratch 履歴、会話 log、resume 用 checkpoint を cache に保存 |
| Completion | scratch 内の `/` command と `@` path 補完 |
| MCP hooks | 非 ACP agent 向けに Neovim 内 MCP server を起動し、編集通知や quickfix 更新を連携 |
| Session integration | resession 用 snapshot / restore hook を提供 |

## 要件

- Neovim
- `tmux`（`backend = "tmux"` または `tmux_acp` を使う場合）
- 利用する agent CLI（例: `gemini`, `claude`, `codex`, `copilot`, `cursor-agent`）
- `fd`（`@` path 補完の候補生成に使用。無い場合は候補なし）
- `fswatch`（macOS）または `inotifywait`（Linux）: `auto_follow` 使用時に推奨
- `qrencode`: `:LazyAgentQR` 使用時のみ

## インストール例

ローカルプラグインとして `lazy.nvim` から読み込む想定です。

```lua
return {
  "lazyagent",
  dir = os.getenv("XDG_CONFIG_HOME") .. "/nvim/lua/plugins/lazyagent",
  keys = {
    { "c<space><space>", function() require("lazyagent").toggle_session() end, mode = { "n", "x" }, desc = "Toggle AI Agent" },
    { "c<space>i", function() require("lazyagent").open_instant() end, mode = { "n", "x" }, desc = "Instant AI Agent" },
    { "c<space><cr>", function() require("lazyagent").send_enter() end, mode = { "n", "x" }, desc = "Send Enter to Agent" },
  },
  cmd = {
    "LazyAgent", "LazyAgentScratch", "LazyAgentToggle", "LazyAgentClose",
    "LazyAgentEdit", "LazyAgentHistory", "LazyAgentConversationList", "LazyAgentSummary",
    "LazyAgentACPModel", "LazyAgentACPMode", "LazyAgentACPConfig",
    "Claude", "Codex", "Gemini", "Copilot", "Cursor",
  },
  opts = {
    backend = "tmux",
    acp = { enabled = true, view = "buffer" },
  },
}
```

`c<space>` はこの dotfiles の好みです。`c` は Neovim 標準の operator なので、衝突が気になる場合は `<leader>` 系に置き換えてください。

## 基本設定

```lua
require("lazyagent").setup({
  backend = "tmux", -- "tmux" | "builtin"
  window_type = "float", -- "float" | "vsplit"
  close_on_send = true,

  interactive_agents = {
    Gemini = {
      cmd = "gemini",
      acp_cmd = { "gemini", "--acp" },
      yolo = true,
    },
    Copilot = {
      cmd = "copilot",
      acp_cmd = { "copilot", "--acp" },
      yolo = true,
    },
  },

  cache = {
    enabled = true,
    dir = vim.fn.stdpath("cache") .. "/lazyagent",
    max_history = 100,
    conversation_retention = "30d",
  },
})
```

agent ごとの設定は global 設定より優先されます。`interactive_agents.<name>.default = true` を指定すると、起動 agent の候補が複数あるときにその agent を優先します。

## Edit selected blocks

`:LazyAgentEdit` は Avante の edit selected block に近い用途の line-range 編集です。選択範囲と前後 context を one-shot agent CLI に渡し、返ってきた replacement を元バッファ上の inline diff として表示してから適用します。

```vim
:'<,'>LazyAgentEdit make this function async and keep behavior
```

または visual mode / normal mode で `c<space>e` を押すと、編集指示の入力 UI を開きます。normal mode では現在行が対象です。

```lua
require("lazyagent").setup({
  edit_blocks = {
    agent = "Copilot",
    -- 明示したい場合。未指定なら copilot -p, claude -p, gemini -p の順で使えるものを探します。
    -- command = { "copilot", "-p" },
    -- モデルを固定したい場合は CLI ごとの option をここに含めます。
    -- command = { "copilot", "-p", "--model", "gpt-5-mini" },
    command_mode = "arg", -- "arg" or "stdin"
    timeout_ms = 90000,
    context_lines = 80,
    max_context_chars = 24000,
    preview = true,
    auto_apply = false,
    preserve_indent = true,
    keymaps = {
      accept = "ct",
      accept_all = "ca",
      reject = "co",
      reject_alt = "cq",
    },
  },
})
```

`edit_blocks.command` は one-shot agent の実行方法です。未指定なら `edit_blocks.candidates` から実行可能な CLI を探します。値は table / string / function を指定できます。

```lua
edit_blocks = {
  -- table: prompt を最後の引数に追加して実行
  command = { "copilot", "-p", "--model", "gpt-5-mini" },
  command_mode = "arg",

  -- stdin で prompt を渡したい CLI の例
  -- command = { "my-agent", "edit" },
  -- command_mode = "stdin",

  -- function: テストや独自 provider 用。文字列、または { ok, stdout, stderr } を返せます。
  -- command = function(prompt, ctx)
  --   return "<code>" .. ctx.original_lines[1] .. "</code>"
  -- end,
}
```

agent には `<code>...</code>` だけを返すよう指示します。parser は `<code>`、JSON (`replacement` / `code`)、fenced code、raw text の順に受け付けます。inline diff 表示中は `ct` で現在の提案を適用、`ca` で pending edits をまとめて適用、`co` / `cq` / `c0` で破棄できます。適用時には元の選択範囲が変更されていないことを確認するため、遅い agent の応答で別編集を上書きしにくくしています。

## ACP mode

ACP を使う場合は `acp.enabled = true` にします。`view = "buffer"` は transcript を Neovim buffer に表示し、`view = "tmux"` は tmux pane に tail 表示します。

```lua
require("lazyagent").setup({
  acp = {
    enabled = true,
    view = "buffer",
    auto_permission = "allow_always",
    default_mode = "bypassPermissions",
    initial_model = "gpt-5.4",
    transcript_compaction = {
      enabled = true,
      min_sections = 48,
      keep_recent_sections = 24,
      summary_items = 6,
    },
  },
  interactive_agents = {
    Cursor = {
      acp_cmd = { "cursor-agent", "acp" },
      acp_cmd_fallbacks = {
        { "agent", "acp" },
        { "cursor-agent", "--acp" },
      },
    },
  },
})
```

`interactive_agents.<name>.acp = false` で、global ACP 有効時でも特定 agent だけ通常 backend に戻せます。

### ACP local commands

ACP session では以下の slash command を Neovim 側で処理します。

| Command | 内容 |
| --- | --- |
| `/model` | model picker |
| `/mode` | mode picker |
| `/config` | config option picker |
| `/resources` | ACP resource browser |
| `/capabilities` | session capability summary |
| `/new` | session restart |

agent が advertise していない `/...` は通常の prompt text として送信します。

## MCP hooks

`mcp_mode = true` のとき、非 ACP agent がある場合だけ Neovim 内で MCP server を起動します。ACP だけで運用している場合は server を起動しません。

```lua
require("lazyagent").setup({
  mcp_mode = true,
  hooks = {
    open_on_edit = true,
    quickfix_on_edit = true,
    notify_on_done = true,
    git_checkpoint_on_done = false,
    diagnostic_on_done = false,
  },
})
```

MCP integration は cache 配下に agent 用の `AGENTS.md`, hook scripts, MCP config を生成します。Cursor / Copilot 連携では一部 global config も更新します。

## Commands

| Command | 内容 |
| --- | --- |
| `:LazyAgent` / `:LazyAgentToggle [agent]` | scratch buffer を toggle |
| `:LazyAgentScratch [agent]` | scratch buffer を開く |
| `:LazyAgentInstant [agent]` | one-shot 用 scratch を開く |
| `:LazyAgentClose [agent]` | session を閉じる |
| `:LazyAgentRestart [agent]` | session を再起動 |
| `:LazyAgentRestore [agent]` | persisted session を復元 |
| `:LazyAgentDetach [agent]` | session を残して Neovim 側の管理から外す |
| `:LazyAgentAttach [agent] [pane]` | 既存 tmux pane を session として attach |
| `:LazyAgentEdit [request]` | 選択範囲 / 現在行を one-shot agent で編集し preview |
| `:LazyAgentHistory [file]` | 現在 context の scratch 履歴を開く |
| `:LazyAgentHistoryList [file]` | 履歴一覧から開く |
| `:LazyAgentConversationList [file]` | 保存済み会話 log を開く |
| `:LazyAgentConversation [agent] [keep_lines]` | ACP conversation を checkpoint 保存。数値指定時は最新 `keep_lines` 行以上を ACP buffer に残し、それ以前を User セクション境界で保存 |
| `:LazyAgentResumeConversation [file]` | conversation checkpoint から開始 |
| `:LazyAgentOpenConversation [agent]` | live pane / transcript を保存して開く |
| `:LazyAgentSummary [open\|copy]` | summary Markdown を開く / path をコピー |
| `:LazyAgentStack` | scratch 内容を履歴に積んで buffer を空にする |
| `:LazyAgentHooks [flag]` | hook flag の表示 / toggle |
| `:LazyAgentQR` | MCP web UI URL の QR code を表示 |
| `:LazyAgentACPConfig [agent]` | ACP config picker |
| `:LazyAgentACPModel [agent]` | ACP model picker |
| `:LazyAgentACPMode [agent]` | ACP mode picker |
| `:LazyAgentACPReopen [agent]` | ACP transcript window を再表示 |
| `:LazyAgentACPCommands [agent]` | ACP slash command palette |
| `:LazyAgentACPTools [agent]` | ACP tool timeline |
| `:LazyAgentACPResources [agent]` | ACP resource browser |
| `:LazyAgentACPCapabilities [agent]` | ACP capability summary |
| `:Gemini` / `:Claude` / `:Codex` / `:Copilot` / `:Cursor` | agent を直接起動 |

## Scratch tokens

| Token | 展開内容 |
| --- | --- |
| `#history` | 現在の project / branch に対応する最新会話 log への参照 |
| `#report` | summary Markdown の保存先 prefix |

その他の transform は `lua/lazyagent/transforms.lua` と `lua/lazyagent/transforms/` を参照してください。

## Public API

```lua
local lazyagent = require("lazyagent")

lazyagent.setup(opts)
lazyagent.toggle_session("Gemini")
lazyagent.open_instant("Cursor")
lazyagent.send_visual()
lazyagent.send_line()
lazyagent.send_to_cli("Copilot", "Explain this diff")
lazyagent.edit_selection({ request = "simplify this block" })
lazyagent.send_key("Enter")
lazyagent.close_session("Gemini")
lazyagent.get_active_agents()
lazyagent.status()
```

低レベル API は `lazyagent.logic.*` にあります。外部から使う場合は、できるだけ `require("lazyagent")` の facade を優先してください。

## Directory layout

| Path | 責務 |
| --- | --- |
| `lua/lazyagent.lua` | public API と setup lifecycle |
| `lua/lazyagent/config/` | default options |
| `lua/lazyagent/commands/` | user command registration |
| `lua/lazyagent/logic/` | agent/session/cache/send/status などの中核処理 |
| `lua/lazyagent/acp/` | ACP client, backend, transcript view |
| `lua/lazyagent/integrations/` | MCP server lifecycle など外部連携 |
| `lua/lazyagent/completion/` | slash / at completion defaults |
| `lua/lazyagent/resources/` | generated config の元になる markdown / hook scripts |
| `lua/lazyagent/mcp/` | Neovim 内 MCP server 実装 |

## Events

`util.fire_event()` は `callbacks` と `User` autocmd の両方へ通知します。

```lua
require("lazyagent").setup({
  callbacks = {
    EditDone = function(data) vim.notify("edited by " .. tostring(data.agent_name)) end,
    TurnDone = function(data) vim.notify("done: " .. tostring(data.agent_name)) end,
  },
})

vim.api.nvim_create_autocmd("User", {
  pattern = "LazyAgentEditDone",
  callback = function(ev)
    print(vim.inspect(ev.data))
  end,
})
```

主な event は `EditDone`, `TurnDone`, `AssistantResponse`, `SessionStarted`, `SessionStopped` です。

## Backend extension

backend は global または agent 単位で差し替えできます。

```lua
require("lazyagent").setup({
  backend = "builtin",
  backends = {
    mybackend = "my.lazyagent.backend",
  },
  interactive_agents = {
    Gemini = { backend = "mybackend" },
  },
})
```

runtime で登録する場合:

```lua
local backend = require("lazyagent.logic.backend")
backend.register_backend("mybackend", require("my.lazyagent.backend"))
backend.set_default_backend("mybackend")
backend.set_agent_backend("Gemini", "mybackend")
```

既存 session は自動移行しないため、backend を変えた後は session を閉じて開き直してください。

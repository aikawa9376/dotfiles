# lazyagent.nvim

Neovim から Gemini / Claude / Codex / Copilot / Cursor などの agent CLI に指示を送るためのローカルプラグインです。

scratch buffer に依頼を書き、tmux pane または ACP transcript buffer に送信します。プロジェクトごとの履歴保存、会話 checkpoint、ACP の model/mode/config picker、MCP hooks による編集後アクションも扱えます。

## 主な機能

| 機能 | 内容 |
| --- | --- |
| Scratch input | float / vsplit の入力バッファから agent に送信 |
| Interactive agents | tmux backend で CLI TUI を管理 |
| ACP mode | ACP 対応 CLI と JSON-RPC で通信し、transcript を tmux または Neovim buffer に表示 |
| ACP mobile | MCP を使わず、スマホのブラウザから active ACP session へ prompt / interrupt を送信 |
| History / conversation | scratch 履歴、会話 log、resume 用 checkpoint を cache に保存 |
| Completion | scratch 内の `/` command と `@` path 補完 |
| MCP hooks | 非 ACP agent 向けに Neovim 内 MCP server を起動し、編集通知や quickfix 更新を連携 |
| Session integration | resession 用 snapshot / restore hook を提供 |

## 要件

- Neovim
- `tmux`（`backend = "tmux"` または `tmux_acp` を使う場合）
- 利用する agent CLI（例: `gemini`, `claude`, `codex`, `copilot`, `cursor-agent`）
- `curl`（`edit_blocks.transport = "api"` で API edit を使う場合）
- `fd`（`@` path 補完の再帰候補に使用。無い場合も直下候補は利用可能）
- `fswatch`（macOS）または `inotifywait`（Linux）: `auto_follow` 使用時に推奨
- `qrencode`: `:LazyAgentQR` / `:LazyAgentACPMobileQR` 使用時のみ
- 画像ペーストを使う場合は `wl-paste`（Wayland） / `xclip`（X11） / `pngpaste`（macOS, optional） / `osascript`（macOS, built-in）のいずれか
- 画像の長辺を `image_paste.max_dimension` で縮小したい場合は ImageMagick（`magick` / `mogrify` / `convert`）

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
    "LazyAgentACPModel", "LazyAgentACPMode", "LazyAgentACPConfig", "LazyAgentACPMobileQR",
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
  image_paste = {
    enabled = true,
    dir = vim.fn.stdpath("cache") .. "/lazyagent/conversation",
    dir_layout = "conversation", -- "conversation" | "flat"
    max_dimension = 1600, -- 長辺の最大 px。超える場合だけ縮小
    preview = {
      max_width = 80, -- Snacks.image 上の最大セル幅
      max_height = 20, -- Snacks.image 上の最大セル高
    },
  },

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

scratch buffer の画像 paste は buffer-local の `:LazyAgentPasteImage` で使えます。貼り付けた画像は `@/absolute/path/to/image.png` の行として挿入し、`folke/snacks.nvim` の image 機能が使える場合はその直下に preview を出します。さらに `:LazyAgentScreenShot` を実行すると、Linux では `import`（ImageMagick / X11）や `grim+slurp`（Wayland）、macOS では `screencapture -i`、Windows では Snipping Tool / screen clip 経由で範囲選択スクショを撮って同じ形式で貼り付けます。さらに scratch へ画像ファイル path や画像 URL を drag & drop した場合も、`image_paste.drop.enabled = true` なら自動で取り込みます。query string 付きの画像 URL や SVG も対象です。default では `image_paste.dir_layout = "conversation"` なので、画像は `image_paste.dir` 配下に conversation / live transcript / scratch ごとの `.../<scope>/images/` 構成で保存されます。local file はその scope へ copy、URL は download して `@...` に置き換えます。フラット保存に戻したい場合は `image_paste.dir_layout = "flat"` を指定してください。元 path をそのまま使いたい場合は `image_paste.drop.copy = false` にしてください。必要なら `scratch_keymaps.paste_image_normal` / `scratch_keymaps.paste_image_insert` / `scratch_keymaps.paste_image_insert_alt` を自分で設定して keymap を追加できます。

## Skills mount / launch wiring

既定では `lazyagent.nvim` 自身の直下にある `skills/` を見ます。`SKILL.md` を含む skill directory を追加すると、lazyagent 起動時に対応 agent へ渡せます。

```text
lazyagent/
├── skills/
│   ├── reviewer/
│   │   └── SKILL.md
│   └── release-notes/
│       └── SKILL.md
```

```lua
require("lazyagent").setup({
  skills = {
    enabled = true,
    mode = "auto", -- "auto" | "mount" | "flag"
    -- bin_dir = "/path/to/bin", -- default: lazyagent/bin
    mount_dir = "~/.agents/skills", -- fallback for agents that need a visible discovery dir
    agents = {
      Copilot = {
        mode = "flag",
        flag = "--plugin-dir",
        -- env = "COPILOT_SKILLS_DIRS", -- env 経由も使いたいときだけ追加
      },
      Gemini = {
        mode = "mount",
      },
    },
  },
})
```

- 何も指定しなければ `lazyagent/skills` を使います。
- 何も指定しなければ `lazyagent/bin` を基準に、`bin/<os>-<arch>/`（例: `bin/linux-x64`, `bin/darwin-arm64`）があればそちらを優先して `LAZYAGENTBIN` に注入します。platform dir が無ければ従来どおり `lazyagent/bin` を使います。
- local CLI を使う skill は `$LAZYAGENTBIN/<tool>` を見れば OK です。
- lazyagent から起動した agent には `LAZYAGENT_NVIM_BRIDGE_*` が注入され、bundled `nvim-cli-bridge` は socket ではなく file bridge 経由で親 Neovim を操作します。bridge client は shell wrapper + Neovim Lua です。sandbox 内で `NVIM_LISTEN_ADDRESS` の socket 接続が拒否される環境でもこの経路を使います。`nvim-cli` は従来どおり raw socket client のままです。
- Neovim の内蔵 terminal は `nvim-cli-bridge terminal list` / `terminal capture` で確認できます。terminal buffer から ACP scratch を開いた場合は、terminal 出力の短い末尾（既定 40 行 / 約 2.4KB 上限）だけが editor context として自動添付されます。そこで判断できない場合は `nvim-cli-bridge terminal capture --bufnr <bufnr> --last N` で必要な scrollback だけ遡ります。同じ scratch で前回と同一の editor context は hash 付きの unchanged marker だけに圧縮されます。
- 別ディレクトリを使いたいときだけ `skills.source` / `skills.sources` で override します。
- bin 側を変えたいときは `skills.bin_dir` で override できます。
- `mode = "flag"`: 起動 command に agent ごとの skills 用 flag を追加します。現状は Copilot で `--plugin-dir` をサポートします。
- `mode = "mount"`: agent ごとの discovery 制約に応じて runtime skill directory を作ります。Gemini は既定で `~/.cache/nvim/lazyagent/agents/gemini/` 配下の hidden runtime を使い、`GEMINI_CLI_HOME` 経由でそこを見せます。Copilot は `flag` 側なので project / home に skills mount を作りません。
- visible な discovery dir が必要な agent だけ `mount_dir` を使います。workspace ごとに見せたいときは `mount_dir = ".agents/skills"` のように明示します。
- `mode = "auto"`: Copilot は `flag`、それ以外は `mount` を選びます。

global `skills` は `interactive_agents.<name>.skills = { ... }` で agent ごとに override できます。`interactive_agents.<name>.skills = false` でその agent だけ無効化できます。

## Edit selected blocks

`:LazyAgentEdit` は Avante の edit selected block に近い用途の line-range 編集です。選択範囲と前後 context を one-shot agent CLI または API に渡し、返ってきた replacement を元バッファ上の inline diff として表示してから適用します。

```vim
:'<,'>LazyAgentEdit make this function async and keep behavior
```

または visual mode / normal mode で `c<space>e` を押すと、編集指示の入力 UI を開きます。normal mode では現在行が対象です。

```lua
require("lazyagent").setup({
  edit_blocks = {
    agent = "Copilot",
    transport = "command", -- "command" or "api"
    -- command transport: 未指定なら copilot -p, claude -p, gemini -p の順で使えるものを探します。
    -- command = { "copilot", "-p" },
    -- モデルを固定したい場合は CLI ごとの option をここに含めます。
    -- command = { "copilot", "-p", "--model", "gpt-5-mini" },
    command_mode = "arg", -- "arg" or "stdin"
    -- api transport: まずは Copilot provider をサポート。
    -- api = {
    --   provider = "copilot",
    --   model = "gpt-5-mini",
    -- },
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

`edit_blocks.transport = "command"` のときは従来どおり CLI を使います。`edit_blocks.command` は one-shot agent の実行方法で、未指定なら `edit_blocks.candidates` から実行可能な CLI を探します。値は table / string / function を指定できます。

```lua
edit_blocks = {
  transport = "command",
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

`edit_blocks.transport = "api"` のときは `edit_blocks.api` を使います。Copilot provider は Avante と同様に、`~/.config/github-copilot/hosts.json` または `apps.json` から OAuth token を見つけて `https://api.github.com/copilot_internal/v2/token` で chat token に交換し、その token で Copilot Chat API を呼びます。

```lua
edit_blocks = {
  transport = "api",
  command = { "copilot", "-p", "--model", "gpt-5-mini" }, -- transport を command に戻すとき用
  api = {
    provider = "copilot",
    model = "gpt-5-mini",
    -- use_response_api = true, -- codex 系モデルを使うときだけ必要なら明示
    -- extra_body = { max_tokens = 20480 },
  },
}
```

agent には `<code>...</code>` だけを返すよう指示します。parser は `<code>`、JSON (`replacement` / `code`)、fenced code、raw text の順に受け付けます。inline diff 表示中は `ct` で現在の提案を適用、`ca` で pending edits をまとめて適用、`co` / `cq` / `c0` で破棄できます。適用時には元の選択範囲が変更されていないことを確認するため、遅い agent の応答で別編集を上書きしにくくしています。

## ACP mode

ACP を使う場合は `acp.enabled = true` にします。`view = "buffer"` は transcript を Neovim buffer に表示し、`view = "tmux"` は tmux pane に tail 表示します。

Neovim自身がtmux pane内で動作し、`agentmux`が`PATH`にある場合、`view = "buffer"` のACP sessionはagentmuxへ自動公開されます。単一sessionは`Codex (ACP)`のような名前で、複数sessionは一つの`LazyAgent: ...`項目に集約されます。状態はACP lifecycleに合わせて`working` / `blocked` / `idle`へ更新され、previewにはNeovimの編集中bufferではなく、選択されたACP sessionのlive transcriptが末尾追従で表示されます。最後のACP sessionを閉じるかNeovimを終了するとowner確認付きで解除されます。

```lua
require("lazyagent").setup({
  acp = {
    enabled = true,
    view = "buffer",
    table_layout = "card", -- "table" | "card"
    auto_permission = "allow_always",
    default_mode = "bypassPermissions",
    initial_model = "gpt-5.4",
    fancy_mode = true,
    transcript_max_lines = 12000,
    render_markdown_debounce_ms = 900,
    release_buffer_on_hide = true,
    mobile = {
      host = "0.0.0.0", -- LAN のスマホから開く場合。未指定なら 127.0.0.1
      port = nil,       -- nil/0 なら空き port を自動選択
      max_body_bytes = 256 * 1024,
    },
    transcript_compaction = {
      enabled = false,
      min_sections = 48,
      keep_recent_sections = 24,
      summary_items = 6,
    },
    runtime_compaction = {
      enabled = true,
      keep_recent_items = 80,
      keep_recent_tools = 40,
      body_limit = 12000,
      tool_output_limit = 24000,
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
通常の buffer view は default で最新 `transcript_max_lines` 行だけを tail 表示します。全文を確認したい場合は `:LazyAgentACPFullTranscript` または `:LazyAgentACPRawTranscript` を使ってください。

古い transcript section をまとめて最近分を優先表示する `transcript_compaction` は default では無効です。必要な場合だけ `enabled = true` にしてください。`runtime_compaction` は default で有効で、古い runtime timeline は summary/pin 情報だけ残し、詳細本文は recent/pinned item と transcript file に寄せます。

`release_buffer_on_hide = true` では ACP transcript window を閉じたときに表示 buffer を wipe し、再表示時に live transcript file から復元します。agent process/session は維持されます。

`acp.fancy_mode = true` を指定すると、ACP transcript buffer の header / compacted summary / metadata popup を絵文字まみれの display-only skin で表示します。保存される transcript や provider 側の会話内容は変わりません。

`acp.table_layout = "card"` を指定すると、ACP transcript buffer で assistant が返した markdown table を **表示だけ** key/value 形式の card に変換します。保存される transcript や carryover 用の元ログはそのままです。

ACP buffer view は section 境界で未閉じの fenced code block を表示上だけ閉じ、後続 section に Markdown state が漏れないようにします。保存される transcript は変更しません。

### ACP mobile web UI

`:LazyAgentACPMobileQR` はACP mobile serverを起動し、スマホで開くためのQR codeを表示します。`:LazyAgentACPMobileStart` はURLだけを通知し、`:LazyAgentACPMobileStop` で停止します。

このUIはMCP serverを起動せず、active ACP sessionの一覧、prompt送信、interruptだけを提供します。起動ごとにrandom bearer tokenを生成し、QR codeと通知URLへ含めます。未指定時は`127.0.0.1`でlocalhost限定です。LANのスマホから使う場合だけ `acp.mobile.host = "0.0.0.0"` を明示してください。LAN公開時は警告を表示し、token認証、Origin検証、request body上限を適用します。

### ACP local commands

ACP session では以下の slash command を Neovim 側で処理します。

| Command | 内容 |
| --- | --- |
| `/model` | model picker |
| `/mode` | mode picker |
| `/config` | config option picker |
| `/resources` | ACP resource browser |
| `/capabilities` | session capability summary |
| `/doctor` | ACP health diagnostics |
| `/context` | context budget report |
| `/tools` | tool / edit review |
| `/new` | session restart |

agent が advertise していない `/...` は通常の prompt text として送信します。

### ACP transcript buffer keymaps

ACP transcript buffer では `ga` で action menu、`<space><space>` でカーソル下の block / tool metadata を近くの float で開けます。`<localleader>s` で ACP provider（Copilot / Gemini / Cursor など）を会話途中で切り替え、既存 transcript は維持したまま次の prompt に会話履歴を引き継げます。` :LazyAgentACPResumeConversation [agent]` では保存済みの ACP conversation log を同じ carryover 方式で新しい ACP session に読み込めます。`:LazyAgentACPSessions [agent]` では provider 側が保持している native session を一覧し、現在の会話へ add するか、native load / resume できます。float は `q` または `<Esc>` で閉じます。

`:LazyAgentACPChanges [thread-uuid]` は最新turnのchanged files drawerを開きます。`<CR>`で選択fileのbefore/after diff、`a`で全fileをtabごとのreviewとして開けます。`h`でtext changeのhunkを選んでKeep / Reject、`k` / `K`でfile / allをKeep、`r` / `R`でfile / allを確認付きRejectできます。Reject前にuserがtextを再編集していても非重複部分は3-way mergeで保持し、競合時は上書きせず停止します。binary changeは内容をbufferへ展開せず、blob metadataを表示します。

`:LazyAgentACPFollow [agent]` はFollow Agentをthread単位で切り替え、現在のtool locationまたはchanged fileを通常の編集windowへ自動表示します。

changed files drawerでは`u`でturn前のfilesystem checkpointへRestore、`U`でRedo、`b`で親thread/turnとtranscriptを引き継ぐclient-local branchを作成できます。

compaction で省略された以前のやり取りも含めて全文を全画面で見たいときは、`:LazyAgentACPFullTranscript [agent]` を使います。新しい tab に live transcript を開き、**compaction / fancy_mode / card table 変換を無効化した** ACP buffer を表示します。`q` で閉じられます。

`:LazyAgentACPRawTranscript [agent]` は live transcript file を通常ウィンドウにそのまま開く raw log viewer です。

footer は advertise された metadata を使って、provider / native session title / session summary / model / mode / reasoning / context usage / remaining context / turn usage / cumulative usage / provider-specific usage をできるだけ表示します。

ACP の command palette と config picker も advertise された説明・category・input hint をできるだけ表示し、boolean / toggle 系 option は picker から直接切り替えられます。

`:LazyAgentACPDoctor` / `:LazyAgentACPContext` / `:LazyAgentACPReview` は `ga` の action menu と local slash command からも開けます。

ACP agentがimage prompt capabilityを公開している場合、paste / screenshotで挿入された`@image-path`は送信時にfirst-class ACP Image blockへ変換されます。非対応agentには画像データを送信せず、理由をText blockとして渡します。

Assistant messageやtool outputがimage / audio / blob resourceを返した場合は、payloadを`stdpath("cache")/lazyagent/acp/media`へcontent-addressed fileとして保存します。imageはtranscript内でinline previewされ、audio / resourceはMIME・size付きのlocal file参照として表示されます。

ACP agentが広告したslash commandはdescriptionに加え、argument hint / placeholderとrequired・optionalをnvim-cmp / blink.cmpのdetail・documentationへ表示します。

ACP composerでは`@diagnostics`を選ぶと、起点bufferのLSP diagnosticsをfile・line・column・severity付きContextItemとしてpromptへ添付できます。

`@branch-diff`はworkspaceのtracked changesを`HEAD`基準のdiff ContextItemとして添付します。unborn branchではstaged / unstaged差分へfallbackし、既定で512 KiBを上限にします。

`@symbol`は起点bufferのcursorを囲む最も近いTreesitter function / class nodeを、そのsource rangeとversionを保ったContextItemとして添付します。

`acp.brain_save.enabled = true` を入れると、ACP の各 turn 完了後に lazyagent 側から `ai-memory-cli save` を呼びます。既定では `skills.bin_dir`（未指定なら `lazyagent/bin`）配下の `ai-memory-cli` を探し、transcript file ではなく turn の `user/assistant` payload をそのまま stdin で渡します。別コマンドを使いたい場合だけ `acp.brain_save.command = { "/absolute/path/to/ai-memory-cli", "save" }` を指定してください。

## MCP hooks

`mcp_mode = true` のとき、非 ACP agent がある場合だけ Neovim 内で MCP server を起動します。ACP だけで運用している場合は server を起動しません。

```lua
require("lazyagent").setup({
  mcp_mode = true,
  hooks = {
    reload_mode = "hook", -- "hook" (default) or "watch"
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
| `:LazyAgent` / `:LazyAgentToggle[!] [agent]` | scratch buffer を toggle。`!` 付きは scratch の有無に関係なく visible な LazyAgent UI を隠し、session は維持する |
| `:LazyAgentScratch [agent]` | scratch buffer を開く |
| `:LazyAgentInstant [agent]` | one-shot 用 scratch を開く |
| `:LazyAgentClose [agent]` | session を閉じる |
| `:LazyAgentRestart [agent]` | session を再起動 |
| `:LazyAgentRestore [agent]` | persisted session を復元 |
| `:LazyAgentDetach [agent]` | session を残して Neovim 側の管理から外す |
| `:LazyAgentAttach [agent] [pane]` | 既存 tmux pane を session として attach |
| `:LazyAgentACPSwitch [agent]` | 現在の ACP 会話を別 provider に切り替える |
| `:LazyAgentEdit [request]` | 選択範囲 / 現在行を one-shot agent で編集し preview |
| `:LazyAgentHistory [file]` | 現在 context の scratch 履歴を開く |
| `:LazyAgentHistoryList [file]` | 履歴一覧から開く |
| `:LazyAgentConversationList [file]` | 保存済み会話 log を開く |
| `:LazyAgentConversation [agent] [keep_lines]` | ACP conversation を checkpoint 保存。数値指定時は最新 `keep_lines` 行以上を ACP buffer に残し、それ以前を User セクション境界で保存 |
| `:LazyAgentResumeConversation [file]` | conversation checkpoint から開始 |
| `:LazyAgentACPSessions [agent]` | native ACP provider session を一覧し、add / load / resume |
| `:LazyAgentACPFullTranscript [agent]` | compaction と display transform を切った ACP transcript を全画面 tab で開く |
| `:LazyAgentACPRawTranscript [agent]` | compaction なしの ACP live transcript を開く |
| `:LazyAgentOpenConversation [agent]` | live pane / transcript を保存して開く |
| `:LazyAgentSummary [open\|copy]` | summary Markdown を開く / path をコピー |
| `:LazyAgentStack` | scratch 内容を履歴に積んで buffer を空にする |
| `:LazyAgentHooks [flag]` | hook flag の表示 / toggle |
| `:LazyAgentQR` | MCP web UI URL の QR code を表示 |
| `:LazyAgentACPMobileStart` | MCP を使わない ACP mobile web UI server を起動して URL を通知 |
| `:LazyAgentACPMobileQR` | ACP mobile web UI の QR code を表示 |
| `:LazyAgentACPMobileStop` | ACP mobile web UI server を停止 |
| `:LazyAgentACPConfig [agent]` | ACP config picker |
| `:LazyAgentACPModel [agent]` | ACP model picker |
| `:LazyAgentACPMode [agent]` | ACP mode picker |
| `:LazyAgentACPReopen [agent]` | ACP transcript window を再表示 |
| `:LazyAgentACPCommands [agent]` | ACP slash command palette |
| `:LazyAgentACPTools [agent]` | ACP tool timeline |
| `:LazyAgentACPResources [agent]` | ACP resource browser |
| `:LazyAgentACPCapabilities [agent]` | ACP capability summary |
| `:LazyAgentACPDoctor [agent]` | ACP health diagnostics |
| `:LazyAgentACPContext [agent]` | context usage / transcript / compaction budget report |
| `:LazyAgentACPReview [agent]` | ACP tool / edit review report |
| `:Gemini` / `:Claude` / `:Codex` / `:Copilot` / `:Cursor` | agent を直接起動 |

## Scratch tokens

| Token | 展開内容 |
| --- | --- |
| `#cursor-diagnostic-fix` | カーソル位置と、その位置にかかっている diagnostic を展開して、最小変更での修正を依頼 |
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

## Roadmap

ACP の次期実装計画、Zed External Agent との差分、milestoneと完了条件は
[ACP_ROADMAP.md](ACP_ROADMAP.md) で管理します。

plugin全体の保守課題、multi-instance対応、削除候補は [TODO.md](TODO.md) を参照してください。

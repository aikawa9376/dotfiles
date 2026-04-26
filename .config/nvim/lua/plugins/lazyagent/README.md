# lazyagent.nvim

選択テキストや現在行を、設定した「エージェント」（Lua関数または外部CLI）に送信するNeovimプラグインです。CLI 連携には tmux を使った対話型エージェント（例: Gemini / Claude / Codex / Copilot / Cursor）をサポートし、必要なら ACP (Agent Client Protocol) を opt-in で利用できます。スクラッチ入力バッファ、キャッシュ保存、lazy.nvim 互換のキー読み込みを備えています。

主な機能
- ビジュアル選択や現在行のテキストをエージェントへ送信
- tmux を使った対話型エージェント（複数エージェントを設定可能）
- スクラッチ入力バッファ（float/vsplit）と一緒に送信
- スクラッチ内容のキャッシュ（プロジェクトの root と git ブランチに基づいたファイル名で保存）
- lazy.nvim のキー設定で必要時にプラグインを読み込む設計
- Neovim 終了時に自動で tmux セッションを閉じる自動クリーンアップ

---

## インストール

ローカルプラグインとして使うことを想定しています。`lazy.nvim` を利用する例:

```lua
return {
  "lazyagent",
  dir = os.getenv("XDG_CONFIG_HOME") .. "/nvim/lua/plugins/lazyagent",
  -- lazy.nvim の keys 単体でプラグインを読み込むようにする例
  keys = {
    { "<leader>sa", function() require("lazyagent").send_visual() end, mode = "v", desc = "Send Visual to Agent" },
    { "<leader>sl", function() require("lazyagent").send_line() end, mode = "n", desc = "Send Line to Agent" },
    { "c<space><space>", function() require("lazyagent").toggle_session("Gemini") end, mode = "n", desc = "Toggle Gemini Agent" },
    { "<leader>sac", function() require("lazyagent").toggle_session("Claude") end, mode = "n", desc = "Start Claude Agent" },
    { "<leader>sax", function() require("lazyagent").toggle_session("Codex") end, mode = "n", desc = "Start Codex Agent" },
    { "<leader>sag", function() require("lazyagent").toggle_session("Gemini") end, mode = "n", desc = "Start Gemini Agent" },
  },
  cmd = {
    "LazyAgentScratch", "LazyAgentToggle", "LazyAgentClose",
    "Claude", "Codex", "Gemini", "Copilot", "Cursor",
  },
  config = function()
    require("lazyagent").setup()
  end,
}
```

注: `c<space><space>` はユーザ指定のキーです。`c` は operator（change）なので、利用すると operator の挙動に影響する点に注意してください。必要なら `<leader>` など別のキーで登録してください。

---

## オプション（主なもの）

lazyagent の `setup(opts)` で指定可能です。主なデフォルト:

```lua
{
  filetype_settings = { ["*"] = { agent = "Gemini" } },
  prompts = { default_agent = function(context) ... end },
    interactive_agents = {
      Gemini = {
        cmd = "gemini",
        acp_cmd = { "gemini", "--acp" },
        pane_size = 30,
        scratch_filetype = "lazyagent",
        submit_keys = { "C-m" }, -- tmux-style key; "<CR>" and "<c-m>" are accepted and normalized for convenience
        capture_delay = 800,
      -- スクラッチ補完（/ や @ 用）を追加したい場合は scratch_completions を指定してください。
      -- 文字列配列、または配列を返す関数を渡せます。
      -- scratch_completions = {
      --   slash = { "/help", "/agents" },
      --   at = { "@docs", "@manual" },
      -- },
    },
    -- Claude, Codex など
    },
    window_type = "float", -- または "vsplit"
    acp = {
      enabled = false,
      view = "tmux", -- "tmux" または "buffer"
    },
    close_on_send = true, -- 送信後に float を閉じるか
  send_key_insert = "<C-CR>",
  send_key_normal = "<CR>",
  -- キーは lazy.nvim の `keys`（例: plugins/lazyagent/init.lua）で管理することを推奨します
  cache = {
    enabled = true,
    dir = vim.fn.stdpath("cache") .. "/lazyagent",
    debounce_ms = 1500,
    persistence_debounce_ms = 150,
  }
}
```

- キーは lazy.nvim の `keys`（例: `plugins/lazyagent/init.lua`）で管理することを推奨します。
- `cache` を有効にすると、スクラッチバッファを自動的にキャッシュ保存してくれます（詳細は下記）。
- `cache.persistence_debounce_ms` を使うと、`sessions.json` の書き込み頻度を抑えられます（既定: 150ms）。

### バックエンド（backend）の切り替え

lazyagent では、対話式セッションの「バックエンド」として `tmux` / `tmux_acp` / `buffer_acp` / `builtin` をサポートしています。

- `tmux` バックエンド: tmux のペインを作成して対話セッションを管理します（デフォルト）。
- `tmux_acp` バックエンド: tmux の transcript ペインを維持したまま、ACP(JSON-RPC) で agent と通信します。
- `buffer_acp` バックエンド: transcript を Neovim buffer/split に表示したまま、ACP(JSON-RPC) で agent と通信します。
- `builtin` バックエンド: Neovim 内のバッファを擬似ペインとして利用します（tmux を使いたくないときの代替手段）。

バックエンドはグローバル（全エージェントの既定）で設定することも、各エージェント設定で個別に上書きすることも可能です。

- グローバル設定（全エージェントの既定）:

```lua
require("lazyagent").setup({
  backend = "builtin", -- "tmux" / "tmux_acp" / "buffer_acp" / "builtin"
})
```

### ACP モード

既存の使い勝手はそのままに、`acp.enabled = true` を立てたときだけ ACP 対応 agent を起動できます。表示先は `acp.view = "tmux"` または `"buffer"` で切り替えます。

```lua
require("lazyagent").setup({
  acp = {
    enabled = true,
    view = "buffer",
    default_mode = "bypassPermissions",
    auto_permission = "allow_always",
    buffer_background = "#002b36",
    buffer_inactive_background = "#073642",
    -- transcript_max_lines = 4000, -- 未指定なら全件。指定したときだけ末尾 N 行に制限
    permission_rules = {
      { name = "safe-readonly", tool_pattern = "read", action = "allow_once" },
      { name = "block-dotenv", path_pattern = "%.env", action = "manual" },
    },
    auto_switch = {
      enabled = true,
      preserve_manual = true,
      mode_rules = {
        { name = "debug-errors", errors_min = 1, value = "debug" },
      },
      model_rules = {
        { name = "cheap-short-prompts", prompt_length_max = 400, value = "gpt-5-mini" },
        { name = "strong-long-prompts", prompt_length_min = 1200, value = "gpt-5.4" },
      },
    },
  },
  interactive_agents = {
    Gemini = { acp_cmd = { "gemini", "--acp" } },
    Copilot = { acp_cmd = { "copilot", "--acp" } },
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

- デフォルトは `false` なので、既存の tmux ベース運用は変わりません。
- `acp.view = "tmux"` なら `tmux_acp`、`acp.view = "buffer"` なら `buffer_acp` が選ばれます。
- `acp.transcript_max_lines` / `interactive_agents.<name>.acp.transcript_max_lines` を指定すると、`buffer_acp` transcript の読み込みを末尾 N 行に制限できます。未指定なら全件読み込みます。
- `acp.hide_pending_messages` (boolean): ACP の pending 系ステータス（tool の waiting/pending）を transcript に自動追加するのを抑制します（デフォルト: true）。transcript に pending 表示が必要な場合は false に設定してください。
- 最高権限寄りで始めたい場合は、まず provider が expose している mode を `acp.default_mode` で指定するのが本命です。agentic.nvim と同じく、`"bypassPermissions"` のような mode がある provider ではこちらを優先してください。
- `acp.auto_permission = "allow_always"` は fallback としては有効ですが、provider mode を切り替えられない場合の補助です。`yolo = true` だけでは ACP permission は暗黙で `allow_once` までに留めています。
- `interactive_agents.<name>.acp = false` を付けると、global ACP 有効時でもその agent だけ従来 backend を使えます。
- `interactive_agents.<name>.acp = { enabled = true, view = "tmux" }` のように agent 単位で view を上書きできます。
- `acp.buffer_background` / `interactive_agents.<name>.acp.buffer_background` で `buffer_acp` transcript の背景色を指定できます。非アクティブ時だけ別色にしたい場合は `buffer_inactive_background` も使えます。
- `acp.default_mode` / `acp.initial_model` は session ready 後に自動で適用します。agent 単位では `interactive_agents.<name>.acp = { default_mode = "...", initial_model = "..." }` や旧式 alias の `acp_default_mode` / `acp_initial_model` も使えます。
- `acp.permission_rules` を使うと、ACP の構造化 permission request に対して rule-based に `allow_once` / `allow_always` / `reject_once` / `reject_always` / `manual` を選べます。rule は上から順に評価し、agent 単位の `interactive_agents.<name>.acp.permission_rules` が global より先に効きます。
- permission rule の match 条件は `agent`, `agent_pattern`, `cwd`, `cwd_pattern`, `tool`, `tool_pattern`, `title`, `title_pattern`, `kind`, `kind_pattern`, `path`, `path_pattern`, `text_pattern` を使えます。`manual`/`prompt`/`ask` は rule をマッチさせつつ picker にフォールバックさせたいとき用です。
- `acp.auto_switch` を使うと、送信前に model/mode を自動切替できます。`mode_rules` / `model_rules` は上から順に評価し、`value`（または `mode` / `model`）に一致する choice がその session に存在するときだけ適用します。
- auto switch rule の match 条件は `agent`, `agent_pattern`, `cwd`, `cwd_pattern`, `filetype`, `filetype_pattern`, `path`, `path_pattern`, `text_pattern`, `prompt_length_min`, `prompt_length_max`, `prompt_lines_min`, `prompt_lines_max`, `diagnostics_min`, `diagnostics_max`, `errors_min`, `errors_max`, `warnings_min`, `warnings_max` を使えます。
- `acp.auto_switch.preserve_manual = true` のときは、`/model` `/mode` や picker で手動変更した session ではそのキーの自動切替を止めます。restart すると解除されます。
- ACP でも scratch / cache / `#history` / `#report` はそのまま使えます。会話保存は tmux pane ではなく transcript から取ります。
- ACP セッションは lazyagent の独自 MCP server に依存しません。status 更新や permission 応答後の monitor 再開、編集後の open-last-changed も Neovim 側で直接処理します。
- ACP の scratch `/` 補完は agent が `available_commands_update` で advertise した command を正として、足りない分だけ lazyagent 側の `/config` `/model` `/mode` `/resources` `/capabilities` `/new` を補います。
- `/model` `/mode` `/config` は ACP に plain text として送らず、Neovim の `vim.ui.select` で local selector を開きます。provider 側の picker UI をそのまま再現するのではなく、agentic.nvim 寄りの挙動です。
- provider が `thought_level` / `reasoning_effort` を config option として expose している場合は、`/model` や `:LazyAgentACPModel` で model を変えた直後に、その reasoning picker も続けて開きます。
- local ACP command は session capability に合わせて出し分けます。`model` / `mode` / `config` を expose しない provider では command palette と補完候補から隠れます。slash command の merged list は ACP が返した内容を正とし、同名の local action は上書きせず不足分だけ補います。`/capabilities` で現在 session の capability summary を見られます。
- 手動 permission picker に落ちる場合は、選択前に diff/path/resource preview を transcript へ追加します。
- `buffer_acp` では edit tool の構造化 diff を fenced code block として transcript に表示し、追加/削除/変更行には inline diff ハイライトを重ねます。
- `:q` などで `buffer_acp` の transcript window を直接閉じても、transcript buffer は wipe されるだけなので `LazyAgentToggle` でもう一度開き直せます。明示的に戻したいときは `:LazyAgentACPReopen` を使えます。
- `:LazyAgentACPConfig` `:LazyAgentACPModel` `:LazyAgentACPMode` に加えて、`:LazyAgentACPReopen` で transcript reopen、`:LazyAgentACPCommands` で slash command palette、`:LazyAgentACPTools` で tool call timeline、`:LazyAgentACPResources` で resource browser、`:LazyAgentACPCapabilities` で capability summary を開けます。
- ACP で agent から質問や確認が来た場合は、通常どおり scratch buffer から返信してください。generic な質問 picker は使わず、protocol で構造化されている permission request だけを picker で扱います。
- advertise されていないその他の `/...` は plain prompt text として送られます。
- `buffer` view では transcript 末尾に薄い footer 行を実バッファとして保ち、`Thinking...` / `Waiting...` などの進行中ステータスを独立行で表示します。footer メタ情報はその下に 2 行空けて、transcript size、provider/version、current model/mode、reasoning、model usage 倍率（Copilot が expose している場合）、MCP server 数、visible な slash command 数、embedded context 対応をまとめて表示します。
- この footer は transcript window 幅に合わせて折り返され、更新時は末尾が見えるように view を調整します。
- footer/statusline/float は使わず、会話バッファ自身の末尾に情報を寄せるので、window focus や globalstatus 設定に影響されません。
- `mcp_mode` は ACP では必須ではありません。true のままでも、全 agent が ACP で動く構成なら lazyagent の MCP server は起動せず、非 ACP agent がいる場合だけ起動します。
- ACP でも global/scratch の特殊キー送信は使えます。`C-c` は現在の turn を cancel し、数字キーはその数字をそのまま prompt として送信します。`Up` / `Down` は transcript を半画面ずつ scroll し、`Escape` は agent に送られます。transcript の最下部へ戻って follow を再開したい場合は `scratch_keymaps.adjust_line` に好みのキーを割り当ててください。
- `buffer_acp` の split は `winfixwidth` / `winfixheight` を使ってサイズを固定するので、ファイラーなど別ウィンドウを開いても transcript pane が広がりにくくなっています。
- `Remaining reqs.` や loaded skill 数のような値は、provider が ACP で expose していない限り表示しません。現状の Copilot ACP ではそこまでは取得できません。
- transcript は `tmux` / `buffer` のどちらでも Nerd Font アイコン付きの section block で表示され、`User` / `Assistant` / `System` / `Tool` などの境目を追いやすくしています。
- `LazyAgentAttach` / 永続 resume は ACP セッションでは未対応です。

- setup 時に custom backend モジュールのマッピングを渡す（文字列としてモジュールパス or モジュールオブジェクトを渡せます）：

```lua
require("lazyagent").setup({
  backend = "builtin",
  backends = { mybackend = "my.lazyagent.backend" },
})
```

- runtime でバックエンドを登録・切り替える API（より簡単に backend を扱うために追加）:

```lua
-- register backend at runtime (module object)
require("lazyagent.logic.backend").register_backend("mybackend", require("my.lazyagent.backend"))
-- set global backend
require("lazyagent.logic.backend").set_default_backend("mybackend")
-- set per-agent override in runtime-config
require("lazyagent.logic.backend").set_agent_backend("Gemini", "mybackend")
```

（注）set_default_backend / set_agent_backend は既存のセッションを自動的に再起動・移行しません。必要に応じて既存 TMUX セッションを close して開き直すか、再接続する前提でご利用ください。

### バックエンド（backend）の切り替え

lazyagent では、対話式セッションの「バックエンド」として `tmux` / `tmux_acp` / `buffer_acp` / `builtin` をサポートしています。

- `tmux` バックエンド: tmux のペインを作成して対話セッションを管理します（デフォルト）。
- `tmux_acp` バックエンド: tmux transcript を残しつつ ACP で agent と通信します。
- `buffer_acp` バックエンド: transcript を Neovim buffer に表示したまま ACP で agent と通信します。
- `builtin` バックエンド: Neovim 内のバッファを擬似ペインとして利用します（tmux を使いたくないときの代替手段）。

バックエンドはグローバル（全エージェントの既定）で設定することも、各エージェント設定で個別に上書きすることも可能です。

- グローバル設定（全エージェントの既定）:

```lua
require("lazyagent").setup({
  backend = "builtin", -- "tmux" / "tmux_acp" / "buffer_acp" / "builtin"
})
```

## prompts（非対話式・プロンプトハンドラ）

lazyagent は「interactive_agents」（tmux を使う対話式）に加え、非対話型のプロンプトハンドラ（prompts）をサポートしています。prompts は `require("lazyagent").setup(opts)` の `prompts` テーブルに、エージェント名をキーとするコールバック関数を設定することで利用可能です。`require("lazyagent").send()` や `require("lazyagent.logic.send").send_buffer_and_clear()` は、`interactive_agents` に該当しないエージェント名が指定されている場合、`prompts` テーブルに定義されたコールバックを呼び出します。`gen` は特別扱いで、`require("lazyagent").send()` で追加のプロンプト入力を要求して `context.prompt` に格納してから `prompts["gen"]` を呼びます。

context のフィールド:
- `filename` : 対象バッファのファイル名
- `text`     : 送信対象の本文テキスト（バッファ全体または選択）
- `filetype` : ファイルタイプ
- `selection`: 選択テキスト（該当する場合）
- `prompt`   : `gen` の場合にユーザが入力した追加プロンプト（任意）

prompts の実装例（非同期 HTTP を `curl` で叩いて結果を別バッファに表示）:

```lua
prompts = {
  my_agent = function(context)
    local cmd = { "curl", "-s", "https://api.example.com/llm", "-d", context.text }
    vim.fn.jobstart(cmd, {
      stdout_buffered = true,
      on_stdout = function(_, data, _)
        if not data or #data == 0 then return end
        vim.schedule(function()
          local bufnr = vim.api.nvim_create_buf(false, true)
          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, data)
          vim.api.nvim_set_current_buf(bufnr)
        end)
      end,
      on_stderr = function(_, data, _)
        if data and #data > 0 then
          vim.schedule(function()
            vim.notify(table.concat(data, "\n"))
          end)
        end
      end,
    })
  end,

  gen = function(context)
    -- context.prompt を組み合わせて API に送るなど、任意に処理を実装します。
  end,
}
```

## キャッシュ（スクラッチの保存）

スクラッチバッファは、デフォルトでは `vim.fn.stdpath("cache") .. "/lazyagent"` に保存されます（`opts.cache.dir` でカスタマイズ可能）。 保存ファイルは、作業中の Git ブランチ名とプロジェクトルート名に基づいた名前で日次ログとして追記されます（例: `feature-foo-myproj-2024-11-21.log`）。

保存のタイミング:
- `BufWritePost`, `BufLeave`, `InsertLeave`, `TextChanged`（遅延バッファ）
- `BufDelete`, `BufWipeout` 時に確実に保存しています

バッファにキャッシュ自動保存を直接繋げたい場合は、`require("lazyagent.logic.cache").write_scratch_to_cache(bufnr)` を呼び出すか、適切な autocmd からキャッシュ関数を呼び出してください。

---

## 主要コマンド

- LazyAgentScratch — スクラッチ入力バッファを開く
- LazyAgentToggle — スクラッチの toggle
- LazyAgentClose — スクラッチを閉じる
- LazyAgentHistory — キャッシュに保存された履歴ログを UI で選択してバッファで開く（引数にファイル名を渡すと直接開けます）
- LazyAgentSummary — プロジェクト/ブランチごとの summary Markdown を UI で選択し、開く/パスをコピーする（引数に `copy` を渡すとコピーのみ）
- LazyAgentAttach — nvim 再起動後などに、すでに起動している tmux ペインをエージェントセッションとして再接続する。引数なしで実行するとエージェント選択→ペイン選択の UI が表示される。`LazyAgentAttach Claude %7` のようにエージェント名とペイン ID を直接渡すこともできる。ACP セッションの再接続には未対応。
- LazyAgentACPConfig — ACP セッションの config option selector を開く（model/mode 以外の option も含む）
- LazyAgentACPModel — ACP セッションの model selector を開く
- LazyAgentACPMode — ACP セッションの mode selector を開く
- LazyAgentACPReopen — 閉じてしまった ACP transcript window を再表示する
- LazyAgentACPCommands — ACP セッションの slash command palette を開く（local command と agent advertise 済み command をまとめて表示）
- LazyAgentACPTools — ACP セッションの tool call timeline を開く
- LazyAgentACPResources — ACP セッションの resource browser を開き、選んだ reference を scratch に挿入する（scratch が無い場合はレジスタへコピー）
- LazyAgentACPCapabilities — ACP セッションの capability summary を開く
- Claude, Codex, Gemini, Copilot, Cursor — 対話型エージェントを直接開始するコマンド（lazy の cmd で読み込む）

- `#report`（`- Summarize in Markdown file.`）トークンを使うと、`stdpath("cache")/lazyagent/summary/<project>-<branch>-<slug>.md` というプレフィックスを提示します（プロジェクト・ブランチ部分はプラグインで付与、slug は AI に選ばせる）。AI 側でそのパスに Markdown を作成/追記してください。`LazyAgentSummary` で既存の summary を開いたりパスをコピーできます。
- `#history` トークンを使うと、現在のプロジェクト+ブランチに対応する最新の会話ログファイルを `@ファイル` として自動参照します。前回の会話内容を AI に引き継がせたい場合に使います。

---

## API（簡易）

主な公開 API（`require("lazyagent")` で利用可能）:

- `require("lazyagent").setup(opts)`:
  プラグインを初期化します。`opts` で既定値を上書きします。
- `require("lazyagent").open_history()`:
  履歴 UI を開きます。
- `require("lazyagent").get_active_agents()`:
  アクティブなエージェント名の配列を返します。
- `require("lazyagent").send_to_cli(agent_name, text)`:
  指定エージェントの CLI ペインにテキストを送信します（interactive agent）。
- `require("lazyagent").send_visual()` / `require("lazyagent").send_line()`:
  Visual 選択 / 現在行を送信するヘルパー。
- `require("lazyagent").send_enter()` / `send_down()` / `send_up()` / `send_key(key)` / `send_interrupt()`:
  エージェントのペインへキー入力を送ります。
- `require("lazyagent").toggle_session(agent_name)` / `open_instant(agent_name)` / `attach_session(agent_name[, pane_id])`:
  セッションの起動・トグル・アタッチ等を行います。
- `require("lazyagent").pick_acp_config(agent_name)` / `pick_acp_model(agent_name)` / `pick_acp_mode(agent_name)`:
  ACP 用のローカルセレクタを開きます（agent 名を省略すると候補から選択）。
- `require("lazyagent").reopen_acp_window(agent_name)` / `pick_acp_commands(agent_name)` / `show_acp_tool_timeline(agent_name)`:
  ACP 関連のユーティリティ。
- `require("lazyagent").pick_acp_resources(agent_name)` / `show_acp_capabilities(agent_name)`:
  ACP のリソース / capability を表示します。
- `require("lazyagent").close_session(agent_name)` / `close_all_sessions()`:
  セッションを閉じます。

注: バッファの全内容を送信してクリアするユーティリティ（`send_buffer_and_clear` / `send_and_clear`）は
`require("lazyagent.logic.send")` モジュールに実装されています。必要であればそちらを直接 require して利用してください。

---

## 仕組みの概要 / 備考

- 対話式エージェント（Gemini など）は tmux ペインで管理します（`split-window -d -P -F "#{pane_id}"` で背景に分割を作成します）。
- ペインに貼り付け + submit key を送ることで送信します。submit は通常 `C-m` などに設定します。
- 一部端末（例: kitty）の DCS / device-control 文字列が流れて出力に目に見えることがあります。キャプチャ時にそうした行をフィルタするロジックを入れていますが、稀に端末依存で表示されることがあります。
- プラグインは Neovim 終了時 (`VimLeavePre`) に既知の tmux セッションを閉じます（`close_all_sessions`）。
- プラグインはキーの自動登録機能を提供していません。lazy.nvim の `keys`（例: `plugins/lazyagent/init.lua`）で登録することを推奨します。

---

## トラブルシューティング

- `c<space><space>` は指定されたキー例です。`c` は Neovim 標準の operator ですので、operator の挙動を変更したくない場合は `<leader>` 系を使ってください。
- Gemini などの CLI が端末に対してフォーカスを奪う場合は、起動コマンド側のオプションや端末実装に依存します。lazyagent は `-d`（バックグラウンド分割）で tmux ペインを作り、焦点は基本的に Neovim のままにします。

---

## auto_follow の依存パッケージ

`auto_follow` オプションを使う場合、`inotifywait`（Linux）または `fswatch`（macOS）のインストールを**強く推奨**します。
インストールすると `find` ポーリングの代わりにイベント駆動で動作し、CPU 負荷がほぼゼロになります。
未インストールでも動作しますが、1 秒ごとに `find` サブプロセスを生成するポーリング方式にフォールバックします。

| OS | パッケージ | インストール |
|----|-----------|-------------|
| Arch Linux | `inotify-tools` | `sudo pacman -S inotify-tools` |
| Ubuntu / Debian | `inotify-tools` | `sudo apt install inotify-tools` |
| macOS | `fswatch` | `brew install fswatch` |

---

## NVIM_LISTEN_ADDRESS と ACP 編集フック（追記）

### NVIM_LISTEN_ADDRESS のエクスポート

- 挙動: lazyagent の setup() 時に、`vim.v.servername` が存在すればプラグインは `vim.env.NVIM_LISTEN_ADDRESS` を設定し、併せて `vim.fn.setenv("NVIM_LISTEN_ADDRESS", <value>)` を呼びます。これにより Neovim 内側の環境と、`:!` や `jobstart` で起動する子プロセス/シェルに同一の値が継承されます。
- 目的: tmux ペインで起動した agent CLI が、起動元 Neovim のサーバソケット（servername）へ接続できるようにするためです（例: Copilot の CLI 等）。
- 注意点: `vim.v.servername` が非常に早い段階で未設定だと値は設定されません（現状は簡潔な実装のためリトライ/VimEnter のフォールバックを行っていません）。必要ならオプトインでフォールバックを追加できます。

### tmux ペインへの注入

- 実装: `lua/lazyagent/logic/session.lua` 側で `split_opts.env.NVIM_LISTEN_ADDRESS` を設定し、tmux split を作る際に env を渡しています。これにより agent プロセスが起動時に環境変数を取得できます。

### ACP の編集フック

- 編集フロー: ACP の `fs/write_text_file` 等は、Neovim バッファを更新しファイルへ書き込みます（実装: `lua/lazyagent/acp/backend.lua` の `write_text_file()`）。
- フック: 書き込み後に `maybe_call_mcp_tool("open_last_changed", ...)` を呼ぶほか、ツール完了時に `util.fire_event("EditDone", { agent_name = ..., tool = ... })` を発火します。
- 受け取り方:
  - User autocmd:

    vim.api.nvim_create_autocmd("User", {
      pattern = "LazyAgentEditDone",
      callback = function(ev)
        -- ev.data に { event = "EditDone", agent_name = <name>, tool = <tool_object> } が入る
        print(vim.inspect(ev.data))
      end,
    })

  - setup のコールバック:

    require("lazyagent").setup({
      callbacks = {
        EditDone = function(data)
          -- data: { event = "EditDone", agent_name = ..., tool = ... }
        end,
      },
    })

- 設定項目: `M.opts.hooks` 内の主要なフック/制御オプション:
  - open_on_edit (boolean): 編集後に自動で最終変更ファイルを開く（デフォルト: true）
  - quickfix_on_edit (boolean): 編集中の変更を quickfix に追加（デフォルト: true）
  - notify_on_done (boolean): エージェントの turn 完了時に notify を表示（デフォルト: true）
  - git_checkpoint_on_done (boolean): turn 完了時に git commit を自動で作る（デフォルト: false）
  - diagnostic_on_done (boolean): notify_done 時に quickfix のファイルを順に開いて LSP diagnostics を表示する自動診断レビューを行う（デフォルト: false）
  - diagnostic_loop_interval_ms (number): 自動診断レビューでファイルを切り替える間隔（ms、デフォルト: 1500）
  - diagnostic_fetch_delay_ms (number): 診断表示前の待機時間（ms、デフォルト: 200）
  - diagnostic_min_severity ("error"|"warning"|"info"|"hint"|"all"): 最小表示レベル（デフォルト: "all"）
  - diagnostic_loop_repeat (boolean): 診断レビューを繰り返すかどうか（デフォルト: false）
  - auto_fix_on_done (boolean): notify_done 時に quickfix のファイル一覧を agent に送って自動修正を依頼する（opt-in、デフォルト: false）

  これらは `M.opts.hooks` テーブルで設定可能です。

### 主要実装箇所（参照）

- `lua/lazyagent.lua` : setup() 内での `NVIM_LISTEN_ADDRESS` エクスポート
- `lua/lazyagent/logic/session.lua` : tmux split での env 注入
- `lua/lazyagent/acp/backend.lua` : `write_text_file()`, `maybe_call_mcp_tool()`, `on_client_update()` (EditDone 発火)
- `lua/lazyagent/mcp/tools.lua` : `open_last_changed` 等の MCP ツール実装
- `lua/lazyagent/util.lua` : `fire_event()` 実装 (User autocmd + setup callbacks)

---

## 有効化と設定例（この実装に関連するオプション）

以下は、ここで実装した動作（NVIM_LISTEN_ADDRESS の export、tmux ペインへの env 注入、ACP の edit フック / MCP hooks / util.fire_event 発火）を有効化／制御するための主要なオプション一覧と設定例です。

- グローバル / フック関連 (M.opts.hooks)
  - open_on_edit (boolean)         : 編集後に自動で最終変更ファイルを開く（デフォルト: true）
  - quickfix_on_edit (boolean)     : 編集中の変更を quickfix に追加する（デフォルト: true）
  - notify_on_done (boolean)       : エージェントの turn 完了時に notify を表示する（デフォルト: true）
  - git_checkpoint_on_done (bool)  : turn 完了時に git commit を自動で作る（デフォルト: false）

- MCP / ACP 関連
  - mcp_mode (boolean)             : プラグイン内の MCP サーバ起動の振る舞い（mcp server の自動起動制御）
  - mcp_initial_send (boolean)     : agent 起動時に initial_send を送って notify_start/notify_done を誘発させる（デフォルト: false）
  - acp.enabled (boolean)          : ACP を有効にして ACP 対応エージェントを起動する（デフォルト: false）
  - acp.view ("tmux"|"buffer")   : ACP 表示先（tmux / buffer）
  - interactive_agents.<name>.acp_cmd: エージェントの ACP 用起動コマンド（例: Copilot の `--acp` フラグ）
  - interactive_agents.<name>.acp     : agent 単位で ACP を無効化/有効化・view を上書きできるテーブル

- イベント購読（setup の callbacks と User autocmd）
  - util.fire_event は次のイベント名を発火します（例）:
    - EditDone
    - TurnDone
    - AssistantResponse
    - SessionStarted
    - SessionStopped
  - 受け取り方:
    - setup の callbacks:

```lua
require("lazyagent").setup({
  callbacks = {
    EditDone = function(data) print("EditDone:", vim.inspect(data)) end,
    TurnDone = function(data) print("TurnDone:", vim.inspect(data)) end,
    AssistantResponse = function(data) print("AssistantResponse:", vim.inspect(data)) end,
    SessionStarted = function(data) print("SessionStarted:", vim.inspect(data)) end,
    SessionStopped = function(data) print("SessionStopped:", vim.inspect(data)) end,
  }
})
```

    - User autocmd (Neovim の `User` イベント):

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "LazyAgentEditDone",
  callback = function(ev)
    -- ev.data.event == "EditDone"
    print(vim.inspect(ev.data))
  end,
})
-- 同様に LazyAgentTurnDone, LazyAgentAssistantResponse, LazyAgentSessionStarted, LazyAgentSessionStopped を受け取れます
```

- 有効化の実用例まとめ

有効にして、編集後に自動でファイルを開きつつ MCP/ACP フックも使う最小構成例:

```lua
require("lazyagent").setup({
  -- MCP を使いたい場合（agent CLI が MCP をサポートする場合）
  mcp_mode = true,
  mcp_initial_send = true,

  -- ACP を使う（Neovim 側で ACP セッションを管理）
  acp = { enabled = true, view = "buffer" },

  -- フック挙動
  hooks = {
    open_on_edit = true,
    quickfix_on_edit = true,
    notify_on_done = true,
    git_checkpoint_on_done = false,
  },

  -- コールバックで受け取る例
  callbacks = {
    EditDone = function(d) vim.notify("Agent edited: " .. tostring(d.agent_name)) end,
    TurnDone = function(d) vim.notify("Turn done: " .. tostring(d.agent_name)) end,
  },

  -- agent 側は ACP を渡して起動（例: Copilot）
  interactive_agents = {
    Copilot = { acp_cmd = { "copilot", "--acp" } },
  },
})
```

- NVIM_LISTEN_ADDRESS のエクスポートについて
  - これは現在 plugin.setup() の起動時に `vim.v.servername` が存在すれば自動で `vim.env.NVIM_LISTEN_ADDRESS` と `vim.fn.setenv("NVIM_LISTEN_ADDRESS", ...)` を呼んでいます。特に設定オプションは用意していません（必要ならオプトインのフォールバック挙動を追加可能です）。

---

Last updated: 2026-04-26T15:55:55+09:00


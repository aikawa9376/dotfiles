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
    { "<leader>sac", function() require("lazyagent").start_interactive_session({ agent_name = "Claude", reuse = true }) end, mode = "n", desc = "Start Claude Agent" },
    { "<leader>sax", function() require("lazyagent").start_interactive_session({ agent_name = "Codex", reuse = true }) end, mode = "n", desc = "Start Codex Agent" },
    { "<leader>sag", function() require("lazyagent").start_interactive_session({ agent_name = "Gemini", reuse = true }) end, mode = "n", desc = "Start Gemini Agent" },
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
  setup_keymaps = false, -- true にするとプラグイン側がデフォルトキーを登録します
  cache = {
    enabled = true,
    dir = vim.fn.stdpath("cache") .. "/lazyagent",
    debounce_ms = 1500,
  }
}
```

- `setup_keymaps` を `false` にして、キーは `plugins/lazyagent/init.lua`（lazy.nvim の keys）に寄せるのが推奨です。
- `cache` を有効にすると、スクラッチバッファを自動的にキャッシュ保存してくれます（詳細は下記）。

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
- 最高権限寄りで始めたい場合は、まず provider が expose している mode を `acp.default_mode` で指定するのが本命です。agentic.nvim と同じく、`"bypassPermissions"` のような mode がある provider ではこちらを優先してください。
- `acp.auto_permission = "allow_always"` は fallback としては有効ですが、provider mode を切り替えられない場合の補助です。`yolo = true` だけでは ACP permission は暗黙で `allow_once` までに留めています。
- `interactive_agents.<name>.acp = false` を付けると、global ACP 有効時でもその agent だけ従来 backend を使えます。
- `interactive_agents.<name>.acp = { enabled = true, view = "tmux" }` のように agent 単位で view を上書きできます。
- `acp.default_mode` / `acp.initial_model` は session ready 後に自動で適用します。agent 単位では `interactive_agents.<name>.acp = { default_mode = "...", initial_model = "..." }` や旧式 alias の `acp_default_mode` / `acp_initial_model` も使えます。
- ACP でも scratch / cache / `#history` / `#report` はそのまま使えます。会話保存は tmux pane ではなく transcript から取ります。
- ACP セッションは lazyagent の独自 MCP server に依存しません。status 更新や permission 応答後の monitor 再開、編集後の open-last-changed も Neovim 側で直接処理します。
- ACP の scratch `/` 補完は agent が `available_commands_update` で advertise した command に加えて、lazyagent 側の `/config` `/model` `/mode` `/new` を出します。
- `/model` `/mode` `/config` は ACP に plain text として送らず、Neovim の `vim.ui.select` で local selector を開きます。provider 側の picker UI をそのまま再現するのではなく、agentic.nvim 寄りの挙動です。
- `:LazyAgentACPConfig` `:LazyAgentACPModel` `:LazyAgentACPMode` でも同じ selector を開けます。
- ACP で agent から質問や確認が来た場合は、通常どおり scratch buffer から返信してください。generic な質問 picker は使わず、protocol で構造化されている permission request だけを picker で扱います。
- advertise されていないその他の `/...` は plain prompt text として送られます。
- `buffer` view では transcript 末尾に薄い footer 行を実バッファとして保ち、`Thinking...` / `Waiting...` などの進行中ステータスを独立行で表示します。footer メタ情報はその下に 2 行空けて、transcript size、provider/version、current model/mode、reasoning、model usage 倍率（Copilot が expose している場合）、MCP server 数、slash command 数、embedded context 対応をまとめて表示します。
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
require("lazyagent").register_backend("mybackend", require("my.lazyagent.backend"))
-- set global backend
require("lazyagent").set_default_backend("mybackend")
-- set per-agent override in runtime-config
require("lazyagent").set_agent_backend("Gemini", "mybackend")
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

lazyagent は「interactive_agents」（tmux を使う対話式）に加え、非対話型のプロンプトハンドラ（prompts）をサポートしています。prompts は `require("lazyagent").setup(opts)` の `prompts` テーブルに、エージェント名をキーとするコールバック関数を設定することで利用可能です。`M.send()` や `M.send_buffer_and_clear()` は、`interactive_agents` に該当しないエージェント名が指定されている場合、`prompts` テーブルに定義されたコールバックを呼び出します。`gen` は特別扱いで、`M.send()` で追加のプロンプト入力を要求して `context.prompt` に格納してから `prompts["gen"]` を呼びます。

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

バッファにキャッシュ自動保存を直接繋げたい場合は、
`require("lazyagent").attach_cache_to_buf(bufnr)` を呼び出すことで、手動で有効化できます。

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
- Claude, Codex, Gemini, Copilot, Cursor — 対話型エージェントを直接開始するコマンド（lazy の cmd で読み込む）

- `#report`（`- Summarize in Markdown file.`）トークンを使うと、`stdpath("cache")/lazyagent/summary/<project>-<branch>-<slug>.md` というプレフィックスを提示します（プロジェクト・ブランチ部分はプラグインで付与、slug は AI に選ばせる）。AI 側でそのパスに Markdown を作成/追記してください。`LazyAgentSummary` で既存の summary を開いたりパスをコピーできます。
- `#history` トークンを使うと、現在のプロジェクト+ブランチに対応する最新の会話ログファイルを `@ファイル` として自動参照します。前回の会話内容を AI に引き継がせたい場合に使います。

---

## API（簡易）

- `require("lazyagent").setup(opts)`:
  設定を読み込み初期化します。`setup_keymaps` が true の場合、デフォルトの keymaps も登録します。
- `require("lazyagent").register_keymaps(maps)`:
  デフォルト keymap を中央で登録するためのヘルパー。
- `require("lazyagent").default_keymaps()`:
  デフォルトの keymap 定義（必要な場合にカスタム登録に利用）。
- `require("lazyagent").start_interactive_session({ agent_name, reuse, initial_input, open_input })`:
  tmux に対話ペインを作り、スクラッチバッファを開く（`reuse=true` で既存のセッションを再利用）。
- `require("lazyagent").toggle_session(agent_name)`:
  - エージェントが未起動なら起動してスクラッチを開く
  - 起動済みでスクラッチが表示されていればスクラッチを閉じる
  - 起動済みでスクラッチが非表示ならスクラッチを開く
- `require("lazyagent").send_visual()` / `.send_line()`:
  選択/行送信ヘルパー
- `require("lazyagent").send_to_cli(agent_name, text)`:
  1回送信（pane を作成/再利用、送って終わる）
- `require("lazyagent").send_buffer_and_clear(agent_name, bufnr)`:
  指定バッファ（省略時は現在のバッファ）の全内容を指定エージェントに送信し、送信後にバッファを空にします。スクラッチのフロートは閉じません（interactive agent / prompt agent の両方に対応）。
- `require("lazyagent").send_and_clear(agent_name)`:
  `send_buffer_and_clear()` の便利ラッパーで、現在のバッファを対象に送信・クリアを行います。
- `require("lazyagent").pick_acp_config(agent_name)` / `.pick_acp_model(agent_name)` / `.pick_acp_mode(agent_name)`:
  ACP セッション用の local selector を開きます。agent 名を省略すると ACP 有効な agent から選択します。
- `require("lazyagent").close_session(agent_name)` / `.close_all_sessions()`:
  1 つのセッション、もしくは全セッションを閉じる

---

## 仕組みの概要 / 備考

- 対話式エージェント（Gemini など）は tmux ペインで管理します（`split-window -d -P -F "#{pane_id}"` で背景に分割を作成します）。
- ペインに貼り付け + submit key を送ることで送信します。submit は通常 `C-m` などに設定します。
- 一部端末（例: kitty）の DCS / device-control 文字列が流れて出力に目に見えることがあります。キャプチャ時にそうした行をフィルタするロジックを入れていますが、稀に端末依存で表示されることがあります。
- プラグインは Neovim 終了時 (`VimLeavePre`) に既知の tmux セッションを閉じます（`close_all_sessions`）。
- デフォルトではプラグインは `setup_keymaps=false` です。キーは `lazy.nvim` に任せて起動時に読み込む構成が推奨です。

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

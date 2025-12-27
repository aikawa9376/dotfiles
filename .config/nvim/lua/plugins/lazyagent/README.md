# lazyagent.nvim

選択テキストや現在行を、設定した「エージェント」（Lua関数または外部CLI）に送信するNeovimプラグインです。CLI 連携には tmux を使った対話型エージェント（例: Gemini / Claude / Codex / Copilot / Cursor）をサポートします。スクラッチ入力バッファ、キャッシュ保存、lazy.nvim 互換のキー読み込みを備えています。

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
      pane_size = 30,
      scratch_filetype = "lazyagent",
      submit_keys = { "C-m" }, -- tmux-style key; "<CR>" and "<c-m>" are accepted and normalized for convenience
      capture_delay = 800,
    },
    -- Claude, Codex など
  },
  window_type = "float", -- または "vsplit"
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

lazyagent では、対話式セッションの「バックエンド」として `tmux` と `builtin` の 2 種類をサポートしています。

- `tmux` バックエンド: tmux のペインを作成して対話セッションを管理します（デフォルト）。
- `builtin` バックエンド: Neovim 内のバッファを擬似ペインとして利用します（tmux を使いたくないときの代替手段）。

バックエンドはグローバル（全エージェントの既定）で設定することも、各エージェント設定で個別に上書きすることも可能です。

- グローバル設定（全エージェントの既定）:

```lua
require("lazyagent").setup({
  backend = "builtin", -- "tmux" または "builtin"
})
```

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

lazyagent では、対話式セッションの「バックエンド」として `tmux` と `builtin` の 2 種類をサポートしています。

- `tmux` バックエンド: tmux のペインを作成して対話セッションを管理します（デフォルト）。
- `builtin` バックエンド: Neovim 内のバッファを擬似ペインとして利用します（tmux を使いたくないときの代替手段）。

バックエンドはグローバル（全エージェントの既定）で設定することも、各エージェント設定で個別に上書きすることも可能です。

- グローバル設定（全エージェントの既定）:

```lua
require("lazyagent").setup({
  backend = "builtin", -- "tmux" または "builtin"
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
- Claude, Codex, Gemini, Copilot, Cursor — 対話型エージェントを直接開始するコマンド（lazy の cmd で読み込む）

- `#report`（`- Summarize in Markdown file.`）トークンを使うと、`stdpath("cache")/lazyagent/summary/<project>-<branch>-<slug>.md` というプレフィックスを提示します（プロジェクト・ブランチ部分はプラグインで付与、slug は AI に選ばせる）。AI 側でそのパスに Markdown を作成/追記してください。`LazyAgentSummary` で既存の summary を開いたりパスをコピーできます。

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

# lazyconflict.nvim

Git のコンフリクトを非同期に検知し、ステータスライン・Quickfix・バッファローカルのキーで解消を支援する Neovim ローカルプラグインです。`akinsho/git-conflict.nvim` に近い UX を、lazy.nvim 向けのローカル配置で再構成しています。

主な機能
- 非同期コンフリクト検知（既存の autocmd や手動コマンドから呼び出し可能）
- ステータスライン / ウィンバーにコンフリクト件数を表示（アイコン付き）
- コンフリクトを含むバッファでマーカーをハイライト
- Quickfix にコンフリクト一覧を流し込みジャンプ
- バッファ入室時にコンフリクト解消用のローカルキーマップを一時的に付与
  - `]]` / `[[` で次/前のコンフリクトへ移動
  - `co` / `ct` / `cb` / `c0` など一般的な diffget 系キーマップ
- 全処理が非同期で Neovim の操作をブロックしない（`jobstart` 等を想定）
- コンフリクト検知は fd / rg などの CLI を前提にしてもよい

---

## インストール

ローカルプラグインとして利用する例（lazy.nvim）:

```lua
return {
  "lazyconflict",
  dir = os.getenv("XDG_CONFIG_HOME") .. "/nvim/lua/plugins/lazyconflict",
  cmd = { "LazyConflictCheck", "LazyConflictQuickfix", "LazyConflictDisable", "LazyConflictEnable" },
  config = function()
    require("lazyconflict").setup()
  end,
}
```

---

## オプション（主なもの）

`require("lazyconflict").setup(opts)` で設定します。デフォルトのイメージ:

```lua
{
  detection = {
    auto = true,
    autocmds = { "BufEnter", "BufWritePost", "FocusGained", "TextChanged" },
    debounce_ms = 400,
    mode = "git", -- "git" (git status) or "marker" (grep markers)
    command = nil, -- nil なら git diff --name-only --diff-filter=U で競合中ファイルのみ拾い、rg でマーカーを検索
    pattern = "^<<<<<<<.*$|^>>>>>>>.*$|^\\|\\|\\|\\|\\|\\|\\|.*$|^=======.*$",
  },
  statusline = {
    icon = "",
    formatter = function(count) return count > 0 and (" " .. count) or "" end,
  },
  quickfix = {
    open = false, -- true なら検知時に自動で Quickfix を開く
  },
  disable_diagnostics = true, -- true ならコンフリクト中は LSP 診断を無効化
  highlights = {
    -- GitConflictCurrent/GitConflictIncoming があればリンクし、なければ同系色の bg を自前で張ります（git-conflict.nvim と同じ配色）。
    current = "LazyConflictCurrent",   -- #405d7e 相当
    incoming = "LazyConflictIncoming", -- #314753 相当
    ancestor = "LazyConflictAncestor", -- #68217a 相当
    separator = "LazyConflictSeparator",
  },
  keymaps = {
    enabled = true, -- バッファローカルにキーマップを張るか
    ours = "co",
    theirs = "ct",
    all_ours = "ca",
    all_theirs = "cA",
    both = "cb",
    cursor = "cc",
    none = "c0",
    next = "]]",
    prev = "[[",
  },
}
```

- `detection.auto = false` にすると `LazyConflictCheck` または `require("lazyconflict").check()` で手動検知できます。
- `command` を指定するとそのコマンドの出力（`path:line:...` 形式）を使うカスタム検知に差し替えます。未指定なら git で未解決ファイルのみ列挙して rg でマーカーを検索するため、普通のテキストや Markdown のコードブロック内のダミー例には反応しません。
- ステータスラインは `require("lazyconflict").statusline()` を呼び出して文字列を返す想定です（空文字なら表示しない）。

### 主なコマンド / API

- `LazyConflictCheck` / `require("lazyconflict").check(opts)`
  直近の Git ワーキングツリーからコンフリクトを非同期検出し、キャッシュを更新。
- `LazyConflictQuickfix` / `require("lazyconflict").populate_quickfix(opts)`
  現在の検出結果を Quickfix に流し込む（必要なら開く）。
- `LazyConflictEnable` / `LazyConflictDisable`
  自動検知の autocmd・バッファローカルキーマップを有効/無効化。
- `require("lazyconflict").jump_next()` / `.jump_prev()`
  バッファ内で次/前のコンフリクトへ移動。
- `require("lazyconflict").accept("ours" | "theirs" | "both" | "none")`
  diffget 系の取り込みを行うヘルパー（git-conflict.nvim に近い動作）。

### ステータスライン例

```lua
-- lualine 例
sections = {
  lualine_c = {
    function() return require("lazyconflict").statusline() end,
  },
}
```

---

## 実装メモ

- コンフリクト検知は非同期ジョブで実行し、結果はキャッシュしてステータス・Quickfix・ハイライトで共有する想定です。
- バッファローカルのハイライトは diff3 マーカー（`<<<<<<<`, `=======`, `>>>>>>>`）に対して extmark の `hl_eol` でブロック全体を塗りつぶす想定です（git-conflict.nvim に揃えた配色）。
- キーマップはコンフリクトを含むバッファに入ったときだけ張り、離れたら外す構成を想定しています。

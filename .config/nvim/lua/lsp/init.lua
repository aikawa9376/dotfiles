require("mason").setup()

-- このファイルの存在するディレクトリ
local dirname = vim.fn.stdpath('config') .. '/after/lsp'

-- 設定したlspを保存する配列 cmd扱いじゃないものは最初に追加
local lsp_names = {'copilot'}

-- 同一ディレクトリのファイルをループ
for file, ftype in vim.fs.dir(dirname) do
  -- `.lua`で終わるファイルを処理（init.luaは除く）
  if ftype == 'file' and vim.endswith(file, '.lua') and file ~= 'init.lua' then
    -- 拡張子を除いてlsp名を作る
    local lsp_name = file:sub(1, -5) -- fname without '.lua'
    -- lspconfigから実際のコマンド名を取得
    local ok, config = pcall(require, 'lspconfig.configs.' .. lsp_name)
    local cmd = ok and config.default_config and config.default_config.cmd
    if cmd and vim.fn.executable(cmd[1]) == 1 then
      table.insert(lsp_names, lsp_name)
    end
  end
end

-- 読み込めたlspを有効化
vim.lsp.enable(lsp_names)

-- lspを有効化させたくない場合はここで設定
local base_start = vim.lsp.start
---@diagnostic disable-next-line: duplicate-set-field
vim.lsp.start = function(config, opts)
  if opts and opts.bufnr then
    -- fugitive系のbufferの場合はスキップ
    if vim.b[opts.bufnr].fugitive_type then
      return
    end
    -- このバッファに対して同じLSPが既にアタッチされている場合はスキップ
    local clients = vim.lsp.get_clients({ bufnr = opts.bufnr, name = config.name })
    if #clients > 0 then
      return
    end
  end
  base_start(config, opts)
end

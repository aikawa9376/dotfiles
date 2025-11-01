require("mason").setup()

-- このファイルの存在するディレクトリ
local dirname = vim.fn.stdpath('config') .. '/after/lsp'

-- 設定したlspを保存する配列
local lsp_names = {}

-- 同一ディレクトリのファイルをループ
for file, ftype in vim.fs.dir(dirname) do
  -- `.lua`で終わるファイルを処理（init.luaは除く）
  if ftype == 'file' and vim.endswith(file, '.lua') and file ~= 'init.lua' then
    -- 拡張子を除いてlsp名を作る
    local lsp_name = file:sub(1, -5) -- fname without '.lua'
    -- 読み込む
    table.insert(lsp_names, lsp_name)
  end
end

-- 読み込めたlspを有効化
vim.lsp.enable(lsp_names)

-- lspを有効化させたくない場合はここで設定
local base_start = vim.lsp.start
---@diagnostic disable-next-line: duplicate-set-field
vim.lsp.start = function(...)
  local _, opt = unpack({ ... })
  if opt and opt.bufnr then
    if vim.b[opt.bufnr].fugitive_type then
      return
    end
  end
  base_start(...)
end

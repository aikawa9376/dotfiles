local M = {}

local prefill_edit_window = function(request)
  require('avante.api').edit()
  local code_bufnr = vim.api.nvim_get_current_buf()
  local code_winid = vim.api.nvim_get_current_win()
  if code_bufnr == nil or code_winid == nil then
    return
  end
  vim.api.nvim_buf_set_lines(code_bufnr, 0, -1, false, { request })
  vim.api.nvim_win_set_cursor(code_winid, { 1, #request + 1 })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-s>', true, true, true), 'v', true)
end

local avante_code_readability_analysis = [[
  以下の点を考慮しコードの可読性の問題を特定してください。
  考慮すべき可読性の問題:
  - 不明瞭な命名
  - 不明瞭な目的
  - 冗長なコメント
  - コメントの欠如
  - 長いまたは複雑な一行のコード
  - ネストが多すぎる
  - 長すぎる変数名
  - 命名とコードスタイルの不一致
  - コードの繰り返し
  上記以外の問題を特定しても構いません。
]]
local avante_optimize_code = "次のコードを最適化してください。"
local avante_fix_bugs = "次のコード内のバグを修正してください。"
local avante_add_tests = "次のコードのテストを実装してください。"
local avante_add_docstring = "次のコードにdocstringを追加してください。"

local avante_ask = require("avante.api").ask

M.avante_code_readability_analysis = function () avante_ask({ question = avante_code_readability_analysis })  end
M.avante_optimize_code = function () prefill_edit_window(avante_optimize_code) end
M.avante_fix_bugs = function () prefill_edit_window(avante_fix_bugs) end
M.avante_add_docstring = function () prefill_edit_window(avante_add_docstring) end
M.avante_add_tests = function () prefill_edit_window( avante_add_tests) end
M.avante_switch_provider = function()
  local ok, plugin = pcall(require, "lazy.core.plugin")
  local ok2, config = pcall(require, "lazy.core.config")
  if not (ok and ok2) then
    vim.notify("lazy.nvim not available", vim.log.levels.ERROR)
    return
  end

  local avante_config = config.spec.plugins["avante.nvim"]
  local opts = plugin.values(avante_config, "opts", false)
  local providers = type(opts) == "table" and opts.providers or nil

  if type(providers) ~= "table" or vim.tbl_isempty(providers) then
    vim.notify("No providers configured for avante.nvim", vim.log.levels.WARN)
    return
  end

  local choices = vim.tbl_keys(providers)
  table.sort(choices)

  -- pcall(require, "dressing")

  vim.ui.select(choices, { prompt = "Select Avante provider:" }, function(choice)
    if not choice then return end
    local ok3, err = pcall(require("avante.api").switch_provider, choice)
    if not ok3 then
      vim.notify("Failed to switch provider: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

return M

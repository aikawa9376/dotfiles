local M = {}
local util = require'vim.lsp.util'
local buf = require'vim.lsp.buf'
local validate = vim.validate

function _G.code_action_complete(win)
  local choice = vim.trim(vim.fn.getline('.'))
  local index = tonumber(string.match(choice, "%d+"))
  local result = vim.api.nvim_buf_get_var(buf, 'code_action_result')
  local ctx = vim.api.nvim_buf_get_var(buf, 'code_action_ctx')
  if not index or index < 1 or index > #result then
    return
  end
  local action = result[index]
  -- ここでウインドウを閉じないと関連のrequestがbufの関係でエラーになる
  vim.api.nvim_win_close(win, true)

  if action.edit then
    util.apply_workspace_edit(action.edit)
  end
  if action.command then
    local command = type(action.command) == 'table' and action.command or action
    local fn = vim.lsp.commands[command.command]
    if fn then
      fn(command, ctx)
    else
      buf.execute_command(command)
    end
  end
end

local function get_titles_length(result)
  local option_strings = {"Code actions:"}
  local length = 0
  for i, action in ipairs(result) do
    action = action[2]
    local title = action.title:gsub('\r\n', '\\r\\n')
    title = title:gsub('\n', '\\n')
    title = string.format("%d. %s [%s]", i, title, action.kind)
    table.insert(option_strings, title)

    length = length < #title and #title or length
  end
  return option_strings, length
end

local function open_action_float(result, ctx)
  local title, length = get_titles_length(result)
  local opts = {
    relative = 'cursor', row = 1,
    col = 0, width = length,
    height = #title, style = 'minimal'
  }
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, opts)

  local fmt =  '<cmd>lua code_action_complete(%d)<CR>'
  vim.api.nvim_buf_set_var(buf, 'code_action_result', result)
  vim.api.nvim_buf_set_var(buf, 'code_action_ctx', ctx)
  vim.api.nvim_win_set_option(win, 'winhighlight', 'Normal:NormalFloat')
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, title)
  vim.api.nvim_buf_set_keymap(buf, 'n', '<CR>', string.format(fmt, win), {silent=true})
  vim.api.nvim_buf_set_keymap(buf, 'n', '<ESC>', ':lua vim.api.nvim_win_close(win, true)<CR>' , {silent=true})
end

local function float_ui_select(items, opts, on_choice)
  local title, length = get_titles_length(items)
  local w_opts = {
    relative = 'cursor', row = 1,
    col = 0, width = length,
    height = #title, style = 'minimal'
  }
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, w_opts)

  local fmt =  '<cmd>lua code_action_complete(%d)<CR>'
  vim.api.nvim_buf_set_var(buf, 'code_action_result', result)
  vim.api.nvim_buf_set_var(buf, 'code_action_ctx', ctx)
  vim.api.nvim_win_set_option(win, 'winhighlight', 'Normal:NormalFloat')
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, title)
  vim.api.nvim_buf_set_keymap(buf, 'n', '<CR>', string.format(fmt, win), {silent=true})
  vim.api.nvim_buf_set_keymap(buf, 'n', '<ESC>', ':lua vim.api.nvim_win_close(win, true)<CR>' , {silent=true})
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      local choice = vim.trim(vim.fn.getline('.'))
      local index = tonumber(string.match(choice, "%d+"))
      print(index)
      -- vim.api.nvim_win_close(win, true)
      if index < 1 or index > #items then
        on_choice(nil, nil)
      else
        on_choice(items[index], index)
      end
    end,
  })

  -- local choice = vim.fn.inputlist(choices)
  -- if choice < 1 or choice > #items then
  --   on_choice(nil, nil)
  -- else
  --   on_choice(items[choice], choice)
  -- end
end

--see: https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_codeAction
local function code_action_handler(_, result, ctx)
  if result == nil or vim.tbl_isempty(result) then
    print("No code actions available")
    return
  end

  open_action_float(result, ctx)
end

--- Requests code actions from all clients and calls the handler exactly once
--- with all aggregated results
---@private
local function code_action_request(params)
  local bufnr = vim.api.nvim_get_current_buf()
  local method = 'textDocument/codeAction'
  vim.lsp.buf_request_all(bufnr, method, params, function(results)
    local actions = {}
    for _, r in pairs(results) do
      vim.list_extend(actions, r.result or {})
    end
    -- ここは自作ハンドラーを作って持ち回ったほうが良いかもしれない
    -- 言語ごとに処理に特徴があるため typescriptなど独自だから差し替えたい
    -- vim.lsp.handlers[method](nil, actions, {bufnr=bufnr, method=method})
    code_action_handler(nil, actions, {bufnr=bufnr, method=method})
  end)

end

--- Selects a code action from the input list that is available at the current
--- cursor position.
---
---@param context: (table, optional) Valid `CodeActionContext` object
---@see https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_codeAction
function M.code_action(context)
  vim.ui.select = float_ui_select
  validate { context = { context, 't', true } }
  context = context or {}
  if not context.diagnostics then
    context.diagnostics = vim.lsp.diagnostic.get_line_diagnostics()
  end
  local params = util.make_range_params()
  params.context = context
  code_action_request(params)
end

--- Performs |vim.lsp.buf.code_action()| for a given range.
---
---@param context: (table, optional) Valid `CodeActionContext` object
---@param start_pos ({number, number}, optional) mark-indexed position.
---Defaults to the start of the last visual selection.
---@param end_pos ({number, number}, optional) mark-indexed position.
---Defaults to the end of the last visual selection.
function M.range_code_action(context, start_pos, end_pos)
  validate { context = { context, 't', true } }
  context = context or { diagnostics = vim.lsp.diagnostic.get_line_diagnostics() }
  local params = util.make_given_range_params(start_pos, end_pos)
  params.context = context
  code_action_request(params)
end

return M

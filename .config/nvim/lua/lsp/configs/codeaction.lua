local M = {}
local util = require'vim.lsp.util'
local buf = require'vim.lsp.buf'
local validate = vim.validate

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

  --see: https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_codeAction
  function code_action_handler(_, result)
    if result == nil or vim.tbl_isempty(result) then
      print("No code actions available")
      return
    end

    open_action_float(result)
  end

  function get_titles_length(result)
    local option_strings = {"Code actions:"}
    local length = 0
    for i, action in ipairs(result) do
      local title = action.title:gsub('\r\n', '\\r\\n')
      title = title:gsub('\n', '\\n')
      title = string.format("%d. %s", i, title)
      table.insert(option_strings, title)

      length = length < #title and #title or length
    end
    return option_strings, length
  end

  function open_action_float(result)
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
    vim.api.nvim_win_set_option(win, 'winhighlight', 'Normal:NormalFloat')
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, title)
    vim.api.nvim_buf_set_keymap(buf, 'n', '<CR>', string.format(fmt, win), {silent=true})
    vim.api.nvim_buf_set_keymap(buf, 'n', '<ESC>', ':lua vim.api.nvim_win_close(win, true)<CR>' , {silent=true})
  end

  function code_action_complete(win)
    local choice = vim.trim(vim.fn.getline('.'))
    local index = tonumber(string.match(choice, "%d+"))
    local result = vim.api.nvim_buf_get_var(buf, 'code_action_result')
    if not index or index < 1 or index > #result then
      return
    end
    local action_chosen = result[index]
    -- textDocument/codeAction can return either Command[] or CodeAction[].
    -- If it is a CodeAction, it can have either an edit, a command or both.
    -- Edits should be executed first
    if action_chosen.edit or type(action_chosen.command) == "table" then
      if action_chosen.edit then
        util.apply_workspace_edit(action_chosen.edit)
      end
      if type(action_chosen.command) == "table" then
        buf.execute_command(action_chosen.command)
      end
    else
      buf.execute_command(action_chosen)
    end
    vim.api.nvim_win_close(win, true)
  end
end

--- Selects a code action from the input list that is available at the current
--- cursor position.
---
---@param context: (table, optional) Valid `CodeActionContext` object
---@see https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_codeAction
function M.code_action(context)
  validate { context = { context, 't', true } }
  context = context or { diagnostics = vim.lsp.diagnostic.get_line_diagnostics() }
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

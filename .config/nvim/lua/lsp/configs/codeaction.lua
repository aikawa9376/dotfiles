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
    codeActionHandler(nil, actions, {bufnr=bufnr, method=method})
  end)

  --see: https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_codeAction
  function codeActionHandler(_, result)
    if result == nil or vim.tbl_isempty(result) then
      print("No code actions available")
      return
    end

    local option_strings = {"Code actions:"}
    for i, action in ipairs(result) do
      local title = action.title:gsub('\r\n', '\\r\\n')
      title = title:gsub('\n', '\\n')
      table.insert(option_strings, string.format("%d. %s", i, title))
    end

    local choice = vim.fn.inputlist(option_strings)
    if choice < 1 or choice > #result then
      return
    end
    local action_chosen = result[choice]
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

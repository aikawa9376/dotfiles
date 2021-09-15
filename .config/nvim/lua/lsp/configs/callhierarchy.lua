local util = require 'vim.lsp.util'
local validate = vim.validate
local api = vim.api

local M = {}

---@see |vim.lsp.buf_request()|
local function request(method, params, handler)
  validate {
    method = {method, 's'};
    handler = {handler, 'f', true};
  }
  return vim.lsp.buf_request(0, method, params, handler)
end

---@private
local function pick_call_hierarchy_item(call_hierarchy_items)
  if not call_hierarchy_items then return end
  if #call_hierarchy_items == 1 then
    return call_hierarchy_items[1]
  end
  local items = {}
  for i, item in pairs(call_hierarchy_items) do
    local entry = item.detail or item.name
    table.insert(items, string.format("%d. %s", i, entry))
  end
  local choice = vim.fn.inputlist(items)
  if choice < 1 or choice > #items then
    return
  end
  return choice
end

---@private
local function call_hierarchy(method, direction)
  local params = util.make_position_params()
  request('textDocument/prepareCallHierarchy', params, function(err, result)
    if err then
      vim.notify(err.message, vim.log.levels.WARN)
      return
    elseif not result or next(result) == nil then
      print('The selected word is not a function')
      return
    end
    local call_hierarchy_item = pick_call_hierarchy_item(result)
    vim.lsp.buf_request(0, method, { item = call_hierarchy_item }, make_call_hierarchy_handler(direction))
  end)
  ---@private
  ---
  --- Displays call hierarchy in the quickfix window.
  ---
  ---@param direction `"from"` for incoming calls and `"to"` for outgoing calls
  ---@returns `CallHierarchyIncomingCall[]` if {direction} is `"from"`,
  ---@returns `CallHierarchyOutgoingCall[]` if {direction} is `"to"`,
  function make_call_hierarchy_handler(direction)
    return function(_, result)
      if not result or next(result) == nil then
        if direction == "from" then
          print('IncomingCall not found')
        elseif direction == "to" then
          print('OutgoingCall not found')
        end
        return
      end
      local items = {}
      for _, call_hierarchy_call in pairs(result) do
        local call_hierarchy_item = call_hierarchy_call[direction]
        local range = call_hierarchy_item.selectionRange
        table.insert(items, {
          filename = assert(vim.uri_to_fname(call_hierarchy_item.uri)),
          text = call_hierarchy_item.name,
          lnum = range.start.line + 1,
          col = range.start.character + 1,
        })
      end
      util.set_qflist(items)
      api.nvim_command("copen")
    end
  end
end

--- Lists all the call sites of the symbol under the cursor in the
--- |quickfix| window. If the symbol can resolve to multiple
--- items, the user can pick one in the |inputlist|.
function M.incoming_calls()
  call_hierarchy('callHierarchy/incomingCalls', 'from')
end

function M.outgoing_calls()
  call_hierarchy('callHierarchy/outgoingCalls', 'to')
end

return M

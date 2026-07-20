local M = {}

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local owned = vim.api.nvim_create_buf(false, true)
  local external = vim.api.nvim_create_buf(false, true)
  local layout_state = {}
  local calls = {}
  local original_redraw = vim.api.nvim__redraw

  local ok, err = xpcall(function()
    vim.api.nvim__redraw = function(opts)
      calls[#calls + 1] = vim.deepcopy(opts)
    end

    local request_redraw = require("lazyagent.acp.view_buffer.redraw").new({
      layout_state = layout_state,
      owns_buffer = function(bufnr) return bufnr == owned end,
      buffer_is_visible = function() return true end,
    })

    request_redraw(external)
    vim.wait(20)
    assert_equal(#calls, 0, "external buffer is ignored")
    assert_equal(layout_state[tostring(external)], nil, "external buffer gets no LazyAgent redraw state")

    request_redraw(owned)
    assert(vim.wait(200, function() return #calls == 1 end, 5), "owned buffer redraw should run")
    assert_equal(calls[1].buf, owned, "redraw targets the owned buffer")
    assert_equal(calls[1].valid, false, "owned buffer is invalidated")
    assert_equal(calls[1].flush, nil, "redraw does not flush unrelated UI")
  end, debug.traceback)

  vim.api.nvim__redraw = original_redraw
  pcall(vim.api.nvim_buf_delete, owned, { force = true })
  pcall(vim.api.nvim_buf_delete, external, { force = true })
  if not ok then
    error(err)
  end
end

return M

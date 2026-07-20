local M = {}

function M.new(ctx)
  local layout_state = ctx.layout_state
  local buffer_is_visible = ctx.buffer_is_visible
  local owns_buffer = ctx.owns_buffer

  local function redraw_buffer(bufnr)
    if type(vim.api.nvim__redraw) == "function" then
      local ok = pcall(vim.api.nvim__redraw, {
        buf = bufnr,
        valid = false,
      })
      if ok then
        return
      end
    end

    if vim.api.nvim_get_current_buf() == bufnr then
      pcall(vim.cmd, "redraw")
    end
  end

  return function(bufnr)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    if not owns_buffer or owns_buffer(bufnr) ~= true then
      return
    end
    if buffer_is_visible and not buffer_is_visible(bufnr) then
      return
    end

    local key = tostring(bufnr)
    local entry = layout_state[key]
    if type(entry) ~= "table" then
      entry = {}
      layout_state[key] = entry
    end
    if entry.redraw_pending then
      return
    end
    entry.redraw_pending = true

    vim.schedule(function()
      local current_entry = layout_state[key]
      if type(current_entry) == "table" then
        current_entry.redraw_pending = nil
      end
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      if owns_buffer(bufnr) ~= true then
        return
      end
      if buffer_is_visible and not buffer_is_visible(bufnr) then
        return
      end
      redraw_buffer(bufnr)
    end)
  end
end

return M

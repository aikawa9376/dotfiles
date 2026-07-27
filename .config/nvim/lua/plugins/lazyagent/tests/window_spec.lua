local M = {}

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local window = require("lazyagent.window")
  local original_win = vim.api.nvim_get_current_win()
  local original_buf = vim.api.nvim_get_current_buf()
  local scratch_buf = window.create_scratch_buffer()
  local close_count = 0

  window.open(scratch_buf, {
    window_type = "float",
    on_close = function()
      close_count = close_count + 1
    end,
  })

  assert_equal(window.close({ keep_buffer = true }), true, "programmatic scratch close")
  assert_equal(close_count, 1, "open-time on_close callback runs")

  window.close({ keep_buffer = true })
  assert_equal(close_count, 1, "open-time on_close callback only runs once")

  if vim.api.nvim_win_is_valid(original_win) and vim.api.nvim_buf_is_valid(original_buf) then
    vim.api.nvim_win_set_buf(original_win, original_buf)
    vim.api.nvim_set_current_win(original_win)
  end
  pcall(vim.api.nvim_buf_delete, scratch_buf, { force = true })
end

return M

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
  local filetype_events = 0
  local group = vim.api.nvim_create_augroup("LazyAgentScratchFiletypeTest", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "lazyagent",
    callback = function() filetype_events = filetype_events + 1 end,
  })
  local scratch_buf = window.create_scratch_buffer()
  vim.api.nvim_buf_set_lines(scratch_buf, 0, -1, false, { "preserved draft" })
  local close_count = 0

  window.open(scratch_buf, {
    window_type = "float",
    on_close = function()
      close_count = close_count + 1
    end,
  })
  assert_equal(filetype_events, 1, "first scratch open initializes FileType once")

  assert_equal(window.close({ keep_buffer = true }), true, "programmatic scratch close")
  assert_equal(close_count, 1, "open-time on_close callback runs")

  window.close({ keep_buffer = true })
  assert_equal(close_count, 1, "open-time on_close callback only runs once")

  local float = window.open(scratch_buf, {
    window_type = "float",
    close_on_focus_lost = true,
    on_close = function() close_count = close_count + 1 end,
  })
  assert_equal(filetype_events, 1, "reopening scratch does not reinitialize FileType")
  assert_equal(vim.api.nvim_buf_get_lines(scratch_buf, 0, -1, false)[1], "preserved draft", "reopen preserves input")
  -- fzf-lua restore_lastwin visits the editor before returning to its origin.
  vim.api.nvim_set_current_win(original_win)
  assert_equal(vim.api.nvim_win_is_valid(float), true, "temporary focus change keeps picker origin valid")
  vim.api.nvim_set_current_win(float)
  vim.wait(20)
  assert_equal(vim.api.nvim_win_is_valid(float), true, "restored scratch survives scheduled focus check")
  assert_equal(close_count, 1, "temporary focus change does not call on_close")

  vim.api.nvim_set_current_win(original_win)
  assert(vim.wait(200, function() return not vim.api.nvim_win_is_valid(float) end, 5),
    "scratch closes when focus remains elsewhere")
  assert_equal(close_count, 2, "genuine focus loss calls on_close once")

  float = window.open(scratch_buf, { window_type = "float", close_on_focus_lost = true })
  vim.api.nvim_set_current_win(original_win)
  window.close({ keep_buffer = true })

  local replacement = window.open(scratch_buf, { window_type = "float", close_on_focus_lost = true })
  vim.wait(20)
  assert_equal(vim.api.nvim_win_is_valid(replacement), true, "stale focus check cannot close a replacement scratch")
  window.close({ keep_buffer = true })

  window.open(scratch_buf, { filetype = "markdown" })
  assert_equal(vim.bo[scratch_buf].filetype, "markdown", "explicit filetype changes still apply")
  window.close({ keep_buffer = true })
  vim.api.nvim_del_augroup_by_id(group)

  if vim.api.nvim_win_is_valid(original_win) and vim.api.nvim_buf_is_valid(original_buf) then
    vim.api.nvim_win_set_buf(original_win, original_buf)
    vim.api.nvim_set_current_win(original_win)
  end
  pcall(vim.api.nvim_buf_delete, scratch_buf, { force = true })
end

return M

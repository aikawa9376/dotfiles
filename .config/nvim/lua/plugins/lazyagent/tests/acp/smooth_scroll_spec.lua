local M = {}

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local smooth_scroll = require("lazyagent.acp.view_buffer.smooth_scroll")
  local win = vim.api.nvim_get_current_win()
  local previous_bufnr = vim.api.nvim_win_get_buf(win)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local lines = {}
  for index = 1, 200 do
    lines[index] = "smooth scroll line " .. tostring(index)
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_win_set_buf(win, bufnr)
  vim.api.nvim_win_set_cursor(win, { 100, 0 })

  local original_get_mode = vim.api.nvim_get_mode
  local original_win_call = vim.api.nvim_win_call
  local mode = "c"
  local win_call_count = 0
  rawset(vim.api, "nvim_get_mode", function()
    return { mode = mode, blocking = false }
  end)
  rawset(vim.api, "nvim_win_call", function(target_win, callback)
    if target_win == win then
      win_call_count = win_call_count + 1
    end
    return original_win_call(target_win, callback)
  end)

  local ok, err = xpcall(function()
    local cfg = {
      enabled = true,
      duration_ms = 300,
      step_ms = 20,
      max_delta = 80,
    }

    assert_equal(smooth_scroll.scroll_by_lines(win, 20, cfg, {
      bufnr = bufnr,
    }), false, "manual smooth scroll is not started from command-line mode")
    vim.wait(60)
    assert_equal(win_call_count, 0, "command-line mode does not enter the target window")
    assert_equal(smooth_scroll.active(win), false, "command-line mode leaves no smooth-scroll timer")

    mode = "n"
    local finish_count = 0
    assert_equal(smooth_scroll.scroll_by_lines(win, 20, cfg, {
      bufnr = bufnr,
      on_finish = function()
        finish_count = finish_count + 1
      end,
    }), true, "manual smooth scroll starts in normal mode")
    assert(vim.wait(200, function() return win_call_count > 0 end, 5),
      "normal-mode smooth scroll should advance at least one frame")

    mode = "c"
    local calls_before_cmdline = win_call_count
    assert(vim.wait(200, function() return not smooth_scroll.active(win) end, 5),
      "an active smooth scroll should stop after command-line mode starts")
    vim.wait(60)
    assert_equal(win_call_count, calls_before_cmdline,
      "an active smooth scroll never enters the window after command-line mode starts")
    assert_equal(finish_count, 1, "stopped smooth scroll runs its completion callback once")
  end, debug.traceback)

  smooth_scroll.stop_window(win)
  rawset(vim.api, "nvim_get_mode", original_get_mode)
  rawset(vim.api, "nvim_win_call", original_win_call)
  vim.api.nvim_win_set_buf(win, previous_bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  if not ok then
    error(err)
  end
end

return M

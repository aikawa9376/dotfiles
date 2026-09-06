local M = {}

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local bufnr = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_get_current_win()
  local previous_bufnr = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_win_set_buf(win, bufnr)
  vim.b[bufnr].lazyagent_acp_pane_id = "follow-test"

  local pane_config = {
    ["follow-test"] = { follow_output = true },
  }
  local scrolls_to_end = 0
  local read_notifications = 0
  local api = {}
  local windowing = require("lazyagent.acp.view_buffer.windowing").new({
    api = api,
    pane_config = pane_config,
    pane_buffers = { ["follow-test"] = bufnr },
    layout_state = {},
    dedicated_transcript_windows = {},
    redirecting_transcript_windows = {},
    acp_window_options = {},
    custom_background_groups = {},
    set_suppress_transcript_window_refresh = function(_) end,
    follow_scroll_off = 0,
    default_scroll_off = 5,
    acp_transcript_filetype = "lazyagent-acp",
    transcript_line_count = function(_)
      return 100
    end,
    scroll_buffer_to_end = function(_)
      scrolls_to_end = scrolls_to_end + 1
    end,
    notify_transcript_read = function(pane_id)
      assert_equal(pane_id, "follow-test", "read notification pane")
      read_notifications = read_notifications + 1
    end,
  })

  vim.bo[bufnr].filetype = "markdown"
  windowing.apply_transcript_buffer_opts(bufnr)
  assert_equal(vim.bo[bufnr].filetype, "lazyagent-acp", "transcript options restore ACP filetype")

  local topline = 80
  local view_at_end = true
  local cursor_at_end = true
  api._window_topline = function(_)
    return topline
  end
  api._window_view_reaches_transcript_end = function(_win, _bufnr)
    return view_at_end
  end
  api._window_cursor_reaches_transcript_end = function(_win, _bufnr)
    return cursor_at_end
  end

  api._on_scroll_input(win, "up")
  assert_equal(pane_config["follow-test"].follow_output, false, "mouse input pauses before viewport movement")
  api._sync_follow_after_scroll(bufnr, win, { topline = -1 })
  assert_equal(pane_config["follow-test"].follow_output, false,
    "upward mouse scroll pauses active follow even while the end remains visible")
  api._sync_follow_after_cursor_moved(bufnr, win)
  assert_equal(pane_config["follow-test"].follow_output, false,
    "end cursor after mouse scrolling cannot re-enable follow")
  topline = 82
  api._sync_follow_after_scroll(bufnr, win, { topline = 2 })
  assert_equal(pane_config["follow-test"].follow_output, false,
    "scrolloff adjustment after mouse scrolling cannot re-enable follow")
  windowing.pause_follow_output(bufnr, { reason = "focus", win = win })
  api._resume_follow_if_at_end(bufnr, win)
  assert_equal(pane_config["follow-test"].follow_output, false,
    "focus changes preserve a manual scrollback pause")

  api._on_scroll_input(win, "down")
  api._on_scroll_input(win, "up")
  vim.wait(20)
  assert_equal(pane_config["follow-test"].follow_output, false,
    "new upward input cancels an already scheduled downward resume")
  assert_equal(scrolls_to_end, 0, "stale downward resume does not pull the view to the end")

  api._resume_follow_output(bufnr, { scroll = false })
  api._sync_follow_after_scroll(bufnr, win, { topline = 0, skipcol = -20 })
  assert_equal(pane_config["follow-test"].follow_output, false,
    "upward scrolling within a wrapped line pauses follow")

  api._resume_follow_output(bufnr, { scroll = false })
  cursor_at_end = false
  api._sync_follow_after_cursor_moved(bufnr, win)
  assert_equal(pane_config["follow-test"].follow_output, false,
    "moving the cursor above the end pauses follow while the end stays visible")

  cursor_at_end = true
  api._resume_follow_output(bufnr, { scroll = false })
  topline = 80
  windowing.pause_follow_output(bufnr, { reason = "focus", win = win })
  topline = 79
  api._sync_follow_after_scroll(bufnr, win)
  assert_equal(pane_config["follow-test"].follow_output, false, "upward scroll keeps follow paused")
  assert_equal(pane_config["follow-test"].follow_pause_reason, "manual", "upward scroll becomes manual pause")

  api._sync_follow_after_cursor_moved(bufnr, win)
  assert_equal(pane_config["follow-test"].follow_output, false, "cursor left at end does not resume follow")
  assert_equal(scrolls_to_end, 0, "manual upward scroll is not pulled back to end")

  api._resume_follow_if_at_end(bufnr, win)
  assert_equal(pane_config["follow-test"].follow_output, false, "leaving with an anchored end cursor stays paused")

  cursor_at_end = false
  api._sync_follow_after_cursor_moved(bufnr, win)
  cursor_at_end = true
  api._sync_follow_after_cursor_moved(bufnr, win)
  assert_equal(pane_config["follow-test"].follow_output, true, "returning the cursor to end resumes follow")
  assert_equal(scrolls_to_end, 1, "cursor return scrolls to end once")
  assert_equal(read_notifications, 1, "cursor return marks the visible transcript read")

  windowing.pause_follow_output(bufnr, { reason = "focus", win = win })
  topline = 79
  api._sync_follow_after_scroll(bufnr, win)
  api._on_scroll_input(win, "down")
  topline = 80
  api._sync_follow_after_scroll(bufnr, win)
  assert_equal(pane_config["follow-test"].follow_output, true, "downward scroll to end resumes follow")
  assert_equal(scrolls_to_end, 2, "downward return scrolls to end once")
  assert_equal(read_notifications, 2, "downward return marks the visible transcript read")

  api._expect_follow_reflow(bufnr)
  api._sync_follow_after_scroll(bufnr, win, { topline = -10 })
  assert_equal(pane_config["follow-test"].follow_output, true, "history eviction preserves follow at the new end")
  api._sync_follow_after_scroll(bufnr, win, { topline = -1 })
  assert_equal(pane_config["follow-test"].follow_output, false, "reflow exemption is consumed once")
  api._resume_follow_output(bufnr, { scroll = false })
  api._expect_follow_reflow(bufnr)
  api._on_scroll_input(win, "up")
  api._sync_follow_after_scroll(bufnr, win, { topline = -1 })
  assert_equal(pane_config["follow-test"].follow_output, false, "mouse input overrides pending automatic reflow")

  vim.api.nvim_win_set_buf(win, previous_bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

return M

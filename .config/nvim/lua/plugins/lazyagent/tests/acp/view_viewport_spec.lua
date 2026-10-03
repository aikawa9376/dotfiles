local M = {}

function M.run()
  -- This contract exercises LazyAgent materialization; the separate Markdown
  -- integration harness covers parsers and external decorations.
  local highlighter = require("lazyagent.acp.highlighter")
  local start_highlighter = highlighter.start
  highlighter.start = function() end
  local state = require("lazyagent.logic.state")
  local previous_opts = state.opts
  state.opts = { acp = { footer_animation = false } }
  local view = require("lazyagent.acp.view_buffer")
  local source_bufnr = vim.api.nvim_get_current_buf()
  local path = vim.fn.tempname() .. "-viewport.log"
  local lines = { "─ Assistant ─", "```lua" }
  -- One block longer than the prefetch range exercises entry into its middle.
  for i = 1, 7000 do
    lines[#lines + 1] = '+ local value_' .. i .. ' = "' .. string.rep("long text ", 14) .. '"'
  end
  lines[#lines + 1] = "```"
  vim.fn.writefile(lines, path)
  local pane, created
  view.create_pane({
    transcript_path = path,
    size = 10,
    acp = { agent_name = "viewport-test", transcript_max_lines = 12000,
      source_winid = vim.api.nvim_get_current_win() },
  }, function(id, result) pane, created = id, result end)
  assert(vim.wait(1000, function() return pane ~= nil end, 10), "pane opens")
  local buf, win = created.bufnr, created.winid
  local diff_ns = vim.api.nvim_create_namespace("lazyagent_acp_diff")
  local function line_at(row)
    return vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
  end
  local function background_rows()
    local rows = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, diff_ns, 0, -1, { details = true })) do
      if mark[4].hl_group == "LazyAgentACPDiffAdd" then rows[mark[2] + 1] = true end
    end
    return rows
  end
  vim.wait(200)
  assert(line_at(3500) == lines[3500], "opening leaves distant code unnormalized")
  assert(vim.api.nvim_buf_line_count(buf) >= #lines, "history row offsets remain available")
  assert(vim.tbl_count(background_rows()) < 1100, "diff marks do not fill the full history")
  vim.api.nvim_set_current_win(win)
  local function jump(command, row)
    vim.cmd("normal! " .. command)
    vim.cmd("redraw")
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
    assert(vim.wait(1000, function() return background_rows()[row] == true end, 10),
      "jump materializes its destination directly: " .. command)
    assert(line_at(row) ~= lines[row] and line_at(row):find("...", 1, true), "visible code is truncated")
    assert(vim.tbl_count(background_rows()) < 1100 * #vim.fn.win_findbuf(buf),
      "scrolling keeps decoration work bounded per visible window")
  end
  jump("3500Gzt", 3500)
  assert(line_at(2000) == lines[2000], "a distant jump does not normalize the intervening history")
  jump("ggzt", 3)
  assert(not background_rows()[3500], "offscreen diff marks are evicted")
  jump("Gzb", 7002)
  jump("3500Gzt", 3500)

  -- A second window on the same transcript must get its own visible range.
  vim.cmd("split")
  local second_win = vim.api.nvim_get_current_win()
  jump("ggzt", 3)
  assert(background_rows()[3500], "both transcript windows retain their visible decoration")
  vim.api.nvim_win_close(second_win, true)
  vim.api.nvim_set_current_win(win)

  local wide_line = line_at(3500)
  vim.cmd("vsplit")
  local resize_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(resize_win, source_bufnr)
  vim.api.nvim_win_set_width(win, 25)
  vim.api.nvim_exec_autocmds("WinResized", {})
  assert(vim.wait(1000, function() return #line_at(3500) < #wide_line end, 10),
    "narrowing normalizes the visible code")
  vim.api.nvim_win_close(resize_win, true)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_exec_autocmds("WinResized", {})
  assert(vim.wait(1000, function() return line_at(3500) == wide_line end, 10),
    "widening restores code from its untruncated source")

  local session = { pane_id = pane, agent_name = "viewport-test", transcript_path = path, view_state = {} }
  state.sessions[session.agent_name] = session
  view.configure_pane(pane, { follow_output = false })
  local text = "\n─ Assistant ─\nnext response\n"
  local file = assert(io.open(path, "a")); file:write(text); file:close()
  view.on_transcript_updated(session, text, "a")
  vim.wait(200)
  assert(vim.api.nvim_win_get_cursor(win)[1] == 3500, "streaming preserves a scrollback cursor")
  assert(line_at(2000) == lines[2000], "streaming does not restore distant code")

  state.sessions[session.agent_name] = nil
  view.kill_pane(pane, session)
  vim.fn.delete(path)
  state.opts = previous_opts
  highlighter.start = start_highlighter
end

return M

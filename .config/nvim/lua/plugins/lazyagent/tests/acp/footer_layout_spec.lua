local M = {}

function M.run()
  local view = require("lazyagent.acp.view_buffer")
  local state = require("lazyagent.logic.state")
  local agent = "footer-layout-test"
  local path = vim.fn.tempname() .. "-footer-layout.log"
  local source_win = vim.api.nvim_get_current_win()
  local previous_session = state.sessions[agent]
  local names = { "render-markdown.state", "render-markdown.core.manager", "render-markdown.core.ui" }
  local saved = {}; for _, name in ipairs(names) do saved[name] = package.loaded[name] end
  local rendered, callbacks = 0, {}
  callbacks.render = function() rendered = rendered + 1 end
  local original_render = callbacks.render
  package.loaded[names[1]] = { on = callbacks }
  package.loaded[names[2]] = { attach = function() end }
  package.loaded[names[3]] = { update = function() end }
  local runtime = { backend = agent, acp_ready = true, acp_agent_info = { title = "Fixture" } }
  state.sessions[agent] = runtime
  vim.fn.writefile({}, path)
  local pane, info
  local ok, err = xpcall(function()
    local windows = #vim.api.nvim_list_wins()
    view.create_pane({ transcript_path = path, size = 12,
      acp = { agent_name = agent, source_winid = source_win },
    }, function(id, value) pane, info = id, value end)
    assert(vim.wait(1000, function() return info ~= nil end, 10), "pane created")
    assert(#vim.api.nvim_list_wins() == windows + 1, "footer adds no separate window")
    local buf, win = info.bufnr, info.winid
    local session = { pane_id = pane, agent_name = agent, transcript_path = path, view_state = {} }
    local footer_ns = vim.api.nvim_create_namespace("lazyagent_acp_footer")
    local render_ns = vim.api.nvim_create_namespace("footer_layout_render_fixture")
    view.resume_follow(pane)

    local function footer_marks()
      return vim.api.nvim_buf_get_extmarks(buf, footer_ns, 0, -1, { details = true })
    end
    local function bottom(message)
      vim.cmd("redraw!")
      local marks = footer_marks()
      assert(#marks > 0, "footer exists")
      local last = marks[#marks][2] + 1
      local position = vim.fn.screenpos(win, last, 1)
      local expected = vim.api.nvim_win_get_position(win)[1] + vim.api.nvim_win_get_height(win)
      assert(position.row == expected, message .. ": " .. vim.inspect({ row = position.row, expected = expected }))
      assert(last == vim.api.nvim_buf_line_count(buf), "footer stays at the buffer end")
      assert(view.capture_thread_view(pane).follow_output == true, message .. ": follow remains active")
    end
    local function append(text)
      local file = assert(io.open(path, "a")); file:write(text); file:close()
      view.on_transcript_updated(session, text, "a")
      assert(vim.wait(1000, function() return session.view_state.append_timer == nil end, 10), "append flushed")
    end
    bottom("empty transcript leaves the footer at the bottom")
    assert(#view.mirror_snapshot(pane).lines == 0, "empty spacer is not transcript content")
    append("─ Assistant ─\n short reply")
    assert(#view.mirror_snapshot(pane).lines == 2, "first output contains no placeholder/spacer rows")
    assert(vim.wait(1000, function() return callbacks.render ~= original_render end, 10), "renderer hook attached")
    bottom("short reply leaves the footer at the bottom")

    local function move_cursor_up()
      vim.api.nvim_win_call(win, function()
        vim.cmd("normal! k")
        vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
      end)
    end
    local footer_end = vim.api.nvim_buf_line_count(buf)
    move_cursor_up()
    assert(vim.api.nvim_win_get_cursor(win)[1] == footer_end - 1, "first upward move stays in the spacer")
    assert(view.capture_thread_view(pane).follow_output == false, "moving up within footer padding pauses follow")
    append(" while paused")
    callbacks.render({ buf = buf, win = win })
    vim.wait(30)
    assert(vim.api.nvim_win_get_cursor(win)[1] == footer_end - 1, "stream and renderer leave the footer cursor alone")
    local transcript_end = view._transcript_end_line(buf)
    for _ = 1, footer_end - 1 - transcript_end do move_cursor_up() end
    assert(vim.api.nvim_win_get_cursor(win)[1] == transcript_end, "upward moves return to the transcript")
    assert(view.capture_thread_view(pane).follow_output == false, "approaching the transcript from below stays paused")
    view.resume_follow(pane)
    bottom("explicit follow returns from footer scrollback")

    local function thinking_mark()
      for _, mark in ipairs(footer_marks()) do
        local parts = {}; for _, chunk in ipairs(mark[4].virt_text or {}) do parts[#parts + 1] = chunk[1] end
        if table.concat(parts):find("Thinking...", 1, true) then return mark end
      end
    end
    runtime.agent_status, runtime.footer_animation = "thinking", false
    view.refresh_footer(buf)
    local thinking = assert(thinking_mark(), "thinking remains visible with animation disabled")
    assert(thinking[2] == view.mirror_snapshot(pane).line_count + 1, "thinking follows the stream before the spacer")
    assert(thinking[4].virt_text_win_col == math.floor((vim.api.nvim_win_get_width(win) - vim.fn.strdisplaywidth("Thinking...")) / 2),
      "thinking is horizontally centered")
    assert(footer_marks()[#footer_marks()][2] - thinking[2] > 3, "metadata stays at the bottom across the spacer")
    bottom("thinking and metadata occupy separate regions")
    local before_stream = thinking[2]
    append(" continues")
    thinking = assert(thinking_mark())
    assert(thinking[2] == before_stream, "same-line streaming keeps thinking directly below the last line")
    runtime.thinking_align = "left"
    view.refresh_footer(buf)
    assert(thinking_mark()[4].virt_text_win_col == 0, "thinking can use left alignment")

    runtime.footer_position = "inline"
    view.refresh_footer(buf)
    local snapshot = view.mirror_snapshot(pane)
    local marks = footer_marks()
    assert(marks[1][2] == snapshot.line_count, "legacy footer begins directly after the transcript")
    assert(vim.api.nvim_buf_line_count(buf) == snapshot.line_count + #marks, "legacy footer has no extra spacer")
    local last = marks[#marks][2] + 1
    assert(vim.fn.screenpos(win, last, 1).row < vim.api.nvim_win_get_position(win)[1] + vim.api.nvim_win_get_height(win),
      "legacy footer is not pinned to the bottom")
    runtime.footer_position, runtime.thinking_align, runtime.agent_status = "bottom", nil, nil
    view.refresh_footer(buf)
    assert(thinking_mark() == nil, "thinking clears when the agent stops thinking")
    bottom("bottom mode can be restored")
    local initial_count = vim.api.nvim_buf_line_count(buf)
    local initial_marks = footer_marks()
    append("\n next reply")
    assert(vim.api.nvim_buf_line_count(buf) == initial_count, "new output consumes the spacer first")
    assert(footer_marks()[1][2] == initial_marks[1][2], "footer does not move while the spacer shrinks")
    bottom("streaming short replies")
    append("\n " .. string.rep("折り返し test ", 16))
    bottom("wrapped output")

    vim.api.nvim_win_set_height(win, 16)
    vim.api.nvim_exec_autocmds("WinResized", {})
    bottom("height-only expansion")
    vim.api.nvim_win_set_height(win, 10)
    vim.api.nvim_exec_autocmds("WinResized", {})
    bottom("height-only contraction")

    -- Async renderer callbacks preserve the user's callback and reconcile
    -- virtual rows after the renderer has returned, even when idle.
    local function render(rows)
      vim.api.nvim_buf_clear_namespace(buf, render_ns, 0, -1)
      if rows > 0 then
        local lines = {}; for _ = 1, rows do lines[#lines + 1] = { { " rendered row" } } end
        -- Like a rendered table's final row, anchor above the first spacer.
        vim.api.nvim_buf_set_extmark(buf, render_ns, view._transcript_end_line(buf), 0,
          { virt_lines = lines, virt_lines_above = true })
      end
      callbacks.render({ buf = buf, win = win })
      vim.wait(30)
    end
    render(4); bottom("delayed virtual rows after the last transcript line")
    assert(vim.api.nvim_buf_get_extmarks(buf, render_ns, 0, -1, {})[1][2] == view._transcript_end_line(buf),
      "padding changes preserve renderer anchors at the first spacer row")
    render(0); bottom("removing delayed virtual rows")
    assert(rendered == 3, "existing render callbacks are retained")

    local growth = {}; for index = 1, 40 do growth[#growth + 1] = " streamed line " .. index end
    append("\n" .. table.concat(growth, "\n"))
    bottom("long stream flows above the footer")
    local tick, marks = vim.api.nvim_buf_get_changedtick(buf), footer_marks()
    view.refresh_footer(buf)
    assert(vim.api.nvim_buf_get_changedtick(buf) == tick, "unchanged footer does not rewrite padding")
    assert(vim.deep_equal(footer_marks(), marks), "unchanged footer preserves its marks")

    view.configure_pane(pane, { follow_output = false })
    vim.api.nvim_win_call(win, function() vim.cmd("normal! ggzt") end)
    local before = vim.api.nvim_win_call(win, vim.fn.winsaveview)
    append("\n new output while reading history")
    render(3)
    local after = vim.api.nvim_win_call(win, vim.fn.winsaveview)
    assert(before.topline == after.topline and before.lnum == after.lnum, "stream/render updates preserve scrollback")
    assert(view.capture_thread_view(pane).follow_output == false, "scrollback stays paused")
    assert(vim.fn.screenpos(win, footer_marks()[1][2] + 1, 1).row == 0, "footer scrolls away with history")
    view.resume_follow(pane)
    bottom("resuming follow returns to the bottom")
    assert(not table.concat(vim.fn.readfile(path), "\n"):find("Fixture", 1, true), "footer padding remains display-only")
  end, debug.traceback)
  if pane then view.kill_pane(pane, { pane_id = pane, transcript_path = path }) end
  state.sessions[agent] = previous_session
  for _, name in ipairs(names) do package.loaded[name] = saved[name] end
  vim.fn.delete(path)
  if not ok then error(err) end
end

return M

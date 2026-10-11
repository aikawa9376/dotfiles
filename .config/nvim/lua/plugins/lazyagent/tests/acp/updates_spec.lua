local M = {}

function M.run()
  local view = require("lazyagent.acp.view_buffer")
  -- An oversized live section survives a bounded read, then yields to a safe
  -- boundary as soon as the next section arrives through the incremental path.
  do
    local path = vim.fn.tempname() .. "-truncated-live.log"
    local raw = { "─ Tool ─", " ```lua" }
    for i = 1, 30 do raw[#raw + 1] = " previous code " .. i end
    vim.fn.writefile(raw, path)
    local pane, created
    view.create_pane({ transcript_path = path, size = 12,
      acp = { agent_name = "truncated-live-test", transcript_max_lines = 12,
        source_winid = vim.api.nvim_get_current_win() },
    }, function(id, result) pane, created = id, result end)
    assert(vim.wait(1000, function() return pane ~= nil end, 10), "bounded pane created")
    local session = { pane_id = pane, agent_name = "truncated-live-test",
      transcript_path = path, view_state = {} }
    view.on_session_created(session)
    assert(vim.wait(1000, function() return session.view_state.refresh_pending ~= true end, 10))
    local shown = vim.api.nvim_buf_get_lines(created.bufnr, 0, -1, false)
    assert(shown[2] == " previous code 19", "oversized live output is retained")
    local long_line = ' + local message = "' .. string.rep("long code ", 20) .. '"'
    local output = "─ Assistant ─\n ```lua\n" .. long_line .. "\n ```\n"
    local file = assert(io.open(path, "a")); file:write(output); file:close()
    view.on_transcript_updated(session, output, "a")
    assert(vim.wait(2000, function()
      return session.view_state.append_timer == nil and session.view_state.refresh_pending ~= true
    end, 10), "new section flushed")
    shown = vim.api.nvim_buf_get_lines(created.bufnr, 0, -1, false)
    assert(require("lazyagent.acp.view_buffer.sections").section_heading_for_line(shown[2]) == "Assistant",
      "streaming discards only the omitted section fragment")
    assert(shown[4] ~= long_line and shown[4]:find("...", 1, true), "the new code block is clipped")
    assert(vim.deep_equal(vim.fn.readfile(path), vim.list_extend(vim.deepcopy(raw),
      { "─ Assistant ─", " ```lua", long_line, " ```" })), "raw history remains complete")
    view.kill_pane(pane, session)
    vim.fn.delete(path)
  end
  for _, fence in ipairs({ "```", "````", "~~~" }) do
    local path = vim.fn.tempname() .. "-fences.log"
    -- Deliberately omit a final newline: providers can split a fence anywhere.
    local file = assert(io.open(path, "w"))
    file:write("─ Tool ─\n python3 - <<'PY'\n " .. fence)
    file:close()
    local pane, pane_state
    view.create_pane({
      transcript_path = path,
      size = 12,
      acp = { agent_name = "fence-test", source_winid = vim.api.nvim_get_current_win() },
    }, function(id, state) pane, pane_state = id, state end)
    assert(vim.wait(1000, function() return pane ~= nil end, 10), "pane created")
    local session = { pane_id = pane, agent_name = "fence-test", transcript_path = path, view_state = {} }
    view.on_session_created(session)
    local function append(text)
      local output = assert(io.open(path, "a"))
      output:write(text)
      output:close()
      view.on_transcript_updated(session, text, "a")
      assert(vim.wait(2000, function()
        return session.view_state.append_timer == nil and session.view_state.refresh_pending ~= true
      end, 10), "stream append completed")
    end
    append("python\n code")
    if #fence > 3 then append("\n ```\n code") end
    append("\n─ Assistant ─\n reply")
    local lines = vim.api.nvim_buf_get_lines(pane_state.bufnr, 0, -1, false)
    local reply_row
    for row, line in ipairs(lines) do
      if line:find("─ Assistant ─", 1, true) == 1 then reply_row = row end
    end
    assert(reply_row and lines[reply_row - 1] == " " .. fence,
      "streaming repairs the fence before the reply: " .. vim.inspect(lines))
    view.kill_pane(pane, session)
    vim.fn.delete(path)
  end

  local path = vim.fn.tempname() .. "-focus.log"
  local history = { "─ Assistant ─" }
  for i = 2, 500 do history[i] = " reply " .. i end
  vim.fn.writefile(history, path)
  local pane, pane_state
  view.create_pane({
    transcript_path = path,
    size = 12,
    acp = { agent_name = "focus-test", source_winid = vim.api.nvim_get_current_win() },
  }, function(id, state) pane, pane_state = id, state end)
  assert(vim.wait(1000, function() return pane ~= nil end, 10), "focus pane created")
  local session = { pane_id = pane, agent_name = "focus-test", transcript_path = path, view_state = {} }
  view.on_session_created(session)
  vim.wait(160)
  vim.fn.writefile({ " appended reply" }, path, "a")
  view.on_transcript_updated(session, " appended reply\n", "a")
  assert(vim.wait(2000, function() return session.view_state.append_timer == nil end, 10), "append flushed")
  assert(table.concat(vim.api.nvim_buf_get_lines(pane_state.bufnr, 0, -1, false), "\n")
    :find("appended reply", 1, true), "latest response remains visible")

  local get_lines = vim.api.nvim_buf_get_lines
  local full_reads = 0
  vim.api.nvim_buf_get_lines = function(buf, start_row, end_row, strict)
    if buf == pane_state.bufnr and start_row == 0 and (end_row == -1 or end_row > 400) then
      full_reads = full_reads + 1
    end
    return get_lines(buf, start_row, end_row, strict)
  end
  local ok, err = pcall(vim.api.nvim_set_current_win, pane_state.winid)
  vim.api.nvim_buf_get_lines = get_lines
  assert(ok, err)
  assert(full_reads == 0, "entering after an incremental flush must not rebuild the decorated history")
  view.kill_pane(pane, session)
  vim.fn.delete(path)

  -- The public runtime is not the backend session that owns the append timer.
  -- Hide inside the append batch, then reopen and keep streaming on that session.
  local state = require("lazyagent.logic.state")
  for _, close_mode in ipairs({ "break", "native", "wipe" }) do
    local agent_name = "pending-hide-" .. close_mode
    local hide_path = vim.fn.tempname() .. "-pending-hide.log"
    vim.fn.writefile({ "# User", "old prompt", "# Assistant", "old reply" }, hide_path)
    local hide_pane, hide_state
    view.create_pane({
      transcript_path = hide_path,
      size = 12,
      acp = { agent_name = agent_name, release_buffer_on_hide = true },
    }, function(id, created) hide_pane, hide_state = id, created end)
    assert(vim.wait(1000, function() return hide_pane ~= nil end, 5))
    local backend_session = { pane_id = hide_pane, agent_name = agent_name,
      transcript_path = hide_path, view_state = {} }
    state.sessions[agent_name] = { pane_id = hide_pane, acp_ready = true,
      acp_transcript_path = hide_path, agent_status = "idle" }
    local function append(text)
      local file = assert(io.open(hide_path, "a")); file:write(text); file:close()
      view.on_transcript_updated(backend_session, text, "a")
    end
    append("\n# Assistant\nqueued before hide\n")
    assert(backend_session.view_state.append_timer, "append batch is pending before hide")
    if close_mode == "break" then
      view.break_pane(hide_pane)
    else
      if close_mode == "wipe" then
        vim.api.nvim_buf_delete(hide_state.bufnr, { force = true })
      else
        vim.api.nvim_win_close(hide_state.winid, true)
      end
      assert(vim.wait(200, function() return not vim.api.nvim_buf_is_valid(hide_state.bufnr) end, 5))
      -- Let the old one-shot timer fire while the released buffer is absent.
      vim.wait(100, function() return false end, 5)
    end
    assert(backend_session.view_state.append_timer == nil, "hide releases the backend append timer")
    assert(backend_session.view_state.pending_append_size == 0, "hide discards bytes already saved on disk")
    view.join_pane(hide_pane, 12, false, nil, backend_session)
    append("\n# User\ninput after reopen\n# Assistant\nreply after reopen\n")
    assert(vim.wait(1000, function() return backend_session.view_state.append_timer == nil end, 5),
      "reopened transcript schedules and completes a fresh batch")
    local hide_buf = view.debug_snapshot().panes[hide_pane].bufnr
    local text = table.concat(vim.api.nvim_buf_get_lines(hide_buf, 0, -1, false), "\n")
    assert(text:find("input after reopen", 1, true) and text:find("reply after reopen", 1, true),
      "reopened transcript displays new inputs and replies")
    local _, count = text:gsub("queued before hide", "")
    assert(count == 1, "reopening does not replay the disk-backed batch twice")
    view.kill_pane(hide_pane, backend_session)
    state.sessions[agent_name] = nil
    vim.fn.delete(hide_path)
  end
end

return M

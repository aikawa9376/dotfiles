local M = {}

function M.run()
  local view = require("lazyagent.acp.view_buffer")
  local state = require("lazyagent.logic.state")
  local sections = require("lazyagent.acp.view_buffer.sections")
  local agent = "conversation-filter-test"
  local path = vim.fn.tempname() .. "-conversation.log"
  local raw = {
    "─ System ─", " setup log",
    "─ User ─", " question",
    "─ Thinking ─", " private thought",
    "─ Tool ─", " tool output", " ```lua", " print('tool')",
    "─ Assistant ─", " answer",
  }
  local timeline = {
    { id = "setup", kind = "system" },
    { id = "question", kind = "user" },
    { id = "thought", kind = "thinking" },
    { id = "tool", kind = "tool" },
    { id = "answer", kind = "assistant" },
  }
  local old_session, old_backend = state.sessions[agent], state.backends[agent]
  local runtime = { backend = agent, transcript_path = path, acp_conversation_timeline = timeline }
  state.sessions[agent] = runtime
  local pinned_id
  state.backends[agent] = { toggle_conversation_pin = function(_, id) pinned_id = id; return true end }
  local file = assert(io.open(path, "w"))
  file:write(table.concat(raw, "\n"))
  file:close()
  local pane, pane_state
  view.create_pane({ transcript_path = path, size = 12,
    acp = { agent_name = agent, source_winid = vim.api.nvim_get_current_win(), release_buffer_on_hide = true },
  }, function(id, info) pane, pane_state = id, info end)
  assert(vim.wait(1000, function() return pane ~= nil end, 10), "pane created")
  -- Backend and public runtime sessions are distinct in real sessions too.
  local session = { pane_id = pane, agent_name = agent, transcript_path = path, view_state = {} }
  runtime.pane_id = pane
  view.on_session_created(session)
  assert(vim.wait(1000, function() return session.view_state.refresh_pending ~= true end, 10))
  local function text()
    return table.concat(vim.api.nvim_buf_get_lines(pane_state.bufnr, 0, -1, false), "\n")
  end
  local function append(value, wait)
    local output = assert(io.open(path, "a"))
    output:write(value)
    output:close()
    view.on_transcript_updated(session, value, "a")
    if wait ~= false then
      assert(vim.wait(2000, function() return session.view_state.append_timer == nil end, 10), "append flushed")
    end
  end
  assert(text():find("tool output", 1, true), "default display includes logs")
  vim.api.nvim_set_current_win(pane_state.winid)
  local toggle = vim.fn.maparg("gC", "n", false, true)
  assert(type(toggle.callback) == "function", "buffer toggle is mapped")
  toggle.callback()
  assert(text():find("question", 1, true) and text():find("answer", 1, true), "both speakers remain")
  for _, hidden in ipairs({ "setup log", "private thought", "tool output", "print('tool')" }) do
    assert(not text():find(hidden, 1, true), "hidden section: " .. hidden)
  end
  append(" continues")
  assert(text():find("answer continues", 1, true), "visible streaming continues: " .. text())

  -- A filtered assistant still points at its original timeline item after an
  -- incremental append; pin/copy/navigation must not select a hidden tool.
  local visible = vim.api.nvim_buf_get_lines(pane_state.bufnr, 0, -1, false)
  local visible_sections = sections.collect_transcript_sections(visible)
  vim.api.nvim_win_set_cursor(pane_state.winid, { visible_sections[#visible_sections].start_row + 1, 0 })
  local select = vim.ui.select
  vim.ui.select = function(actions, _, callback)
    for _, action in ipairs(actions) do
      if action.label == "Pin current block" then callback(action); return end
    end
    error("pin action missing")
  end
  local ok, err = pcall(vim.fn.maparg("ga", "n", false, true).callback)
  vim.ui.select = select
  assert(ok, err)
  assert(pinned_id == "answer", "filtered actions keep the original message ID")

  for _, heading in ipairs({ "Thinking", "Tool", "Edited", "Terminal", "Plan", "System", "Error" }) do
    timeline[#timeline + 1] = { id = heading, kind = heading:lower() }
    append("\n─ " .. heading .. " ─\n hidden " .. heading)
    local tick = vim.api.nvim_buf_get_changedtick(pane_state.bufnr)
    append(" continuation")
    assert(not text():find("hidden " .. heading, 1, true), heading .. " stays hidden while streaming")
    assert(vim.api.nvim_buf_get_changedtick(pane_state.bufnr) == tick, "hidden chunks do not rewrite the buffer")
  end
  timeline[#timeline + 1] = { id = "reply", kind = "assistant" }
  append("\n─ Assistant ─\n next reply")
  assert(text():find("next reply", 1, true), "reply after hidden output is visible")

  -- Toggle with unflushed output, including the direct buffer mapping path.
  append(" pending", false)
  toggle.callback()
  assert(vim.wait(1000, function() return session.view_state.append_timer == nil end, 10))
  assert(text():find("hidden Error continuation", 1, true), "toggle restores logs")
  local _, pending_count = text():gsub(" pending", "")
  assert(pending_count == 1, "toggle does not duplicate pending output")
  assert(view.toggle_conversation_only(pane, session) == true)

  -- Full transcript remains available while the live pane is filtered.
  assert(view.open_fullscreen_transcript(pane, session))
  local inspector = vim.b.lazyagent_acp_pane_id
  local full_text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  assert(full_text:find("hidden Error", 1, true), "fullscreen opens all logs")
  vim.cmd("tabclose")
  view.kill_pane(inspector)

  assert(view.break_pane(pane, session))
  assert(not vim.api.nvim_buf_is_valid(pane_state.bufnr), "hidden buffer released")
  assert(view.join_pane(pane, 12, false, nil, session))
  local info
  view.get_pane_info(pane, function(value) info = value end, session)
  assert(vim.wait(1000, function() return info ~= nil end, 10))
  local reopened = view.mirror_snapshot(pane)
  assert(not table.concat(reopened.lines, "\n"):find("hidden Error", 1, true), "filter survives buffer release and reopen")
  assert(table.concat(vim.fn.readfile(path), "\n"):find("hidden Error", 1, true), "disk log remains intact")
  view.kill_pane(pane, session)
  -- A pane with only diagnostics must remain empty until a real message arrives.
  file = assert(io.open(path, "w"))
  file:write("─ System ─\n only logs")
  file:close()
  timeline = { { id = "only-logs", kind = "system" } }
  runtime.acp_conversation_timeline = timeline
  pane = nil
  view.create_pane({ transcript_path = path, size = 12,
    acp = { agent_name = agent, source_winid = vim.api.nvim_get_current_win(),
      transcript_compaction = { enabled = true, min_sections = 2, keep_recent_sections = 1 } },
  }, function(id, info) pane, pane_state = id, info end)
  assert(vim.wait(1000, function() return pane ~= nil end, 10))
  session = { pane_id = pane, agent_name = agent, transcript_path = path, view_state = {} }
  runtime.pane_id = pane
  assert(view.toggle_conversation_only(pane, session))
  append(" continuation")
  assert(not text():find("only logs", 1, true), "log-only pane stays empty")
  timeline[#timeline + 1] = { id = "new-question", kind = "user" }
  append("\n─ User ─\n new question")
  timeline[#timeline + 1] = { id = "new-answer", kind = "assistant" }
  append("\n─ Assistant ─\n new answer")
  assert(text():find("new question", 1, true) and text():find("new answer", 1, true),
    "both messages remain even when section compaction is configured")
  assert(not text():find("compacted", 1, true), "conversation-only display has no synthetic log summary")
  view.kill_pane(pane, session)
  state.sessions[agent], state.backends[agent] = old_session, old_backend
  vim.fn.delete(path)
end

return M

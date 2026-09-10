local M = {}

function M.run()
  local view = require("lazyagent.acp.view_buffer")
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
end

return M

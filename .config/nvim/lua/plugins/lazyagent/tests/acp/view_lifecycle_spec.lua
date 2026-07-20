local M = {}

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local render_module_names = {
    "render-markdown.core.manager",
    "render-markdown.core.ui",
    "render-markdown.state",
  }
  local previous_render_modules = {}
  for _, name in ipairs(render_module_names) do
    previous_render_modules[name] = package.loaded[name]
  end
  local render_updates = 0
  local render_group = vim.api.nvim_create_augroup("RenderMarkdown", { clear = true })
  package.loaded["render-markdown.core.manager"] = {
    buffers = {},
    attach = function(bufnr)
      vim.api.nvim_create_autocmd({ "CmdlineChanged", "ModeChanged", "TextChanged" }, {
        group = render_group,
        buffer = bufnr,
        callback = function() end,
      })
    end,
  }
  package.loaded["render-markdown.core.ui"] = {
    cache = {},
    ns = vim.api.nvim_create_namespace("lazyagent_test_render_markdown"),
    update = function() render_updates = render_updates + 1 end,
  }
  package.loaded["render-markdown.state"] = { cache = {} }

  local view = require("lazyagent.acp.view_buffer")
  local pane_id
  local pane_state
  local transcript_path = vim.fn.tempname() .. "-lazyagent-acp.log"
  local transcript_lines = { "# System", "lifecycle test" }
  for index = 1, 60 do
    transcript_lines[#transcript_lines + 1] = "line " .. tostring(index)
  end
  vim.fn.writefile(transcript_lines, transcript_path)

  view.create_pane({
    transcript_path = transcript_path,
    size = 8,
    is_vertical = false,
    opts = {},
    acp = {
      agent_name = "lifecycle-test",
      source_winid = vim.api.nvim_get_current_win(),
      source_bufnr = vim.api.nvim_get_current_buf(),
    },
  }, function(created_pane_id, created_state)
    pane_id = created_pane_id
    pane_state = created_state
  end)

  assert(vim.wait(1000, function()
    return pane_id ~= nil
  end, 10), "buffer view should be created")

  local live = view.debug_snapshot()
  assert_equal(live.pane_count, 1, "live pane ownership")
  assert_equal(live.buffer_count, 1, "live buffer ownership")
  assert_equal(live.valid_buffer_count, 1, "live valid buffer")
  assert_equal(live.config_count, 1, "live pane configuration")
  assert(live.window_count >= 1, "live transcript should have a window")

  vim.wait(300)
  render_updates = 0
  local transcript_bufnr = assert(live.panes[tostring(pane_id)]).bufnr
  assert_equal(#vim.api.nvim_get_autocmds({
    group = render_group,
    event = "CmdlineChanged",
    buffer = transcript_bufnr,
  }), 1, "ACP transcript leaves another plugin's cmdline autocmd untouched")
  assert_equal(#vim.api.nvim_get_autocmds({
    group = render_group,
    buffer = transcript_bufnr,
  }), 3, "ACP transcript preserves all render-markdown updates")

  local session = {
    pane_id = pane_id,
    agent_name = "lifecycle-test",
    transcript_path = transcript_path,
    view_state = vim.tbl_extend("force", pane_state or {}, {}),
  }
  local popup_bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[popup_bufnr].buftype = "nofile"
  vim.bo[popup_bufnr].filetype = "vim"
  vim.api.nvim_buf_set_lines(popup_bufnr, 0, -1, false, { ":LazyAgentTest" })
  local popup_winid = vim.api.nvim_open_win(popup_bufnr, true, {
    relative = "editor",
    row = 0,
    col = 0,
    width = 30,
    height = 1,
    style = "minimal",
  })

  view.on_transcript_updated(session, "\nsecond response", "a")
  assert(vim.wait(1000, function() return render_updates == 1 end, 10),
    "agent output redraws its owned transcript")
  vim.wait(250)
  assert_equal(render_updates, 1, "owned transcript redraw is coalesced")
  assert_equal(vim.api.nvim_get_current_win(), popup_winid, "external popup keeps focus during ACP output")
  assert_equal(vim.api.nvim_get_current_buf(), popup_bufnr, "external popup keeps its buffer during ACP output")
  assert_equal(vim.bo[popup_bufnr].filetype, "vim", "external popup filetype is untouched")
  assert_equal(vim.api.nvim_buf_get_lines(popup_bufnr, 0, -1, false)[1], ":LazyAgentTest",
    "external popup content is untouched")
  assert_equal(vim.b[popup_bufnr].lazyagent_acp_pane_id, nil, "external popup is not claimed by LazyAgent")
  vim.api.nvim_win_close(popup_winid, true)
  vim.api.nvim_buf_delete(popup_bufnr, { force = true })

  vim.api.nvim_win_call(pane_state.winid, function()
    vim.fn.winrestview({ lnum = 30, topline = 24, col = 0, leftcol = 0 })
  end)
  local saved_view = assert(view.capture_thread_view(pane_id))
  assert_equal(saved_view.view.lnum, 30, "captured thread cursor")
  assert_equal(saved_view.view.topline, 24, "captured thread topline")
  vim.api.nvim_win_call(pane_state.winid, function()
    vim.fn.winrestview({ lnum = 1, topline = 1, col = 0, leftcol = 0 })
  end)
  assert_equal(view.restore_thread_view(pane_id, saved_view), true, "restore thread view")
  local restored_view = assert(view.capture_thread_view(pane_id))
  assert_equal(restored_view.view.lnum, saved_view.view.lnum, "restored thread cursor")
  assert_equal(restored_view.view.topline, saved_view.view.topline, "restored thread topline")

  session.view_state = vim.tbl_extend("force", session.view_state or {}, {
    pending_append = "queued",
    pending_append_chunks = { "queued" },
    pending_append_size = 6,
  })
  view.kill_pane(pane_id, session)

  local closed = view.debug_snapshot()
  assert_equal(closed.pane_count, 0, "closed pane ownership")
  assert_equal(closed.buffer_count, 0, "closed buffer ownership")
  assert_equal(closed.valid_buffer_count, 0, "closed valid buffer")
  assert_equal(closed.window_count, 0, "closed transcript windows")
  assert_equal(closed.config_count, 0, "closed pane configuration")
  assert_equal(closed.layout_count, 0, "closed layout state")
  assert_equal(closed.active_timer_count, 0, "closed view timers")
  assert_equal(session.view_state.pending_append, nil, "closed append payload")
  assert_equal(session.view_state.pending_append_chunks, nil, "closed append chunks")

  local backend = require("lazyagent.acp.backend").new(view)
  local backend_debug = backend.get_debug_snapshot()
  assert_equal(backend_debug.session_count, 0, "closed backend sessions")
  assert_equal(backend_debug.transcript_owner_count, 0, "closed transcript ownership")
  assert_equal(backend_debug.terminal_count, 0, "closed terminals")
  assert_equal(backend_debug.child_process_count, 0, "closed child processes")
  assert_equal(backend_debug.timer_count, 0, "closed backend timers")
  assert_equal(backend_debug.callback_count, 0, "closed backend callbacks")

  pcall(vim.api.nvim_del_augroup_by_id, render_group)
  for _, name in ipairs(render_module_names) do
    package.loaded[name] = previous_render_modules[name]
  end
  vim.fn.delete(transcript_path)
end

return M

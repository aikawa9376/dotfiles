local M = {}

function M.run()
  local view = require("lazyagent.acp.view_buffer")
  local state = require("lazyagent.logic.state")
  local previous_opts = state.opts.image_paste
  local previous_snacks = package.loaded["snacks"]
  local source_win = vim.api.nvim_get_current_win()
  local image_path = vim.fn.tempname() .. ".png"
  local transcript_path = vim.fn.tempname() .. "-image-follow.log"
  local ns = vim.api.nvim_create_namespace("lazyagent_test_image_follow")
  local placements = {}
  local pane, info

  local ok, err = xpcall(function()
    vim.fn.writefile({ "image fixture" }, image_path)
    local lines = { "─ Assistant ─" }
    for index = 1, 60 do lines[#lines + 1] = " answer " .. index end
    lines[#lines + 1] = " @" .. image_path
    lines[#lines + 1] = " text below the image"
    vim.fn.writefile(lines, transcript_path)
    state.opts.image_paste = { enabled = true, preview = {
      enabled = true, acp_prefetch_lines = 40, acp_refresh_debounce_ms = 0,
    } }
    package.loaded["snacks"] = { image = { placement = { new = function(buf, _, opts)
      local placement = { opts = opts }
      -- Retain real Neovim virtual rows, replacing only image conversion and
      -- terminal graphics. render() represents a delayed Snacks update.
      function placement:render(height)
        local rows = {}
        for _ = 1, height do rows[#rows + 1] = { { " image row " } } end
        self.mark = vim.api.nvim_buf_set_extmark(buf, ns, self.opts.pos[1] - 1, 0,
          { id = self.mark, virt_lines = rows })
        if self.opts.on_update then self.opts.on_update(self) end
      end
      function placement:update() end
      function placement:show() end
      function placement:close()
        self.closed = true
        if self.mark then vim.api.nvim_buf_del_extmark(buf, ns, self.mark) end
      end
      placements[#placements + 1] = placement
      return placement
    end } } }

    view.create_pane({ transcript_path = transcript_path, size = 12,
      acp = { agent_name = "image-follow-test", source_winid = source_win },
    }, function(id, value) pane, info = id, value end)
    assert(vim.wait(1000, function() return info ~= nil end, 10), "transcript created")
    view.resume_follow(pane)
    require("lazyagent.logic.image_paste").refresh_buffer_previews(info.bufnr)
    assert(#placements > 0, "image preview created")
    local buf, win = info.bufnr, info.winid
    local placement = placements[#placements]
    view.resume_follow(pane)

    local function assert_follow(message)
      assert(view.capture_thread_view(pane).follow_output == true, message)
      assert(view._window_view_reaches_transcript_end(win, buf), message .. ": end stays visible")
    end
    placement:render(8)
    view._sync_follow_after_scroll(buf, win, { topline = 0, topfill = 8 })
    assert_follow("delayed image loading preserves follow through virtual-row scroll")
    placement:render(3)
    view._sync_follow_after_scroll(buf, win, { topline = -5 })
    assert_follow("image shrinking preserves follow through upward reflow")

    -- User input takes priority even between placement and its scroll event.
    placement:render(8)
    view._on_scroll_input(win, "up")
    view._sync_follow_after_scroll(buf, win, { topline = -1 })
    assert(view.capture_thread_view(pane).follow_output == false, "wheel up overrides pending image reflow")
    vim.api.nvim_win_set_cursor(win, { 20, 0 })
    local before = vim.api.nvim_win_get_cursor(win)
    placement:render(2)
    assert(view.capture_thread_view(pane).follow_output == false, "late image update preserves manual pause")
    assert(vim.deep_equal(vim.api.nvim_win_get_cursor(win), before), "late image update preserves scrollback cursor")

    view.resume_follow(pane)
    require("lazyagent.logic.image_paste").clear_buffer_previews(buf)
    view._sync_follow_after_scroll(buf, win, { topline = -2 })
    assert_follow("removing an image preserves follow")

    local session = { pane_id = pane, agent_name = "image-follow-test", transcript_path = transcript_path, view_state = {} }
    local text = "\n next streamed reply"
    vim.fn.writefile({ " next streamed reply" }, transcript_path, "a")
    view.on_transcript_updated(session, text, "a")
    assert(vim.wait(1000, function() return session.view_state.append_timer == nil end, 10), "append flushed")
    assert_follow("streaming continues following after image reflow")
  end, debug.traceback)

  if pane then view.kill_pane(pane, { pane_id = pane, transcript_path = transcript_path }) end
  package.loaded["snacks"] = previous_snacks
  state.opts.image_paste = previous_opts
  vim.fn.delete(image_path)
  vim.fn.delete(transcript_path)
  if not ok then error(err) end
end

return M

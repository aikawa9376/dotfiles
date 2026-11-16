local M = {}
function M.run()
  local guard = require("lazyagent.acp.renderer_layout")
  local source = vim.api.nvim_get_current_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "lazyagent_acp"
  vim.api.nvim_win_set_buf(0, buf)
  local win = vim.api.nvim_get_current_win()
  local old_linebreak = vim.wo[win].linebreak
  vim.wo[win].linebreak = true
  local calls, renders = {}, 0
  local ui = { update = function(_, _, event) calls[#calls + 1] = event end }
  local callbacks = { render = function() renders = renders + 1 end }
  guard.install(ui, callbacks)
  local update, render = ui.update, callbacks.render
  guard.install(ui, callbacks)
  assert(ui.update == update and callbacks.render == render, "layout guard installs once")
  ui.update(buf, win, "Initial", true)
  -- Native paragraph wrapping takes ownership of this option during rendering.
  vim.wo[win].linebreak = false
  callbacks.render({ buf = buf, win = win })
  local baseline = #calls
  local popup = vim.api.nvim_create_buf(false, true)
  local float = vim.api.nvim_open_win(popup, false, {
    relative = "editor", row = 1, col = 1, width = 20, height = 1, style = "minimal",
  })
  ui.update(buf, win, "ParagraphGeometry", true)
  vim.api.nvim_win_close(float, true)
  ui.update(buf, win, "ParagraphGeometry", true)
  assert(#calls == baseline, "unrelated popup opening/closing cannot force ACP reflow")
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "New streamed reply" })
  vim.bo[buf].modifiable = false
  ui.update(buf, win, "TextChanged", false)
  assert(#calls == baseline + 1, "text updates retain the original rendering path")
  ui.update(buf, win, "UserCommand", true)
  assert(#calls == baseline + 2, "explicit refresh cannot be filtered")
  callbacks.render({ buf = buf, win = win })
  vim.wo[win].wrap = not vim.wo[win].wrap
  ui.update(buf, win, "ParagraphGeometry", true)
  assert(#calls == baseline + 3, "actual ACP wrapping-option changes still reflow")
  callbacks.render({ buf = buf, win = win })
  vim.wo[win].wrap = not vim.wo[win].wrap
  ui.update(buf, win, "ParagraphGeometry", true)
  callbacks.render({ buf = buf, win = win })
  vim.cmd("vsplit")
  local shared = vim.api.nvim_get_current_win()
  local count = #calls
  ui.update(buf, win, "ParagraphGeometry", true)
  assert(#calls == count + 1, "sharing the source buffer changes its layout")
  callbacks.render({ buf = buf, win = win })
  vim.api.nvim_win_close(shared, true)
  count = #calls
  ui.update(buf, win, "ParagraphGeometry", true)
  assert(#calls == count + 1, "closing a shared source window restores its layout")
  callbacks.render({ buf = buf, win = win })
  ui.update(buf, win, "ModeChanged", false)
  assert(calls[#calls] == "ModeChanged", "mode transitions are not overridden")
  vim.bo[popup].filetype = "markdown"
  count = #calls
  ui.update(popup, win, "ParagraphGeometry", true)
  ui.update(popup, win, "ParagraphGeometry", true)
  assert(#calls == count + 2, "ordinary Markdown policy is unchanged")
  assert(renders == 6, "user render callbacks are preserved")
  vim.api.nvim_win_set_buf(win, source)
  vim.api.nvim_buf_delete(buf, { force = true })
  assert(ui._lazyagent_layout_guard[buf] == nil, "wiped ACP buffers release geometry snapshots")
  vim.api.nvim_buf_delete(popup, { force = true })
  vim.wo[win].linebreak = old_linebreak
end
return M

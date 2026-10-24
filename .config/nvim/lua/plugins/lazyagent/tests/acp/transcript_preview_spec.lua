local M = {}

function M.run()
  local highlighter = require("lazyagent.acp.highlighter")
  local original_start = highlighter.start
  local starts = 0
  highlighter.start = function() starts = starts + 1 end
  local source_win = vim.api.nvim_get_current_win()
  vim.cmd("vsplit")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_width(win, 32)
  vim.bo[buf].modifiable = false
  local renderer = require("lazyagent.acp.transcript_preview").attach(buf)
  local ns = vim.api.nvim_create_namespace("lazyagent_acp_preview")
  local lines = {
    "─ 󰋽 System", "Connected",
    "─ 󰍩 User · 2026-10-24 08:13 " .. string.rep("─", 80), "prompt",
    "─ 󰭹 Codex 6.1 Sol High · 2026-10-24 08:14 " .. string.rep("─", 80), "answer",
    "─ 󱁤 Tool execute completed", " - System output remains literal",
    "```lua", "print('code')", "```",
  }
  local original_lines = vim.deepcopy(lines)
  local function set(value, transcript)
    renderer.set(value, { transcript = transcript, provider = "Codex" })
    assert(not vim.bo[buf].modifiable and not vim.bo[buf].modified, "preview remains read only and clean")
  end
  local function text(row)
    return vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
  end
  local function groups()
    local result = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      result[mark[2] + 1] = mark[4].hl_group
    end
    return result
  end
  set(lines, true)
  assert(vim.bo[buf].filetype == "lazyagent_acp", "mirror selects the ACP Markdown handler")
  assert(starts > 0, "mirror starts the guarded ACP Markdown highlighter")
  assert(vim.b[buf].lazyagent_acp_pane_id == nil, "preview does not become an ACP pane")
  local painted = groups()
  assert(painted[1] == "LazyAgentACPSystemHeader", "system header retains its ACP color")
  assert(painted[3] == "LazyAgentACPUserHeader", "user header retains its ACP color")
  assert(painted[5] == "LazyAgentACPAssistantHeader", "model/provider header retains its ACP color")
  assert(painted[7] == "LazyAgentACPToolHeader", "tool header retains its ACP color")
  assert(painted[8] == nil, "tool output is not mistaken for a transcript header")
  for _, row in ipairs({ 1, 3, 5, 7 }) do
    assert(vim.fn.strdisplaywidth(text(row)) <= vim.api.nvim_win_get_width(win), "header fits the preview width")
  end
  assert(text(5):find("Codex 6.1 Sol High", 1, true), "model name precedes truncated timestamp and separator")
  assert(vim.deep_equal(lines, original_lines), "normalization never mutates source snapshot")
  assert(text(8) == lines[8] and text(10) == lines[10], "body and fenced code stay intact")

  local narrow = text(5)
  vim.api.nvim_win_set_width(win, 65)
  vim.api.nvim_exec_autocmds("WinResized", {})
  assert(text(5) ~= narrow and not text(5):find("…", 1, true), "widening restores the original model heading")
  assert(vim.fn.strdisplaywidth(text(5)) <= vim.api.nvim_win_get_width(win), "restored separator fits new width")
  vim.api.nvim_win_set_width(win, 24)
  vim.api.nvim_exec_autocmds("WinResized", {})
  assert(vim.fn.strdisplaywidth(text(5)) <= 24, "narrowing recomputes Unicode display width")

  local long = { "─ System", "start" }
  for _ = 1, 500 do long[#long + 1] = "body" end
  long[#long + 1] = "─ Tool completed"
  set(long, true)
  vim.api.nvim_win_set_cursor(win, { #long, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
  assert(groups()[#long] == "LazyAgentACPToolHeader", "scrolling paints headers outside the initial viewport")
  assert(groups()[1] == nil, "offscreen decorations are released")

  set({ "# Details", "─ System is ordinary detail text" }, false)
  assert(vim.bo[buf].filetype == "lazyagent_acp", "details retain the same Markdown renderer configuration")
  assert(next(groups()) == nil, "switching modes clears transcript colors")
  set(lines, true)
  assert(groups()[1] == "LazyAgentACPSystemHeader", "returning to mirror restores transcript decoration")
  vim.api.nvim_buf_delete(buf, { force = true })
  local ok = pcall(vim.api.nvim_get_autocmds, { group = "LazyAgentACPPreviewRender" .. buf })
  assert(not ok, "wiping a preview removes global scroll and resize callbacks")
  if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  vim.api.nvim_set_current_win(source_win)
  highlighter.start = original_start
end

return M

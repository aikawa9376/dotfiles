-- Measure entry into an already visible transcript while a reply is pending.
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
local output_path = assert(vim.env.LAZYAGENT_BENCH_OUT, "set LAZYAGENT_BENCH_OUT")
vim.opt.rtp:prepend(root)
vim.opt.rtp:append(vim.fn.stdpath("data") .. "/site")
local uv = vim.uv or vim.loop
local baseline = vim.env.LAZYAGENT_FOCUS_BASELINE_DIR
if baseline then
  package.loaded["lazyagent.acp.view_diff"] = dofile(baseline .. "/view_diff.lua")
  package.loaded["lazyagent.acp.view_buffer.updates"] = dofile(baseline .. "/updates.lua")
end

local markdown = pcall(vim.treesitter.language.add, "markdown")
local lua = pcall(vim.treesitter.language.add, "lua")
assert(markdown and lua, "install the markdown and lua parsers before measuring capture latency")
vim.treesitter.language.register("markdown", "lazyagent_acp")
vim.api.nvim_create_autocmd("FileType", {
  pattern = "lazyagent_acp",
  callback = function(args) vim.treesitter.start(args.buf, "markdown") end,
})

local captures = 0
local captures_at_pos = vim.treesitter.get_captures_at_pos
vim.treesitter.get_captures_at_pos = function(...)
  captures = captures + 1
  return captures_at_pos(...)
end
local state = require("lazyagent.logic.state")
state.opts = { acp = { footer_animation = false } }
local view = require("lazyagent.acp.view_buffer")
local path = vim.fn.tempname() .. "-focus.log"
local lines = {}
for _ = 1, 150 do
  vim.list_extend(lines, { "─ Assistant ─", "```lua" })
  for i = 1, 30 do
    lines[#lines + 1] = 'local message_' .. i .. ' = "' .. string.rep("long text ", 16) .. '"'
  end
  lines[#lines + 1] = "```"
end
vim.fn.writefile(lines, path)
local pane, pane_state
view.create_pane({
  transcript_path = path,
  size = 12,
  acp = { agent_name = "focus-bench", transcript_max_lines = 12000, source_winid = vim.api.nvim_get_current_win() },
}, function(id, created) pane, pane_state = id, created end)
assert(vim.wait(30000, function() return pane ~= nil end, 10), "pane created")
local session = { pane_id = pane, agent_name = "focus-bench", transcript_path = path, view_state = {} }
state.sessions[session.agent_name] = session
view.on_session_created(session)
vim.wait(160)

local results = {}
for i = 1, 3 do
  vim.api.nvim_set_current_win(pane_state.source_winid)
  vim.wait(160)
  local text = " reply " .. i .. "\n"
  local file = assert(io.open(path, "a")); file:write(text); file:close()
  view.on_transcript_updated(session, text, "a")
  assert(session.view_state.append_timer ~= nil, "a batched reply is pending before entry")
  captures = 0
  local started = uv.hrtime()
  vim.api.nvim_set_current_win(pane_state.winid)
  local entry_ms = (uv.hrtime() - started) / 1e6
  local entry_captures = captures
  vim.api.nvim_win_set_cursor(pane_state.winid, { 5, 10 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = pane_state.bufnr })
  vim.wait(160)
  assert(session.view_state.append_timer == nil, "entry flushes the pending reply")
  assert(table.concat(vim.api.nvim_buf_get_lines(pane_state.bufnr, 0, -1, false), "\n")
    :find("reply " .. i, 1, true), "entry preserves the newest response")
  results[#results + 1] = { entry_ms = entry_ms, entry_capture_lookups = entry_captures, settled_capture_lookups = captures }
end
vim.fn.writefile({ vim.json.encode({ source_lines = #lines, samples = results }) }, output_path)
state.sessions[session.agent_name] = nil
view.kill_pane(pane, session)
vim.fn.delete(path)

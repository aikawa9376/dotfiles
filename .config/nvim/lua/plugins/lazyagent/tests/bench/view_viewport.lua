-- Compare actual buffer work when reopening a large diff/code transcript.
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
vim.opt.rtp:prepend(root)
local output = assert(vim.env.LAZYAGENT_BENCH_OUT, "set LAZYAGENT_BENCH_OUT")
local baseline = vim.env.LAZYAGENT_VIEWPORT_BASELINE_DIR
if baseline then
  local render = dofile(baseline .. "/render.lua")
  local new = render.new
  render.new = function(ctx)
    ctx.decorate_prefetch_margin = 80
    ctx.decorate_sync_line_limit = 600
    ctx.decorate_chunk_size = 400
    return new(ctx)
  end
  package.loaded["lazyagent.acp.view_buffer.render"] = render
  package.loaded["lazyagent.acp.view_diff"] = dofile(baseline .. "/view_diff.lua")
end
local state = require("lazyagent.logic.state")
state.opts = { acp = { footer_animation = false } }
require("lazyagent.acp.highlighter").start = function() end
local view = require("lazyagent.acp.view_buffer")
local path = vim.fn.tempname() .. "-viewport-bench.log"
local lines = {}
for _ = 1, 200 do
  vim.list_extend(lines, { "─ Assistant ─", "```lua" })
  for i = 1, 32 do
    lines[#lines + 1] = '+ local value_' .. i .. ' = "' .. string.rep("long text ", 14) .. '"'
  end
  lines[#lines + 1] = "```"
end
vim.fn.writefile(lines, path)
local widths, marks = 0, 0
local displaywidth, extmark = vim.fn.strdisplaywidth, vim.api.nvim_buf_set_extmark
vim.fn.strdisplaywidth = function(...)
  widths = widths + 1
  return displaywidth(...)
end
vim.api.nvim_buf_set_extmark = function(...)
  marks = marks + 1
  return extmark(...)
end
local pane, created
local started = vim.uv.hrtime()
view.create_pane({ transcript_path = path, size = 12,
  acp = { agent_name = "viewport-bench", transcript_max_lines = 12000,
    source_winid = vim.api.nvim_get_current_win() },
}, function(id, result) pane, created = id, result end)
assert(vim.wait(1000, function() return pane ~= nil end, 10), "pane opens")
local open_ms = (vim.uv.hrtime() - started) / 1e6
vim.wait(200)
local diff_marks = #vim.api.nvim_buf_get_extmarks(created.bufnr,
  vim.api.nvim_create_namespace("lazyagent_acp_diff"), 0, -1, {})
vim.fn.writefile({ vim.json.encode({ source_lines = #lines, open_ms = open_ms,
  width_calculations = widths, extmark_writes = marks, retained_diff_marks = diff_marks,
}) }, output)
view.kill_pane(pane, { pane_id = pane, transcript_path = path })
vim.fn.delete(path)

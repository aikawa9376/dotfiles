-- Native Tree-sitter memory pressure with a realistic retained Lua heap.
-- Run baseline/bounded modes in separate fresh processes; no user transcript,
-- provider, malloc_trim, GC option changes, or external renderer is involved.
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
vim.opt.rtp:prepend(root)
vim.opt.rtp:append(assert(vim.env.LAZYAGENT_PARSER_RTP))
local mode = vim.env.LAZYAGENT_PARSER_GC_MODE or "bounded"
assert(mode == "bounded" or mode == "baseline")
local loops = tonumber(vim.env.LAZYAGENT_BENCH_LOOPS) or 40
local heap_mib = tonumber(vim.env.LAZYAGENT_BENCH_HEAP_MIB) or 128
local rows = 3000
local retained = {}
while collectgarbage("count") < heap_mib * 1024 do
  local i = #retained + 1
  retained[i] = { id = i, text = "cached metadata " .. i, flags = { visible = false, kind = "message" } }
end
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, buf)
vim.bo[buf].filetype = "lazyagent_acp"
local lines = {}
for i = 1, rows do
  lines[i] = "A documentation line with **bold text** and a [link](/tmp/README.md)."
end
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
local parser = assert(vim.treesitter.get_parser(buf, "markdown"))
require("lazyagent.acp.injections").guard(parser)
parser:parse(true)
collectgarbage("collect"); collectgarbage("collect")
if mode == "bounded" then require("lazyagent.acp.parser_gc").attach(parser, buf) end
local report = { mode = mode, rows = rows, loops = loops, retained_objects = #retained,
  source_bytes = vim.api.nvim_buf_get_offset(buf, rows), samples = {},
  gc = { steps = 0, total_ms = 0, max_step_ms = 0, slices = 0, max_slice_ms = 0 } }
local native
if jit and jit.os == "Linux" then
  local ffi = require("ffi")
  pcall(ffi.cdef, [[
    struct mallinfo2 { size_t arena; size_t ordblks; size_t smblks; size_t hblks;
      size_t hblkhd; size_t usmblks; size_t fsmblks; size_t uordblks;
      size_t fordblks; size_t keepcost; };
    struct mallinfo2 mallinfo2(void);
  ]])
  local ok = pcall(function() return ffi.C.mallinfo2() end)
  if ok then native = function()
    local info = ffi.C.mallinfo2()
    return { used = tonumber(info.uordblks), free = tonumber(info.fordblks), arena = tonumber(info.arena) }
  end end
end
local function sample(phase)
  report.samples[#report.samples + 1] = { phase = phase, lua_bytes = collectgarbage("count") * 1024,
    rss_bytes = vim.uv.resident_set_memory(), native = native and native() or nil }
end
local gc, schedule = collectgarbage, vim.schedule
vim.schedule = function(fn)
  if debug.getinfo(fn, "S").source:find("/acp/parser_gc.lua", 1, true) then
    return schedule(function()
      local started = vim.uv.hrtime()
      fn()
      report.gc.slices = report.gc.slices + 1
      report.gc.max_slice_ms = math.max(report.gc.max_slice_ms, (vim.uv.hrtime() - started) / 1e6)
    end)
  end
  return schedule(fn)
end
_G.collectgarbage = function(kind, ...)
  local started = vim.uv.hrtime()
  local result = gc(kind, ...)
  if kind == "step" then
    local ms = (vim.uv.hrtime() - started) / 1e6
    report.gc.steps = report.gc.steps + 1
    report.gc.total_ms = report.gc.total_ms + ms
    report.gc.max_step_ms = math.max(report.gc.max_step_ms, ms)
  end
  return result
end
sample("baseline")
local started = vim.uv.hrtime()
local ok, err = xpcall(function()
  for i = 1, loops do
    vim.api.nvim_buf_set_lines(buf, -2, -1, false, { "streaming reply " .. i })
    local done, parse_error = false
    parser:parse({ rows - 60, rows }, function(err)
      parse_error, done = err, true
    end)
    assert(vim.wait(5000, function() return done end, 1), "native async parse completes")
    assert(not parse_error, parse_error)
    -- Drain the actual deferred GC request, without a redraw or forced GC.
    vim.wait(1, function() return false end)
    if i % 5 == 0 then sample(i) end
  end
end, debug.traceback)
_G.collectgarbage, vim.schedule = gc, schedule
assert(ok, err)
report.elapsed_ms = (vim.uv.hrtime() - started) / 1e6
collectgarbage("collect"); collectgarbage("collect")
sample("after_gc")
assert(#retained == report.retained_objects, "simulated long-lived metadata remains reachable")
vim.fn.writefile({ vim.json.encode(report) }, assert(vim.env.LAZYAGENT_BENCH_OUT))
vim.api.nvim_buf_delete(buf, { force = true })

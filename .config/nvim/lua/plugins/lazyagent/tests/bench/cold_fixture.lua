local root = assert(vim.env.LAZYAGENT_BENCH_ROOT, "LAZYAGENT_BENCH_ROOT is required")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
collectgarbage("collect")
local before = collectgarbage("count")
local started = (vim.uv or vim.loop).hrtime()
local Cockpit = require("lazyagent.acp.cockpit")
local Client = require("lazyagent.acp.client")
Client.new({ command = { vim.v.progpath, "--version" } })
Cockpit.render({ {
  thread_id = "cold", provider_id = "fixture", title = "cold command", cwd = root, status = "closed",
} }, {}, { width = 100 })
local elapsed = ((vim.uv or vim.loop).hrtime() - started) / 1000000
collectgarbage("collect")
io.stdout:write(vim.json.encode({ lazyagent_ms = elapsed, lua_kb_before = before, lua_kb_after_gc = collectgarbage("count") }))
io.stdout:flush()

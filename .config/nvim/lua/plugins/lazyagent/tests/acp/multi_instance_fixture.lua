local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
vim.opt.runtimepath:prepend(root)
package.path = table.concat({ root .. "/?.lua", root .. "/?/init.lua", package.path }, ";")

local ok, err = xpcall(function()
  local ThreadStore = require("lazyagent.acp.thread_store")
  local store = ThreadStore.new({
    dir = assert(vim.env.LAZYAGENT_MULTI_INSTANCE_DIR),
    lock_timeout_ms = 5000,
  })
  assert(store:create({
    thread_id = assert(vim.env.LAZYAGENT_MULTI_INSTANCE_THREAD),
    provider_id = assert(vim.env.LAZYAGENT_MULTI_INSTANCE_PROVIDER),
    process_id = vim.fn.getpid(),
  }))
end, debug.traceback)

if not ok then
  io.stderr:write(tostring(err) .. "\n")
  vim.cmd("cquit 1")
else
  vim.cmd("qa!")
end

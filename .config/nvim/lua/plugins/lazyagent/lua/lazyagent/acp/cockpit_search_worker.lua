local source = debug.getinfo(1, "S").source:gsub("^@", "")
vim.opt.runtimepath:prepend(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))))
local ok, value = pcall(function()
  local request = vim.json.decode(io.read("*a"))
  local Search = require("lazyagent.acp.cockpit_search")
  local result, err
  if request.action == "search" then result, err = Search.scan(request.threads, request.query, request.opts)
  elseif request.action == "open" then result, err = Search.read_hit(request.hit, request.query)
  else error("Unknown transcript search action") end
  return result or { error = tostring(err) }
end)
io.stdout:write(vim.json.encode(ok and value or { error = tostring(value) }))

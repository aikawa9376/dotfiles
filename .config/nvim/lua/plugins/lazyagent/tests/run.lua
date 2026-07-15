local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(source))

vim.opt.runtimepath:prepend(root)
package.path = table.concat({
  root .. "/?.lua",
  root .. "/?/init.lua",
  package.path,
}, ";")

local suites = {
  "tests.acp.client_contract",
  "tests.acp.cancellation_spec",
  "tests.acp.path_guard_spec",
  "tests.acp.file_writer_spec",
  "tests.acp.terminals_spec",
}

local failures = {}
for _, name in ipairs(suites) do
  local ok, suite_or_error = pcall(require, name)
  if not ok then
    failures[#failures + 1] = name .. ": " .. tostring(suite_or_error)
  else
    local suite_ok, suite_error = xpcall(suite_or_error.run, debug.traceback)
    if not suite_ok then
      failures[#failures + 1] = name .. ":\n" .. tostring(suite_error)
    else
      print("ok - " .. name)
    end
  end
end

if #failures > 0 then
  error(table.concat(failures, "\n\n"), 0)
end

print(string.format("all %d suite(s) passed", #suites))

local M = {}

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local Follow = require("lazyagent.acp.follow")
  local root = vim.fn.tempname() .. "-follow"
  vim.fn.mkdir(root, "p")
  local path = root .. "/target.lua"
  vim.fn.writefile({ "one", "two", "three" }, path)
  local session = { root_dir = root, cwd = root }

  local target = assert(Follow.resolve(session, {
    paths = { "fallback.lua" },
    locations = { { uri = vim.uri_from_fname(path), range = { start = { line = 1 } } } },
  }))
  assert_equal(target.path, path, "tool location path")
  assert_equal(target.line, 2, "zero-based tool location line")

  local path_target = assert(Follow.resolve(session, { path = "target.lua" }))
  assert_equal(path_target.path, path, "changed file fallback")
  assert_equal(Follow.resolve(session, { path = "missing.lua" }), nil, "missing target ignored")
  assert_equal(Follow.resolve(session, { path = vim.v.progpath }), nil, "out-of-scope target ignored")
  vim.fn.delete(root, "rf")
end

return M

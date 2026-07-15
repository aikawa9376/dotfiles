local M = {}

local function assert_equal(expected, actual, label)
  if not vim.deep_equal(expected, actual) then
    error(string.format("%s: expected %s, got %s", label, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local function assert_truthy(value, label)
  if not value then
    error(label or "expected truthy value", 2)
  end
end

local function assert_denied(value, err, label)
  assert_equal(nil, value, label .. " value")
  assert_truthy(type(err) == "string" and err:match("ACP filesystem roots"), label .. " error")
end

function M.run()
  local PathGuard = require("lazyagent.acp.backend.path_guard")
  local uv = vim.uv or vim.loop
  local base = vim.fn.tempname()
  local root = base .. "/root"
  local extra = base .. "/extra"
  local outside = base .. "/outside"
  vim.fn.mkdir(root, "p")
  vim.fn.mkdir(extra, "p")
  vim.fn.mkdir(outside, "p")
  vim.fn.writefile({ "inside" }, root .. "/inside.txt")
  vim.fn.writefile({ "extra" }, extra .. "/extra.txt")
  vim.fn.writefile({ "outside" }, outside .. "/outside.txt")

  local ok_file_link, file_link_err = uv.fs_symlink(outside .. "/outside.txt", root .. "/file-link")
  assert_truthy(ok_file_link, "create file symlink: " .. tostring(file_link_err))
  local ok_dir_link, dir_link_err = uv.fs_symlink(outside, root .. "/dir-link", { dir = true })
  assert_truthy(ok_dir_link, "create directory symlink: " .. tostring(dir_link_err))

  local guard, guard_err = PathGuard.new({
    cwd = root,
    additional_directories = { "../extra" },
  })
  assert_truthy(guard, "create path guard: " .. tostring(guard_err))

  assert_equal(uv.fs_realpath(root .. "/inside.txt"), guard:resolve("inside.txt"), "relative read")
  assert_equal(uv.fs_realpath(extra .. "/extra.txt"), guard:resolve(extra .. "/extra.txt"), "additional root")
  assert_equal(root .. "/new/child.txt", guard:resolve("new/child.txt", { allow_missing = true }), "missing write")

  local value, err = guard:resolve("../outside/outside.txt")
  assert_denied(value, err, "parent traversal")
  value, err = guard:resolve(root .. "-sibling/file.txt", { allow_missing = true })
  assert_denied(value, err, "root prefix sibling")
  value, err = guard:resolve("file-link")
  assert_denied(value, err, "file symlink escape")
  value, err = guard:resolve("dir-link/new.txt", { allow_missing = true })
  assert_denied(value, err, "directory symlink escape")

  vim.fn.delete(base, "rf")
end

return M

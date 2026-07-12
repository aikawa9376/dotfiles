vim.opt.runtimepath:append(vim.fn.getcwd())

local conflict = require("lazyconflict")

local function assert_eq(expected, actual, message)
  if expected ~= actual then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function set_lines(lines)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local complete = set_lines({
  "<<<<<<<< ours",
  "current",
  "========",
  "incoming",
  ">>>>>>>> theirs",
  "<<<<<<< incomplete",
  "not a complete conflict",
})
local regions = conflict.build_regions(complete)
assert_eq(1, #regions, "only complete blocks are parsed")
assert_eq(1, regions[1].start, "custom marker width start")
assert_eq(5, regions[1].finish, "custom marker width end")

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local function git(...)
  local cmd = { "git", "-C", root }
  vim.list_extend(cmd, { ... })
  local result = vim.system(cmd, { text = true }):wait()
  if result.code ~= 0 then
    error(result.stderr)
  end
end
local function write(path, lines)
  vim.fn.writefile(lines, root .. "/" .. path)
end

git("init", "-q")
git("config", "user.email", "lazyconflict@example.invalid")
git("config", "user.name", "lazyconflict test")
write("conflicted.txt", { "base" })
git("add", "conflicted.txt")
git("commit", "-qm", "base")
git("checkout", "-qb", "other")
write("conflicted.txt", { "other" })
git("commit", "-qam", "other")
git("checkout", "-q", "master")
write("conflicted.txt", { "ours" })
git("commit", "-qam", "ours")
local merge = vim.system({ "git", "-C", root, "merge", "other" }, { text = true }):wait()
assert_eq(1, merge.code, "fixture merge conflicts")

write("example.txt", { "<<<<<<< docs", "sample", "=======", "sample", ">>>>>>> docs" })
vim.cmd.edit(vim.fn.fnameescape(root .. "/example.txt"))

conflict.setup({
  detection = { auto = false, cwd = root, mode = "git" },
  statusline = { formatter = tostring },
  disable_diagnostics = false,
  keymaps = { enabled = false },
})
assert(vim.wait(3000, function()
  return conflict.statusline() == "1"
end), "git conflict detection timed out")
assert_eq("1", conflict.statusline(), "clean marker examples are not counted in git mode")

vim.cmd.edit(vim.fn.fnameescape(root .. "/conflicted.txt"))
local conflicted_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(conflicted_buf, 0, -1, false, { "resolved but unsaved" })
conflict.apply_buffer(conflicted_buf)
assert_eq("0", conflict.statusline(), "unsaved conflict resolution updates the count")

local stale_output = table.concat({
  root .. "/stale.txt:1:<<<<<<< ours",
  root .. "/stale.txt:2:=======",
  root .. "/stale.txt:3:>>>>>>> theirs",
}, "\\n")
conflict.check({ command = { "sh", "-c", "sleep 0.2; printf '%s\\n' \"$1\"", "sh", stale_output }, cwd = root })
conflict.check({ command = { "sh", "-c", "true" }, cwd = root })
assert(vim.wait(1000, function()
  return conflict.statusline() == "0"
end), "newer conflict check timed out")
vim.wait(300)
assert_eq("0", conflict.statusline(), "stale asynchronous results are ignored")

conflict.disable()
assert_eq("0", conflict.statusline(), "disable clears the count")
vim.fn.delete(root, "rf")
print("lazyconflict tests: ok")

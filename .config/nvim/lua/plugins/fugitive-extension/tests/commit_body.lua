-- Run from the plugin root: nvim --headless --clean -u NONE -l tests/commit_body.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. package.path
local body = require('features.commit_body')
local ns = vim.api.nvim_create_namespace('fugitive_commit_body')
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid' }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end
git({ 'init', '-q' })
git({ 'commit', '--allow-empty', '-qm', 'Subject only' })
local empty = git({ 'rev-parse', 'HEAD' })
git({ 'commit', '--allow-empty', '-qm', 'Subject with body', '-m', '本文です。\n\nSecond paragraph\n  indented detail' })
local full = git({ 'rev-parse', 'HEAD' })
local function buffer(ft, lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = ft
  vim.b[b].fugitive_work_tree = root
  vim.b[b].git_dir = root .. '/.git'
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  body.attach(b)
  return b
end
local system, calls = vim.system, 0
vim.system = function(argv, opts, callback)
  assert(type(callback) == 'function', 'commit body query blocked on a synchronous process')
  calls = calls + 1
  return system(argv, opts, callback)
end
local lines = { full:sub(1, 7) .. ' 2026-09-13 12:34 Subject with body', empty:sub(1, 7) .. ' 2026-09-13 12:33 Subject only' }
local b = buffer('fugitivestatus', lines)
vim.api.nvim_set_current_buf(b)
body.refresh(b)
body.refresh(b)
assert(calls == 1, 'parallel refreshes duplicated the batch query')
-- Opening before the lookup finishes shows loading, then the multiline body.
vim.fn.maparg('gk', 'n', false, true).callback()
local popup = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_get_current_line():find('Loading'))
assert(vim.wait(2000, function()
  return vim.api.nvim_buf_get_lines(popup, 0, 1, false)[1] == '本文です。'
end, 10))
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(popup, 0, -1, false), { '本文です。', '', 'Second paragraph', '  indented detail' }))
vim.fn.maparg('q', 'n', false, true).callback()
local marks = vim.api.nvim_buf_get_extmarks(b, ns, 0, -1, { details = true })
assert(#marks == 1 and marks[1][2] == 0 and marks[1][3] == #lines[1])
assert(marks[1][4].virt_text[1][1] == ' 󰍡')
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(b, 0, -1, false), lines), 'icons changed buffer text')
body.refresh(b)
assert(calls == 1, 'cached refresh repeated Git work')
vim.api.nvim_win_set_cursor(0, { 2, 0 })
body.show(b)
assert(vim.api.nvim_get_current_line() == 'No commit message body.')
vim.fn.maparg('q', 'n', false, true).callback()
local log_line = full:sub(1, 7) .. '\t2026-09-13\tSubject with body\tAuthor\t (HEAD)\tstat'
local log = buffer('fugitivelog', { log_line })
body.refresh(log)
assert(vim.wait(2000, function() return #vim.api.nvim_buf_get_extmarks(log, ns, 0, -1, {}) == 1 end, 10))
marks = vim.api.nvim_buf_get_extmarks(log, ns, 0, -1, {})
assert(marks[1][3] == #log_line:match('^(%x+\t[^\t]*\t[^\t]*\t[^\t]*)'), 'log icon was not after author')
vim.api.nvim_buf_delete(b, { force = true })
vim.api.nvim_buf_delete(log, { force = true })
-- Obsolete results, failure, and buffer reuse cannot annotate a different commit.
local requests, killed = {}, 0
vim.system = function(_, _, callback)
  requests[#requests + 1] = callback
  return { kill = function() killed = killed + 1 end }
end
b = buffer('fugitivestatus', { full:sub(1, 7) .. ' old' })
body.refresh(b)
vim.api.nvim_buf_set_lines(b, 0, -1, false, { empty:sub(1, 7) .. ' new' })
body.refresh(b)
requests[1]({ code = 0, stdout = full .. '\0old body\0\n' })
assert(vim.wait(1000, function() return #requests == 2 end, 10))
assert(#vim.api.nvim_buf_get_extmarks(b, ns, 0, -1, {}) == 0, 'old body annotated the replacement row')
requests[2]({ code = 1, stderr = 'fixture failure' })
vim.wait(10, function() return false end)
body.refresh(b)
assert(#requests == 3, 'failed lookup could not be retried')
vim.api.nvim_buf_delete(b, { force = true })
assert(killed == 1, 'teardown left body lookup running')
requests[3]({ code = 0, stdout = empty .. '\0late body\0\n' })
vim.wait(10, function() return false end)
assert(not pcall(vim.api.nvim_get_autocmds, { group = 'FugitiveCommitBody' .. b }), 'teardown leaked handlers')
vim.system = system
-- Exercise the actual list renderers, including their later enrichment refresh.
git({ 'remote', 'add', 'origin', root })
local executable = vim.fn.executable
vim.fn.executable = function(name) return name == 'gh' and 0 or executable(name) end
local group = vim.api.nvim_create_augroup('CommitBodyIntegration', { clear = true })
require('features.commands').setup(group)
require('features.status').setup(group)
require('features.log').setup(group)
local status_buf = require('features.status').open({ work_tree = root, split = true })
assert(vim.wait(5000, function()
  local contents = table.concat(vim.api.nvim_buf_get_lines(status_buf, 0, -1, false), '\n')
  return not contents:find('Loading') and #vim.api.nvim_buf_get_extmarks(status_buf, ns, 0, -1, {}) == 1
end, 20), 'status enrichment did not retain the body icon')
assert(vim.fn.maparg('gk', 'n', false, true).desc == 'Show commit message body')
vim.cmd('FugitiveLog')
local log_buf = vim.api.nvim_get_current_buf()
assert(vim.bo[log_buf].filetype == 'fugitivelog')
assert(vim.wait(5000, function()
  return #vim.api.nvim_buf_get_extmarks(log_buf, ns, 0, -1, {}) == 1
end, 20), 'log renderer did not request body icons')
vim.fn.maparg('gk', 'n', false, true).callback()
assert(vim.api.nvim_get_current_line() == '本文です。')
vim.fn.maparg('q', 'n', false, true).callback()
vim.api.nvim_buf_delete(log_buf, { force = true })
vim.api.nvim_buf_delete(status_buf, { force = true })
vim.fn.executable = executable
vim.fn.delete(root, 'rf')
print('PASS: async body batch, icon positions, loading/cached/empty floats, stale results, errors, teardown')

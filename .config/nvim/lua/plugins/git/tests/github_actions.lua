local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local actions = require('git.features.github_actions')
local ctx = { root = f.root, url = f.pr.url }
local captured_input, input_opts
vim.ui.input = function(opts, cb) captured_input, input_opts = cb, opts end
local view = require('git.features.pr')
local opened
local original_open = view.open
view.open = function(opts) opened = opts end
actions.create_quick(ctx)
assert(vim.wait(5000, function() return captured_input ~= nil end, 10))
assert(input_opts.default == 'topic', 'Default PR title did not use the latest commit subject')
-- Input may switch buffers/cwd; every subprocess still belongs to the origin.
vim.cmd('cd /tmp')
captured_input('Title $(literal) `ticks`')
assert(vim.wait(5000, function() return opened ~= nil end, 10), table.concat(f.notifications, '\n'))
local create
for _, call in ipairs(f.calls) do if call.argv[2] == 'pr' and call.argv[3] == 'create' then create = call end end
assert(create and create.opts.cwd == f.root)
assert(vim.tbl_contains(create.argv, '--fill') and vim.tbl_contains(create.argv, '--head') and vim.tbl_contains(create.argv, 'topic'))
assert(vim.tbl_contains(create.argv, 'Title $(literal) `ticks`'))
assert(create.opts.env.GH_PROMPT_DISABLED == '1')
assert(f.git({ 'rev-parse', 'HEAD' }) == f.head and vim.fn.filereadable(f.root .. '/dirty.txt') == 1)
view.open = original_open
local status_open = require('git.features.status').open
local worktree_opened
require('git.features.status').open = function(opts) worktree_opened = opts.work_tree end
actions.worktree(ctx)
local input_before = captured_input
assert(vim.wait(5000, function() return captured_input ~= input_before end, 10), 'No worktree path input')
local path = f.root .. '-review space'
captured_input(path)
assert(vim.wait(5000, function() return worktree_opened ~= nil end, 10), table.concat(f.notifications, '\n'))
assert(worktree_opened == path)
assert(f.git({ 'rev-parse', 'HEAD' }, path) == f.head)
assert(f.git({ 'branch', '--show-current' }, path) == 'pr-7')
assert(vim.fn.getcwd() == path and f.git({ 'branch', '--show-current' }) == 'topic', 'Worktree checkout switched source branch')
assert(f.git({ 'status', '--porcelain' }):find('dirty.txt', 1, true))
local associated
actions.run({ root = path }, require('git.features.github').pr, function(pr, resolved)
  associated = resolved
end)
assert(vim.wait(5000, function() return associated ~= nil end, 10))
assert(associated.number == 7 and associated.host == 'ghe.example.test', 'PR worktree lost its GitHub association')
-- Existing worktrees/branches must not be reset or overwritten.
local prior = #f.notifications
actions.worktree(ctx)
input_before = captured_input
assert(vim.wait(5000, function() return captured_input ~= input_before end, 10))
captured_input(path)
assert(vim.wait(5000, function() return #f.notifications > prior end, 10))
assert(f.notifications[#f.notifications]:find('already exists', 1, true))
require('git.features.status').open = status_open
local checks = require('git.features.github_checks')
local browser
vim.ui.open = function(url) browser = url end
checks.checks(ctx)
assert(vim.wait(5000, function() return vim.api.nvim_get_current_line():find('CI checks', 1, true) ~= nil end, 10))
vim.api.nvim_win_set_cursor(0, { 4, 0 }); vim.fn.maparg('gx', 'n', false, true).callback()
assert(browser:find('/job/12', 1, true))
checks.runs(ctx)
assert(vim.wait(5000, function() return vim.api.nvim_get_current_line() == 'GitHub Actions' end, 10))
vim.api.nvim_win_set_cursor(0, { 4, 0 }); vim.fn.maparg('gx', 'n', false, true).callback()
assert(browser == 'https://ghe.example.test/org/repo/actions/runs/11')
-- The menu exposes a reachable quick action and both kinds of CI entry.
local ui = actions.open(ctx)
for _, key in ipairs({ 'C', 'k', 'a', 'w', 'p', 'r', 'm', 'd' }) do
  assert(vim.api.nvim_buf_call(ui.bufnr, function() return vim.fn.maparg(key, 'n', false, true).callback end))
end
ui.close()
local octo_calls = {}
vim.api.nvim_create_user_command('Octo', function(args)
  octo_calls[#octo_calls + 1] = { args = args.args, cwd = vim.fn.getcwd() }
end, { nargs = '*' })
-- The actual default-PR menu entry asks only for a title, without opening Octo.
ui = actions.open(ctx)
local menu_lines = vim.api.nvim_buf_get_lines(ui.bufnr, 0, -1, false)
local default_row, octo_row
for i, line in ipairs(menu_lines) do
  if line:find('Create default PR', 1, true) then default_row = i end
  if line:find('Create PR (Octo editor)', 1, true) then octo_row = i end
end
assert(default_row and octo_row and default_row < octo_row)
input_before = captured_input
local before_default = #f.calls
vim.api.nvim_buf_call(ui.bufnr, function() vim.fn.maparg('C', 'n', false, true).callback() end)
assert(vim.wait(5000, function() return captured_input ~= input_before end, 10))
assert(input_opts.default == 'topic' and #octo_calls == 0)
captured_input(nil)
assert(#f.calls == before_default, 'Cancelled default PR reached GitHub')
package.loaded['octo.utils'] = { get_current_buffer = function()
  return { node = {}, ready = true, isPullRequest = function() return true end }
end }
actions.octo(ctx, true)
assert(vim.wait(5000, function() return #octo_calls >= 2 end, 10))
assert(octo_calls[1].args == f.pr.url and octo_calls[2].args == 'review start', 'Octo review selected another PR')
ui = actions.open(ctx)
vim.api.nvim_buf_call(ui.bufnr, function() vim.fn.maparg('c', 'n', false, true).callback() end)
assert(octo_calls[#octo_calls].args == 'pr create' and octo_calls[#octo_calls].cwd == f.root)
vim.ui.select = function(items, _, cb) cb(items[1]) end
local merged
actions.merge(ctx)
assert(vim.wait(5000, function()
  for _, call in ipairs(f.calls) do if call.argv[2] == 'pr' and call.argv[3] == 'merge' then merged = call; return true end end
end, 10))
assert(vim.tbl_contains(merged.argv, '--squash') and vim.tbl_contains(merged.argv, '--match-head-commit') and vim.tbl_contains(merged.argv, f.head))
assert(vim.wait(5000, function() return not require('git.features.async').busy(f.root) end, 10))
vim.cmd('tcd /tmp')
f.git({ 'worktree', 'remove', '--', path })
f.cleanup()
print('PASS: quick PR defaults and literal title, captured cwd, real isolated worktree, collision protection, CI/Actions gx, reachable menu keys')

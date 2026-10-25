local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
local actions, github = require('git.features.github_actions'), require('git.features.github')
local related = require('git.features.github_related')
local utils = require('git.utils')
vim.o.columns, vim.o.lines = 160, 60
f.delay = 30
local function pr(number, state, base)
  local item = vim.deepcopy(f.pr)
  item.number, item.url, item.state = number, f.pr.url:gsub('/7$', '/' .. number), state or 'OPEN'
  item.title, item.baseRefName = 'Related PR ' .. number, base or 'main'
  return item
end
local function source(ft, lines)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft
  utils.set_buf_work_tree(buf, f.root)
  return buf
end
local function text(ui) return table.concat(vim.api.nvim_buf_get_lines(ui.bufnr, 0, -1, false), '\n') end
local function wait_for(ui, value)
  assert(vim.wait(5000, function() return text(ui):find(value, 1, true) ~= nil end, 10), text(ui))
end
local function key(ui, value)
  vim.api.nvim_set_current_win(ui.winid)
  local mapping = vim.fn.maparg(value, 'n', false, true)
  assert(mapping.callback, 'Missing key ' .. value)
  mapping.callback()
end
local function last_call(command, subcommand)
  for i = #f.calls, 1, -1 do
    if f.calls[i].argv[2] == command and (not subcommand or f.calls[i].argv[3] == subcommand) then return f.calls[i] end
  end
end
local function arg(call, flag)
  for i, value in ipairs(call.argv) do if value == flag then return call.argv[i + 1] end end
end
local buf = source('gitbranch', { 'main', 'topic' })
vim.b[buf].branch_map, vim.b[buf].branch_kinds = { 'main', 'topic' }, { 'local_', 'local_' }
f.git({ 'config', 'branch.topic.pullRequestUrl', 'https://ghe.example.test/unrelated/repo/pull/999' })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
local captured = actions.context(buf)
assert(captured.branch == 'main' and not captured.commit)
f.prs = { pr(8), pr(7, 'OPEN', 'release'), pr(6, 'MERGED') }
local ui = actions.open(captured)
assert(text(ui):find('PR: Loading', 1, true) and text(ui):find('Ref: main', 1, true))
-- Async publication keeps the selected action, even as the header grows.
for row, line in ipairs(vim.api.nvim_buf_get_lines(ui.bufnr, 0, -1, false)) do
  if line:find('Create default PR', 1, true) then vim.api.nvim_win_set_cursor(ui.winid, { row, 0 }) end
end
local source_win = vim.fn.win_findbuf(buf)[1]
vim.api.nvim_win_set_cursor(source_win, { 2, 0 })
vim.cmd('cd /tmp')
wait_for(ui, 'Open PR… (3)')
assert(vim.api.nvim_get_current_line():find('Create default PR', 1, true), 'Header update moved to another action')
local call = last_call('pr', 'list')
assert(arg(call, '--head') == 'main' and arg(call, '--state') == 'all' and call.opts.cwd == f.root)
assert(not last_call('pr', 'view'), 'Cursor lookup inherited the checked-out branch association')
assert(text(ui):find('release', 1, true) and text(ui):find('[merged]', 1, true))
local selected, selection, opened
vim.ui.select = function(items, opts, callback) selected, selection = items, callback; assert(opts.format_item(items[2]):find('release', 1, true)) end
local view = require('git.features.pr')
local original_open = view.open
view.open = function(opts) opened = opts end
key(ui, 'p')
assert(#selected == 3 and not opened)
selection(selected[2])
assert(opened.url == f.pr.url and opened.root == f.root, 'Picker did not retain the chosen PR identity')
-- State-specific mutations select eligible PRs only.
local merged
local original_merge = actions.merge
actions.merge = function(opts) merged = opts end
vim.api.nvim_set_current_win(source_win)
f.prs = { pr(8), pr(6, 'MERGED') }
related.invalidate(f.root)
ui = actions.open(captured); wait_for(ui, 'Open PR… (2)'); key(ui, 'm')
assert(merged.url:find('/8$', 1) and merged.root == f.root)
actions.merge = original_merge
-- A single match opens directly, and the browser has its own explicit action.
f.prs = { pr(9, 'CLOSED') }
related.invalidate(f.root)
local browser
vim.ui.open = function(url) browser = url end
ui = actions.open(captured); wait_for(ui, '#9 [closed]')
local before = #f.notifications
key(ui, 'm')
assert(vim.api.nvim_buf_is_valid(ui.bufnr) and #f.notifications == before + 1, 'Closed PR merge was enabled')
assert(text(ui):find('Reopen PR', 1, true))
key(ui, 'b'); assert(browser:find('/9$'))
ui = actions.open(captured); wait_for(ui, '#9 [closed]'); key(ui, 'p')
assert(opened.url:find('/9$'))
-- Fork branches sharing a name are filtered by the selected remote repository.
f.git({ 'remote', 'set-url', 'origin', 'git@ghe.example.test:fork/repo.git' })
vim.b[buf].branch_map, vim.b[buf].branch_kinds = { 'origin/feature/nested', 'topic' }, { 'remote', 'local_' }
vim.api.nvim_win_set_cursor(0, { 1, 0 })
local own, other = pr(10), pr(11)
own.headRepositoryOwner, own.headRepository = { login = 'fork' }, { name = 'repo' }
other.headRepositoryOwner, other.headRepository = { login = 'other' }, { name = 'repo' }
f.prs = { own, other }
ui = actions.open(actions.context(buf)); wait_for(ui, '#10 [open]')
assert(not text(ui):find('#11', 1, true) and arg(last_call('pr', 'list'), '--head') == 'feature/nested')
ui.close()
-- Log cursor commits use the associated-PR API and never fall back to HEAD.
local log = source('gitlog', { f.base:sub(1, 9) .. '\told commit', f.head:sub(1, 9) .. '\tnew commit' })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
local endpoint
f.api_response = function(path)
  if path:find('/commits/', 1, true) then
    endpoint = path
    return { data = { { number = 12, html_url = f.pr.url:gsub('/7$', '/12'), title = 'Historical PR',
      state = 'closed', merged_at = '2026-10-01', head = { ref = 'old' }, base = { ref = 'main' } } } }
  end
end
ui = actions.open(actions.context(log)); wait_for(ui, '#12 [merged]')
assert(endpoint == 'repos/org/repo/commits/' .. f.base .. '/pulls')
assert(text(ui):find('old → main', 1, true))
ui.close()
local commit = source('gitcommitview', { 'Commit header' })
vim.b[commit].git_commit = f.base
assert(actions.context(commit).commit == f.base)
-- No result and read failures disable PR actions while leaving repository actions reachable.
f.prs = {}
ui = actions.open(captured)
key(ui, 'R'); wait_for(ui, 'No related pull requests')
opened = nil; key(ui, 'p'); assert(not opened and vim.api.nvim_buf_is_valid(ui.bufnr)); ui.close()
local json = github.json
github.json = function(ctx, args, opts)
  if args[1] == 'pr' and args[2] == 'list' then error('lookup failed', 0) end
  return json(ctx, args, opts)
end
ui = actions.open(captured); key(ui, 'R'); wait_for(ui, 'Could not load — lookup failed')
key(ui, 'p'); assert(not opened); ui.close(); github.json = json
-- An empty Branch/Log row has no target, and must not select the current branch.
vim.api.nvim_set_current_buf(log)
vim.api.nvim_buf_set_lines(log, 0, -1, false, { '' })
local empty = actions.context(log)
assert(empty.no_target)
local calls_before = #f.calls
ui = actions.open(empty); wait_for(ui, 'No related pull requests'); ui.close()
for i = calls_before + 1, #f.calls do
  assert(f.calls[i].argv[2] ~= 'pr', 'An empty cursor row fell back to the current branch PR')
end
-- Stored worktree associations apply to that selected local branch only.
ui = actions.open({ root = f.root, branch = 'topic', branch_kind = 'local_' })
wait_for(ui, '#7 [open]')
assert(arg(last_call('pr', 'view'), '--repo') == 'ghe.example.test/unrelated/repo')
ui.close()
-- Closing a loading view cancels its work; late results cannot replace a newer menu.
f.delay = 80
related.invalidate(f.root)
ui = actions.open(captured); local old = ui.bufnr; ui.close()
f.prs = { pr(15) }
local newer = actions.open(captured); wait_for(newer, '#15 [open]')
assert(not vim.api.nvim_buf_is_valid(old) and not text(newer):find('Could not load', 1, true))
newer.close()
-- Space-Space N captures the source cursor when the root menu opens.
vim.api.nvim_set_current_buf(buf)
vim.b[buf].branch_map, vim.b[buf].branch_kinds = { 'main', 'topic' }, { 'local_', 'local_' }
vim.api.nvim_win_set_cursor(0, { 1, 0 })
local root = require('git.features.magit_actions').open(buf)
source_win = vim.fn.win_findbuf(buf)[1]
vim.api.nvim_win_set_cursor(source_win, { 2, 0 })
key(root, 'N')
local submenu = { bufnr = vim.api.nvim_get_current_buf(), winid = vim.api.nvim_get_current_win() }
wait_for(submenu, '#15 [open]')
assert(arg(last_call('pr', 'list'), '--head') == 'main')
key(submenu, 'q')
view.open = original_open
f.cleanup()
print('PASS: cursor PR discovery, async header, exact PR selection, state filtering, fork identity, cancellation and submenu capture')

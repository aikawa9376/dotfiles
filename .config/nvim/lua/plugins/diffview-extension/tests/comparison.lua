local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.rtp:prepend(plugin)
local api = vim.api
local info, comparison = require('diffview_extension.commit_info'), require('diffview_extension.comparison')
local root = vim.fn.tempname() .. ' repo'; vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false' }
  vim.list_extend(argv, args); local result = vim.system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr); return vim.trim(result.stdout)
end
git({ 'init', '-qb', 'main' })
local commits = {}
for i, subject in ipairs({ 'base', 'second', '三番目 100% %{literal}' }) do
  vim.fn.writefile({ tostring(i) }, root .. '/a'); git({ 'add', '.' }); git({ 'commit', '-qm', subject })
  commits[i] = git({ 'rev-parse', 'HEAD' })
end
local function commit(hash) return { type = 2, commit = hash } end
local tab = api.nvim_get_current_tabpage()
local function view(left, right, raw, extra)
  return vim.tbl_extend('force', { tabpage = tab, adapter = { ctx = { toplevel = root } }, left = left, right = right, rev_arg = raw }, extra or {})
end
local function load(v)
  info._refresh(v)
  assert(vim.wait(2000, function() return not info.state(tab).request end, 1))
  return info.state(tab), info.statusline()
end
local state, text = load(view(commit(commits[1]), commit(commits[3]), 'main..feature'))
assert(text:find('main..feature · 2 commits', 1, true) and text:find('三番目 100% %{literal}', 1, true))
assert(state.metadata[commits[1]].subject == 'base' and state.metadata[commits[3]].subject:find('100%', 1, true))
state, text = load(view(commit(commits[2]), commit(commits[3]), commits[3] .. '^!'))
assert(state.context.mode == 'commit' and text == state.metadata[commits[3]].short .. ' 三番目 100% %{literal}')
state = load(view(commit(commits[2]), commit(commits[3]), commits[3] .. '^..' .. commits[3]))
assert(state.context.mode == 'commit')
state, text = load(view(commit(commits[2]), commit(commits[3]), commits[2] .. '..' .. commits[3]))
assert(state.context.mode == 'commit' and text:find('三番目', 1, true))
assert(info.statusline(32):find('三番目', 1, true) and vim.fn.strdisplaywidth(info.statusline(32)) <= 32)
state, text = load(view(commit(comparison.empty_tree), commit(commits[1]), comparison.empty_tree .. '..' .. commits[1]))
assert(state.context.mode == 'commit' and text:find(' base', 1, true))
state, text = load(view(commit(comparison.empty_tree), commit(commits[1]), commits[1] .. '^!'))
assert(text:find(' base', 1, true) and state.counts.right == 1)
state, text = load(view(commit(commits[1]), commit(commits[3]), 'main...feature'))
assert(state.context.left.label == 'merge-base' and state.context.left.commit == commits[1] and text:find('main...feature', 1, true))
state, text = load(view(commit(commits[3]), commit(commits[1]), 'feature..main'))
assert(text:find('-2/+0 commits', 1, true))
git({ 'checkout', '-qb', 'side', commits[1] }); vim.fn.writefile({ 'side' }, root .. '/b')
git({ 'add', '.' }); git({ 'commit', '-qm', 'side' }); local side = git({ 'rev-parse', 'HEAD' })
state, text = load(view(commit(side), commit(commits[3]), 'side..main'))
assert(state.counts.left == 1 and state.counts.right == 2 and text:find('-1/+2 commits', 1, true))
state, text = load(view({ type = 3, stage = 0 }, { type = 1 }))
assert(text == 'index → working tree')
state, text = load(view({ type = 3, stage = 0 }, { type = 1 }, nil, {
  cur_entry = { kind = 'staged', revs = { a = commit(commits[3]), b = { type = 3, stage = 0 } } },
}))
assert(state.context.right.kind == 'index' and text:find('→ index', 1, true))
state, text = load(view({ type = 3, stage = 0 }, { type = 1 }, nil, { files = { conflicting = { true, true } } }))
assert(text:find('conflicts: 2', 1, true))
local head = commit(commits[3]); head.track_head = true
state, text = load(view(head, { type = 3, stage = 0 }))
assert(text:find('HEAD → index', 1, true))
state, text = load(view(commit(commits[1]), { type = 1 }, 'HEAD~2'))
assert(text:find('HEAD~2 → working tree', 1, true))
state, text = load(view({ type = 1 }, commit(commits[3]), 'HEAD~2..feature'))
assert(state.context.mode == 'worktree' and text:find('working tree → feature', 1, true))
state, text = load(view(commit(commits[1]), commit(commits[3]), nil, { get_file_data = function() end }))
assert(state.context.custom and text:find('Snapshot', 1, true) and text:find('2 commits', 1, true))
local historical = { panel = { cur_item = { { commit = { hash = commits[2], subject = 'second' } } } },
  cur_entry = { revs = { a = commit(commits[1]), b = commit(commits[2]) } } }
state, text = load(view(nil, nil, nil, historical))
assert(text:find('History · ' .. commits[2]:sub(1, 7), 1, true) and text:find('second', 1, true))
historical.cur_entry.revs.b = { type = 1 }
state, text = load(view(nil, nil, nil, historical))
assert(text:find('→ working tree', 1, true))
state = load(view(commit(commits[1]), commit(commits[3]), string.rep('very-long-ref-', 30) .. '..main'))
for _, width in ipairs({ 32, 48, 80 }) do
  local narrow = info.statusline(width)
  assert(vim.fn.strdisplaywidth(narrow) <= width and narrow:find('三番目', 1, true), 'Long branch ranges must keep their tip message')
  assert(narrow:find(commits[1]:sub(1, 3), 1, true) and narrow:find(commits[3]:sub(1, 3), 1, true), 'Compacted ranges must keep both endpoint hashes')
end
state = load(view(commit(commits[2]), commit(commits[3]), 'main..feature'))
assert(state.context.mode == 'range' and info.statusline(32):find('三番目', 1, true), 'Branch labels stay a range while retaining the message')
local original, callbacks = vim.system, {}
vim.system = function(_, _, callback) callbacks[#callbacks + 1] = callback; return { kill = function() end } end
local old = view(commit(commits[1]), commit(commits[2]), 'old..tip')
local newer = view(commit(commits[2]), commit(commits[3]), 'new..tip')
info._refresh(old); info._refresh(newer)
callbacks[1]({ code = 0, stdout = commits[2] .. '\0old\0Stale subject\0' .. commits[1] .. '\n' }); vim.wait(10)
assert(info.state(tab).view == newer and not info.statusline():find('Stale subject', 1, true))
-- Rendering consumes cached data only.
vim.system = function() error('Statusline launched Git') end
info.statusline(80)
vim.system = original
info._states[tab] = nil
vim.fn.delete(root, 'rf')
print('PASS: comparison endpoints, counts/divergence, root/single commits, merge-base, mutable/index/history/snapshot views, widths and stale results')

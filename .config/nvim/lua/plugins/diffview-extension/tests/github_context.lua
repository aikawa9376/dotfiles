-- Real Diffview rendering/actions, real Git revisions and mocked GitHub reads.
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.rtp:prepend(plugin)
vim.opt.rtp:prepend(vim.fs.dirname(plugin) .. '/git')
for _, name in ipairs({ 'diffview.nvim', 'plenary.nvim', 'nvim-web-devicons', 'nvim-treesitter/runtime' }) do
  vim.opt.rtp:prepend(vim.fn.stdpath('data') .. '/lazy/' .. name)
end
local api, original_system = vim.api, vim.system
local temporary = vim.fn.tempname()
vim.env.XDG_STATE_HOME, vim.env.XDG_CACHE_HOME = temporary .. '/state', temporary .. '/cache'
local root = temporary .. '/repo'; vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false' }
  vim.list_extend(argv, args); local result = original_system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr); return vim.trim(result.stdout)
end
git({ 'init', '-qb', 'feature' })
git({ 'config', 'branch.feature.pullRequestUrl', 'https://wrong.example/unrelated/repo/pull/999' })
local commits = {}
for i = 1, 4 do
  vim.fn.writefile({ 'return ' .. i }, root .. '/a.lua')
  vim.fn.writefile({ 'return ' .. i }, root .. '/b.lua')
  git({ 'add', '.' }); git({ 'commit', '-qm', 'commit ' .. i }); commits[i] = git({ 'rev-parse', 'HEAD' })
end
local calls, failed, held, callbacks = {}, false, false, {}
local function pr(number)
  return { number = number, title = number == 21 and 'a.lua is a PR title' or 'Other change',
    html_url = 'https://github.example/acme/repo/pull/' .. number, state = number == 21 and 'open' or 'closed',
    merged_at = number == 22 and '2026-10-14T00:00:00Z' or vim.NIL }
end
vim.system = function(argv, opts, callback)
  if argv[1] ~= 'gh' then return original_system(argv, opts, callback) end
  calls[#calls + 1] = { argv = argv, cwd = opts.cwd }
  assert(opts.cwd == root, 'GH used a different repository cwd')
  local data, error
  if argv[2] == 'repo' then data = { nameWithOwner = 'acme/repo', url = 'https://github.example/acme/repo', defaultBranchRef = { name = 'main' } }
  elseif argv[2] == 'pr' then
    data = { number = 23, title = 'Branch PR', url = 'https://github.example/acme/repo/pull/23', state = 'OPEN',
      headRefName = 'feature', headRefOid = commits[4], author = { login = 'alice' }, body = '' }
  else
    assert(opts.env.GH_HOST == 'github.example')
    local hash = table.concat(argv, ' '):match('commits/(%x+)/pulls')
    assert(hash, vim.inspect(argv))
    if failed then error = 'lookup rejected'
    else data = { { pr(21), pr(22), pr(21) } } end
  end
  local result = { code = error and 1 or 0, stderr = error or '', stdout = error and '' or vim.json.encode(data) }
  if held then callbacks[#callbacks + 1] = function() callback(result) end
  else vim.schedule(function() callback(result) end) end
  return { kill = function() end }
end
require('git').setup({ word_diff_style = 'github' })
local info, github = require('diffview_extension.commit_info'), require('diffview_extension.github_context')
local group = api.nvim_create_augroup('DiffviewContextTest', { clear = true })
github.setup(group); info.setup(group)
local spec = dofile(vim.fs.dirname(plugin) .. '/diffview.lua')
require('diffview').setup(spec.opts)
local lib = require('diffview.lib')
local function settled(view)
  assert(vim.wait(5000, function()
    local context, prs = info.state(view.tabpage), github._states[view.tabpage]
    local descriptor = require('diffview_extension.comparison').describe(view)
    local ready = view.files and view.files:len() == 0
    if view.cur_entry and view.cur_entry.opened then
      ready = true
      for _, win in ipairs(view.cur_layout.windows) do
        if not win.file.bufnr or not api.nvim_win_is_valid(win.id) or api.nvim_win_get_buf(win.id) ~= win.file.bufnr then ready = false end
      end
      if view.left and view.cur_entry.revs.a.commit ~= view.left.commit then ready = false end
    end
    return ready and context and context.context.key == descriptor.key and not context.request and prs and not prs.loading and view.panel.bufid
  end, 5), 'Comparison/GitHub state did not settle')
  return info.state(view.tabpage), github._states[view.tabpage]
end
local function open(args)
  local view = assert(lib.diffview_open(vim.list_extend({ '-C' .. root }, args)))
  view:open(); settled(view); return view
end
local function panel_key(view, key)
  api.nvim_set_current_win(view.panel.winid)
  local map = vim.fn.maparg(key, 'n', false, true)
  assert(map.callback, key); map.callback()
end
local view = open({ commits[1] .. '..' .. commits[4] })
local context, prs = settled(view)
assert(context.counts.right == 3 and #prs.result.items == 2 and prs.result.scanned == 3)
assert(prs.result.items[1].status == 'open' and prs.result.items[2].status == 'merged')
local function lines() return table.concat(api.nvim_buf_get_lines(view.panel.bufid, 0, -1, false), '\n') end
assert(lines():find('Comparison', 1, true) and lines():find('3 commits', 1, true) and lines():find('#21 a.lua is a PR title', 1, true))
local component = view._github_component
local first_pr = component.prs.comp.lstart + 1
assert(github.at(view, first_pr).number == 21)
local entry = view.panel:ordered_file_list()[#view.panel:ordered_file_list()]
view.panel:highlight_file(entry)
panel_key(view, 'j')
assert(api.nvim_win_get_cursor(0)[1] == first_pr, 'Native j did not reach the related PR section')
local opened, menu, old_pr, old_actions = nil, nil, package.loaded['git.features.pr'], package.loaded['git.features.github_actions']
package.loaded['git.features.pr'] = { open = function(ctx) opened = ctx end }
package.loaded['git.features.github_actions'] = { open = function(ctx) menu = ctx end }
panel_key(view, '<CR>'); assert(opened.number == 21 and opened.root == root and opened.host == 'github.example')
panel_key(view, 'gA'); assert(menu.number == 21 and menu.bufnr == view.panel.bufid)
package.loaded['git.features.pr'], package.loaded['git.features.github_actions'] = old_pr, old_actions
local count = #calls
view.panel:render(); view.panel:redraw(); vim.wait(20)
assert(#calls == count and lines():find('#21', 1, true), 'Panel redraw refetched GH or lost the PR rows')
view.panel.listing_style = 'list'; view.panel:update_components(); view.panel:render(); view.panel:redraw()
assert(lines():find('#21', 1, true) and github.at(view, view._github_component.prs.comp.lstart + 1).number == 21)
github.commit_limit = 2; panel_key(view, 'gR'); settled(view)
assert(github._states[view.tabpage].result.limited and lines():find('latest 2 only', 1, true))
failed = true; panel_key(view, 'gR'); settled(view)
assert(lines():find('Lookup incomplete', 1, true))
failed = false
github.associate(view, { root = root, url = 'https://github.example/acme/repo/pull/23' }); settled(view)
assert(github._states[view.tabpage].result.explicit and lines():find('#23 Branch PR', 1, true))
-- Updating only the left endpoint invalidates the old explicit association.
view:set_revs(commits[2] .. '..' .. commits[4])
assert(vim.wait(5000, function()
  local cached = info.state(view.tabpage)
  return cached and cached.context.left.commit == commits[2]
end, 5), 'Changing the left endpoint did not refresh comparison metadata')
settled(view)
assert(not github._states[view.tabpage].result.explicit and info.state(view.tabpage).context.left.commit == commits[2])
local tab = view.tabpage
held = true; github.refresh(view, true); view:close()
for _, callback in ipairs(callbacks) do callback() end
vim.wait(30)
assert(github._states[tab] == nil and info.state(tab) == nil, 'Closed view retained state or accepted late GH results')
held = false; callbacks = {}
-- Mutable views show index/worktree and the open branch PR, not just HEAD's subject.
view = open({})
context, prs = settled(view)
assert(context.context.right.kind == 'worktree' and info.statusline():find('index → working tree', 1, true))
assert(#prs.result.items == 3 and lines():find('#23 Branch PR', 1, true))
view:close()
view = open({ '--cached' }); context = settled(view)
assert(context.context.right.kind == 'index' and info.statusline():find('HEAD → index', 1, true)); view:close()
-- FileHistory tracks the selected commit as its cursor/entry changes.
view = assert(lib.file_history(nil, { '-C' .. root, root .. '/a.lua' })); view:open()
context = settled(view)
assert(context.context.mode == 'history' and context.context.right.commit == commits[4])
assert(info.statusline():find('History', 1, true))
api.nvim_set_current_win(view.panel.winid)
require('diffview.actions').select_next_commit()
assert(vim.wait(5000, function()
  local cached = info.state(view.tabpage)
  return cached and cached.context.right.commit == commits[3]
end, 5), 'FileHistory selection did not update statusline context')
settled(view); view:close()
local custom = require('diffview.api.views.diff.diff_view')
view = custom.CDiffView({ git_root = root, left = custom.Rev(custom.RevType.COMMIT, commits[1]),
  right = custom.Rev(custom.RevType.COMMIT, commits[4]),
  files = { working = { { path = 'a.lua', status = 'M', selected = true } }, staged = {}, conflicting = {} },
  get_file_data = function(_, _, side) return { side == 'left' and 'return 1' or 'return 4' } end })
view:open(); context = settled(view)
assert(context.context.custom and info.statusline():find('Snapshot', 1, true))
local review = { review_id = 'test-review', changeset_id = 'test-set', lineage_id = 'test-lineage', created_at = '1',
  changes = { { path = 'a.lua', after_blob = { hash = 'test-hash' } } },
  annotations = { { path = 'a.lua', summary = 'Review note', target = { side = 'after', start_line = 1, blob_hash = 'test-hash' } } } }
package.loaded['lazyagent.acp.git_review_controller'] = { list = function() return { review } end }
require('diffview_extension.review_view').bind_review(view, review)
view.panel:render(); view.panel:redraw()
local namespace = api.nvim_get_namespaces().diffview_extension_review_panel
assert(vim.wait(1000, function()
  local marks = api.nvim_buf_get_extmarks(view.panel.bufid, namespace, 0, -1, {})
  if #marks == 0 then return false end
  for _, mark in ipairs(marks) do if mark[2] >= view._github_component.comp.lstart then return false end end
  return true
end, 5), 'Review overlays did not settle on the native file rows')
for _, mark in ipairs(api.nvim_buf_get_extmarks(view.panel.bufid, namespace, 0, -1, {})) do
  assert(mark[2] < view._github_component.comp.lstart, 'PR title/provenance was decorated as a reviewed file')
end
view:close()
vim.system = original_system
vim.fn.delete(root, 'rf')
print('PASS: real Diffview context/PR components, semantic actions, native navigation, redraw/list switching, bounded lookup, explicit PR handoff, retarget/close and mutable views')

-- Real Diffview panes/Git blobs, mocked public GitHub threads; no remote writes.
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.rtp:prepend(plugin); vim.opt.rtp:prepend(vim.fs.dirname(plugin) .. '/git')
for _, name in ipairs({ 'diffview.nvim', 'plenary.nvim', 'nvim-web-devicons', 'nvim-treesitter/runtime' }) do
  vim.opt.rtp:prepend(vim.fn.stdpath('data') .. '/lazy/' .. name)
end
local api, system = vim.api, vim.system
local temporary = vim.fn.tempname()
vim.env.XDG_STATE_HOME, vim.env.XDG_CACHE_HOME = temporary .. '/state', temporary .. '/cache'
local root = temporary .. '/repo'; vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false' }
  vim.list_extend(argv, args); local result = system(argv, { text = true }):wait()
  assert(result.code == 0, result.stderr); return vim.trim(result.stdout)
end
git({ 'init', '-qb', 'feature' })
local before = { 'head', 'leftnote', 'before', 'range1', 'range2', 'tail' }
local after = { 'head', 'leftnote', 'after', 'range1', 'range2', 'tail' }
vim.fn.writefile(before, root .. '/old.lua'); vim.fn.writefile({ 'before' }, root .. '/b.lua')
git({ 'add', '.' }); git({ 'commit', '-qm', 'base' }); local base = git({ 'rev-parse', 'HEAD' })
git({ 'mv', 'old.lua', 'a.lua' }); vim.fn.writefile(after, root .. '/a.lua'); vim.fn.writefile({ 'after' }, root .. '/b.lua')
git({ 'add', '.' }); git({ 'commit', '-qm', 'head' }); local head = git({ 'rev-parse', 'HEAD' })
local calls, held, callbacks, status_failure, wrong_head, viewer_failure, missing_blobs, advanced_base = {}, false, {}, false, false, false, false, false
local function pr(number)
  return { number = number, title = 'Review ' .. number, url = 'https://github.example/acme/repo/pull/' .. number,
    html_url = 'https://github.example/acme/repo/pull/' .. number, state = 'OPEN', headRefName = 'feature',
    baseRefOid = advanced_base and head or base, headRefOid = missing_blobs and string.rep('f', 40) or head, author = { login = 'alice' }, body = '' }
end
local function comment(id, line, side, start)
  return { id = id, path = 'a.lua', line = line, start_line = start, side = side or 'RIGHT', commit_id = head,
    body = 'comment ' .. id, user = { login = 'alice' }, created_at = '2026-10-14T00:00:00Z',
    updated_at = '2026-10-14T00:00:00Z', html_url = pr(21).url .. '#discussion_r' .. id }
end
local function status(id, line, side, start, extra)
  return vim.tbl_extend('force', { id = 'thread' .. id, path = 'a.lua', line = line, startLine = start,
    diffSide = side or 'RIGHT', subjectType = 'LINE', isOutdated = false, isResolved = id == 102,
    viewerCanResolve = true, viewerCanUnresolve = true,
    comments = { nodes = { { fullDatabaseId = id, pullRequestReview = { state = id == 105 and 'PENDING' or 'COMMENTED' } } } } }, extra or {})
end
vim.system = function(argv, opts, callback)
  if argv[1] ~= 'gh' then return system(argv, opts, callback) end
  assert(opts.cwd == root, 'Repository ownership lost'); calls[#calls + 1] = argv
  local data, err
  local joined = table.concat(argv, ' ')
  if argv[2] == 'repo' then data = { nameWithOwner = 'acme/repo', url = 'https://github.example/acme/repo', defaultBranchRef = { name = 'main' } }
  elseif argv[2] == 'pr' then data = pr(tonumber(argv[4]) or tonumber(argv[3]) or 21)
  elseif joined:find('/pulls?', 1, true) then data = { { pr(21), pr(22) } }
  elseif joined:find('/comments?', 1, true) then
    if joined:find('/pulls/22/', 1, true) then data = { { comment(201, 4) } }
    else
      local reply = comment(107, 5); reply.in_reply_to_id = 101
      data = { { comment(101, 5, 'RIGHT', 4), comment(102, 2, 'LEFT'), comment(103, 5), comment(104), comment(105, 5), reply } }
    end
  elseif joined:find('graphql', 1, true) then
    if status_failure then err = 'No GraphQL access'
    else
      local vars = vim.json.decode(opts.stdin).variables
      local nodes = vars.number == 22 and { status(201, 4) } or {
        status(101, 5, 'RIGHT', 4), status(102, 2, 'LEFT'), status(103, 5, 'RIGHT', nil, { isOutdated = true }),
        status(104, vim.NIL, 'RIGHT', nil, { subjectType = 'FILE' }), status(105, 5),
      }
      data = { data = { repository = { pullRequest = { headRefOid = wrong_head and base or pr(vars.number).headRefOid,
        reviewThreads = { nodes = nodes, pageInfo = { hasNextPage = false } } } } } }
    end
  elseif joined:find(' user', 1, true) then if viewer_failure then err = 'No viewer' else data = { login = 'alice' } end
  else error(vim.inspect(argv)) end
  local result = { code = err and 1 or 0, stderr = err or '', stdout = err and '' or vim.json.encode(data) }
  if held then callbacks[#callbacks + 1] = function() callback(result) end else vim.schedule(function() callback(result) end) end
  return { kill = function() end }
end
require('git').setup({ word_diff_style = 'github' })
local info, related = require('diffview_extension.commit_info'), require('diffview_extension.github_context')
local comments = require('diffview_extension.pr_comments')
local group = api.nvim_create_augroup('DiffviewPRCommentTest', { clear = true })
local provider, set_provider = nil, api.nvim_set_decoration_provider
api.nvim_set_decoration_provider = function(ns, callbacks)
  if ns == comments._namespace then provider = callbacks end
  return set_provider(ns, callbacks)
end
comments.setup(group); api.nvim_set_decoration_provider = set_provider
related.setup(group); info.setup(group)
require('diffview').setup(dofile(vim.fs.dirname(plugin) .. '/diffview.lua').opts)
local lib = require('diffview.lib')
local function settle(view)
  assert(vim.wait(7000, function()
    local state, context, relationship = comments._states[view.tabpage], info.state(view.tabpage), related.state(view.tabpage)
    if not context or context.request or not relationship or relationship.loading then return false end
    if not state or state.loading or state.projection_task then return false end
    if not view.cur_entry or not view.cur_entry.opened then return false end
    if view.cur_entry.revs.a.commit ~= view.left.commit or view.cur_entry.revs.b.commit ~= view.right.commit then return false end
    local count = 0
    for _, plan in pairs(state.plans) do if comments._valid(plan) then count = count + 1 end end
    return count == 2 and state.view == view
  end, 10), 'Comment projection failed to settle')
  return comments._states[view.tabpage]
end
local function open(args)
  local view = assert(lib.diffview_open(vim.list_extend({ '-C' .. root }, args)))
  view:open(); settle(view); return view
end
local function pane(state, side)
  for _, plan in pairs(state.plans) do if plan.side == side then return plan end end
end
local function snapshot(state, number)
  for _, s in ipairs(state.snapshots) do if s.ctx.number == number then return s end end
end
local view = open({ base .. '..' .. head })
local state = settle(view)
assert(#state.snapshots == 2 and #snapshot(state, 21).threads == 4, 'Pending or reply became a separate public thread')
assert(snapshot(state, 21).entries['a.lua'].old_path == 'old.lua', 'Rename did not resolve')
local left, right = pane(state, 'LEFT'), pane(state, 'RIGHT')
assert(left.rows[2][1].thread.id == 102 and right.rows[5][1].thread.id == 101 and right.rows[4][1].thread.id == 201)
assert(#right.rows[5][1].thread.comments == 2 and #right.ranges == 2)
assert(right.rows[5][1].first == 4 and right.rows[5][1].last == 5, 'Multiline anchor lost')
local panel = table.concat(api.nvim_buf_get_lines(view.panel.bufid, 0, -1, false), '\n')
assert(panel:find('💬 4', 1, true) and panel:find('gct all threads', 1, true))
-- Window decorations cannot leak into an ordinary window showing this buffer.
local ordinary = api.nvim_get_current_win()
assert(ordinary == view.panel.winid)
assert(comments._windows[ordinary] == nil)
assert(provider.on_win(nil, ordinary, right.buf) == false and provider.on_win(nil, right.win, right.buf))
local marks, set_mark = {}, api.nvim_buf_set_extmark
api.nvim_buf_set_extmark = function(buf, namespace, row, col, opts)
  marks[#marks + 1] = { buf = buf, namespace = namespace, row = row, opts = opts }; return 0
end
provider.on_line(nil, right.win, right.buf, 4)
provider.on_line(nil, left.win, left.buf, 1)
provider.on_line(nil, ordinary, right.buf, 4)
api.nvim_buf_set_extmark = set_mark
assert(#marks == 2 and marks[1].opts.ephemeral and marks[1].opts.virt_text[1][1] == ' 💬 1')
assert(marks[1].opts.virt_text[1][2] == 'DiagnosticInfo' and marks[2].opts.virt_text[1][2] == 'DiagnosticOk')
assert(#api.nvim_buf_get_extmarks(right.buf, comments._namespace, 0, -1, {}) == 0, 'Markers became permanent buffer extmarks')
api.nvim_set_current_win(right.win); api.nvim_win_set_cursor(right.win, { 5, 0 })
comments.open()
local preview = vim.b[right.buf].git_pr_preview
assert(preview and api.nvim_get_current_buf() == preview, 'gk did not focus published history')
local text = table.concat(api.nvim_buf_get_lines(preview, 0, -1, false), '\n')
assert(text:find('comment 101', 1, true) and text:find('comment 107', 1, true))
local reply, resolve, action
local saved_threads, saved_status, saved_actions = package.loaded['git.features.pr_threads'], package.loaded['git.features.pr_thread_status'], package.loaded['git.features.pr_comment_actions']
package.loaded['git.features.pr_threads'] = { open = function(ctx, thread) reply = { ctx, thread } end }
vim.fn.maparg('gc', 'n', false, true).callback(); assert(reply[1].number == 21 and reply[2].id == 101)
api.nvim_win_set_cursor(right.win, { 5, 0 }); comments.open()
package.loaded['git.features.pr_thread_status'] = vim.tbl_extend('force', saved_status, { toggle = function(ctx, threads) resolve = { ctx, threads } end })
vim.fn.maparg('gR', 'n', false, true).callback(); assert(resolve[1].number == 21 and resolve[2][1].id == 101)
api.nvim_win_set_cursor(right.win, { 5, 0 }); comments.open()
api.nvim_win_set_cursor(0, { #api.nvim_buf_get_lines(api.nvim_get_current_buf(), 0, -1, false), 0 })
package.loaded['git.features.pr_comment_actions'] = { menu = function(ctx, item) action = { ctx, item } end }
vim.fn.maparg('gA', 'n', false, true).callback(); assert(action[1].number == 21 and action[2].id == 107)
package.loaded['git.features.pr_threads'], package.loaded['git.features.pr_thread_status'], package.loaded['git.features.pr_comment_actions'] = saved_threads, saved_status, saved_actions
-- Thread navigation wraps between real LEFT/RIGHT panes and keeps preview routes.
api.nvim_set_current_win(right.win); api.nvim_win_set_cursor(right.win, { 5, 0 })
comments.navigate(1)
assert(api.nvim_get_current_buf() == vim.b[left.buf].git_pr_preview)
vim.fn.maparg('[t', 'n', false, true).callback()
assert(api.nvim_get_current_buf() == vim.b[right.buf].git_pr_preview)
vim.fn.maparg('q', 'n', false, true).callback()
assert(api.nvim_get_current_win() == right.win)
local select = vim.ui.select
local listed
vim.ui.select = function(items, opts, cb) listed = items; for _, item in ipairs(items) do if item.thread.id == 103 then cb(item); return end end end
comments.list(); assert(#listed == 5 and vim.b[right.buf].git_pr_preview, 'Outdated/file-level history unavailable')
require('git.features.pr_comment_preview').close(right.buf); api.nvim_set_current_win(right.win); vim.ui.select = select
local requests = #calls
comments.project(state); settle(view); assert(#calls == requests, 'Local projection refetched GitHub')
-- File selection invalidates old placements and uses cached remote threads.
local selected = view.cur_entry
for _, entry in view.files:iter() do if entry.path == 'b.lua' then view:set_file(entry, true); break end end
assert(vim.wait(5000, function() local plan = pane(state, 'RIGHT'); return plan and plan.path == 'b.lua' and comments._valid(plan) end, 10))
assert(#pane(state, 'RIGHT').ranges == 0 and #calls == requests)
view:set_file(selected, true)
assert(vim.wait(5000, function() local plan = pane(state, 'RIGHT'); return plan and plan.path == 'a.lua' and comments._valid(plan) and #plan.ranges == 2 end, 10))
-- Retargeting replaces the remote/projection state and rejects the old pane plan.
local previous_state = state
view:set_revs(head .. '..' .. base)
assert(vim.wait(5000, function() return comments._states[view.tabpage] and comments._states[view.tabpage] ~= previous_state end, 10))
state = settle(view); assert(not comments._valid(right) and info.state(view.tabpage).context.right.commit == base)
view:close(); assert(comments._states[view.tabpage] == nil, 'Closed comparison retained comments')
-- Mutable views shift unchanged code after edits, but suppress changed anchors.
view = open({ base }); state = settle(view); right = pane(state, 'RIGHT')
api.nvim_set_current_win(right.win)
api.nvim_buf_set_lines(right.buf, 0, 0, false, { 'prefix' })
assert(not comments._valid(right), 'Changed buffer retained stale anchors before recomputation')
api.nvim_exec_autocmds('TextChanged', { buffer = right.buf }); state = settle(view); right = pane(state, 'RIGHT')
assert(right.rows[6] and right.rows[5] and right.rows[6][1].first == 5, 'Insertion did not shift confirmed anchors')
api.nvim_buf_set_lines(right.buf, 4, 5, false, { 'changed anchor' }); api.nvim_exec_autocmds('TextChanged', { buffer = right.buf })
state = settle(view); right = pane(state, 'RIGHT'); assert(#right.ranges == 0, 'Changed anchor was guessed')
api.nvim_buf_set_lines(right.buf, 0, -1, false, after); vim.bo[right.buf].modified = false
api.nvim_exec_autocmds('TextChanged', { buffer = right.buf }); settle(view)
-- A normal editor window using the same worktree buffer has no marker plan.
api.nvim_set_current_win(right.win); vim.cmd('vsplit'); local ordinary_win = api.nvim_get_current_win()
assert(api.nvim_get_current_buf() == right.buf and comments._windows[ordinary_win] == nil)
api.nvim_win_close(ordinary_win, true); api.nvim_set_current_win(right.win)
-- Canonical head mismatch and partial GraphQL failure preserve the list only.
wrong_head = true; related.refresh(view, true); state = settle(view)
assert(#pane(state, 'RIGHT').ranges == 0 and #snapshot(state, 21).threads == 4 and #snapshot(state, 21).errors > 0)
wrong_head = false; status_failure = true; related.refresh(view, true); state = settle(view)
assert(#pane(state, 'RIGHT').ranges == 0 and #snapshot(state, 21).threads > 0)
status_failure = false; viewer_failure = true; related.refresh(view, true); state = settle(view); right = pane(state, 'RIGHT')
assert(snapshot(state, 21).viewer == nil and right.rows[5], 'Viewer failure removed readable threads')
api.nvim_set_current_win(right.win); api.nvim_win_set_cursor(right.win, { 5, 0 }); comments.open()
require('git.features.pr_comment_preview').close(right.buf); api.nvim_set_current_win(right.win)
-- Missing local PR objects remain list-only; no automatic fetch is performed.
missing_blobs = true; related.refresh(view, true); state = settle(view)
assert(#pane(state, 'RIGHT').ranges == 0 and #pane(state, 'LEFT').ranges == 0 and #snapshot(state, 21).threads == 4)
missing_blobs = false; advanced_base = true; related.refresh(view, true); state = settle(view)
assert(#pane(state, 'LEFT').ranges == 0 and #pane(state, 'RIGHT').ranges == 2, 'Unverified old LEFT base was used')
advanced_base = false
-- Cancel reads on close and reject late callbacks.
held = true; related.refresh(view, true)
local tab = view.tabpage; view:close()
for _, cb in ipairs(callbacks) do cb() end; vim.wait(50)
assert(comments._states[tab] == nil and related.state(tab) == nil)
vim.system = system; vim.fn.delete(root, 'rf')
print('PASS: real Diffview PR comments, public/left/right/rename/range anchors, preview actions, list fallback, edits, window scope, partial failures, refresh and close cancellation')

-- Repository evidence is shared by all actions in one render/validation pass.
-- Action declarations own policy; this module owns reads and reusable predicates.
local M = {}
local utils = require('git.utils')
local selection = require('git.features.action_selection')
local State = {}
State.__index = State
local namespaces = { local_ = 'refs/heads/', remote = 'refs/remotes/', tags = 'refs/tags/' }
local function pack(...) return { n = select('#', ...), ... } end

function M.ref(ctx)
  if ctx.commit then return ctx.commit end
  local prefix = ctx.panel == 'branch' and namespaces[ctx.branch_kind] or nil
  return ctx.branch and ((prefix or '') .. ctx.branch) or nil
end

function State:memo(key, read)
  if self.cache[key] == nil then self.cache[key] = pack(read()) end
  return unpack(self.cache[key], 1, self.cache[key].n)
end

function State:git(args)
  return self:memo(vim.json.encode(args), function()
    local argv = { 'git', '--no-optional-locks', '-C', self.ctx.work_tree }
    vim.list_extend(argv, args)
    local result = vim.system(argv, { text = true }):wait()
    return result.code == 0 and vim.trim(result.stdout or '') or nil, result.code
  end)
end

function State:head() return self:git({ 'rev-parse', '--verify', 'HEAD' }) end
function State:branch() return self:git({ 'symbolic-ref', '--quiet', '--short', 'HEAD' }) end
function State:dir()
  return self:memo('git_dir', function() return utils.get_git_dir(self.ctx.work_tree) end)
end
function State:operation()
  return self:memo('operation', function()
    return require('git.features.operation').inspect(self.ctx.work_tree, self:dir())
  end)
end
function State:unmerged() return self:git({ 'ls-files', '-u' }) ~= '' end
function State:staged() local _, code = self:git({ 'diff', '--cached', '--quiet' }); return code == 1 end
function State:unstaged() local _, code = self:git({ 'diff', '--quiet' }); return code == 1 end
function State:clean() return self:git({ 'status', '--porcelain', '--untracked-files=all' }) == '' end
function State:config(key) return self:git({ 'config', '--get', key }) end
function State:boolean(key)
  local value = self:git({ 'config', '--type=bool', '--get', key })
  if value == nil then return nil end
  return value == 'true'
end
function State:remotes() return vim.split(self:git({ 'remote' }) or '', '\n', { trimempty = true }) end
function State:remote(name) return name == '.' or vim.tbl_contains(self:remotes(), name) end
function State:upstream(branch)
  branch = branch or self:branch()
  if not branch then return end
  return self:config('branch.' .. branch .. '.remote'), self:config('branch.' .. branch .. '.merge')
end
function State:push_remote(branch)
  branch = branch or self:branch()
  if not branch then return end
  return self:config('branch.' .. branch .. '.pushRemote') or self:config('remote.pushDefault')
    or self:config('branch.' .. branch .. '.remote')
end
function State:resolve(ref)
  if not ref then return end
  return self:git({ 'rev-parse', '--verify', '--end-of-options', ref .. '^{commit}' })
end
function State:target()
  local ctx = self.ctx
  return ctx.commit or ctx.target_head or M.ref(ctx)
end
function State:parents(ref)
  local line = self:git({ 'rev-list', '--parents', '-n1', ref })
  return line and #vim.split(line, ' ', { trimempty = true }) - 1 or nil
end
function State:ancestor(ref, target)
  local _, code = self:git({ 'merge-base', '--is-ancestor', ref, target or 'HEAD' })
  return code == 0
end
function State:worktrees()
  return self:memo('worktrees', function()
    local entries, current = {}, nil
    local output = self:git({ 'worktree', 'list', '--porcelain', '-z' }) or ''
    for _, item in ipairs(vim.split(output, '\0', { plain = true })) do
      if item:sub(1, 9) == 'worktree ' then
        current = { path = item:sub(10) }; entries[#entries + 1] = current
      elseif current then
        local key, value = item:match('^(%S+)%s+(.*)$')
        if key then current[key] = value else current[item] = true end
      end
    end
    return entries
  end)
end
function State:occupied(branch)
  for _, wt in ipairs(self:worktrees()) do
    if wt.branch == 'refs/heads/' .. branch then return wt.path end
  end
end
function State:option(name) return self.options[name] end
function State:modules()
  return self:memo('modules', function()
    local paths = {}
    local output = self:git({ 'config', '--null', '--file', '.gitmodules', '--get-regexp', '^submodule\\..*\\.path$' }) or ''
    for _, item in ipairs(vim.split(output, '\0', { plain = true, trimempty = true })) do
      paths[#paths + 1] = item:match('^[^\n]+\n(.*)$')
    end
    if #paths == 0 then return paths end
    local args = { '--literal-pathspecs', 'ls-files', '--stage', '-z', '--' }
    vim.list_extend(args, paths)
    local registered = {}
    for _, item in ipairs(vim.split(self:git(args) or '', '\0', { plain = true, trimempty = true })) do
      local path = item:match('^160000 %x+ %d\t(.*)$')
      if path then registered[path] = true end
    end
    return vim.tbl_filter(function(path) return registered[path] end, paths)
  end)
end

function M.selected_submodule(ctx)
  if not ctx.path then return end
  local s = setmetatable({ ctx = ctx, cache = {} }, State)
  for _, path in ipairs(s:modules()) do if path == ctx.path then return path end end
end

function M.source(ctx, targeted)
  -- Workflow entry points also accept an explicit repository without a panel.
  if not ctx.bufnr and not ctx.source_win then
    return ctx.work_tree ~= nil and utils.get_git_dir(ctx.work_tree) ~= nil, 'Repository is unavailable'
  end
  if not vim.api.nvim_win_is_valid(ctx.source_win)
    or not vim.api.nvim_buf_is_valid(ctx.bufnr)
    or utils.get_buf_work_tree(ctx.bufnr) ~= ctx.work_tree then
    return false, 'Source panel changed; reopen the action menu'
  end
  if targeted then
    for _, item in ipairs(ctx.source_selections or {}) do
      if not selection.matches(ctx.bufnr, item.row, item.value) then
        return false, 'Selected item changed; reopen the action menu'
      end
    end
  end
  return true
end

function M.mapping(ctx, key)
  local ok, reason = M.source(ctx, true)
  if not ok then return false, reason end
  if vim.api.nvim_win_get_buf(ctx.source_win) ~= ctx.bufnr then
    return false, 'Source window changed; reopen the action menu'
  end
  local map = vim.api.nvim_buf_call(ctx.bufnr, function() return vim.fn.maparg(key, 'n', false, true) end)
  if map.buffer ~= 1 or (type(map.callback) ~= 'function' and (not map.rhs or map.rhs == '')) then
    return false, 'Action is not registered in the source panel'
  end
  return true, nil, map
end

local rules = {}
function rules.head(s) return s:head() ~= nil, 'Requires at least one commit' end
function rules.branch(s) return s:branch() ~= nil, 'Requires a checked-out branch' end
function rules.resolved(s) return not s:unmerged(), 'Resolve unmerged files first' end
function rules.clean(s) return s:clean(), 'Commit, stash, or discard worktree changes first' end
function rules.idle(s)
  local op = s:operation()
  return op == nil, op and ('Finish the current ' .. op.kind .. ' first') or nil
end
function rules.no_sequence(s)
  local op = s:operation()
  return not op or op.kind == 'bisect', op and ('Finish the current ' .. op.kind .. ' first') or nil
end
function rules.staged(s) return s:staged(), 'No staged changes' end
function rules.changes(s) return not s:clean(), 'No changes to save' end
function rules.tracked_changes(s) return s:staged() or s:unstaged(), 'No tracked changes' end
function rules.remotes(s) return #s:remotes() > 0, 'No remotes configured' end
function rules.upstream(s)
  local remote, ref = s:upstream()
  return remote ~= nil and ref ~= nil and s:remote(remote), 'No configured upstream remote and branch'
end
function rules.upstream_remote(s)
  local remote = s:upstream()
  return remote ~= nil and s:remote(remote), 'No configured upstream remote'
end
function rules.push_remote(s)
  local remote = s:push_remote()
  return remote ~= nil and s:remote(remote), 'No configured push remote'
end
function rules.local_ref(s)
  return s.ctx.branch_kind == 'local_' and s:resolve('refs/heads/' .. s.ctx.branch) ~= nil,
    'Select an existing local branch'
end
function rules.unoccupied(s)
  return not s:occupied(s.ctx.branch), 'Branch is checked out in a worktree'
end
function rules.deletable(s)
  local branch = s.ctx.branch
  local upstream = s:resolve(branch .. '@{upstream}') or 'HEAD'
  return s:ancestor('refs/heads/' .. branch, upstream), 'Branch is not fully merged; use the branch panel for force deletion'
end
function rules.selected(s)
  for _, ref in ipairs(s.ctx.commits or { s:target() }) do
    if not s:resolve(ref) then return false, 'Selected revision no longer exists' end
  end
  return true
end
function rules.rewrite(s)
  local ref = s.ctx.commit
  return ref ~= nil and s:resolve(ref) ~= nil and s:ancestor(ref), 'Select a commit on the current history'
end
function rules.nonmerge(s)
  return s.ctx.commit ~= nil and (s:parents(s.ctx.commit) or 2) <= 1, 'Select a non-merge commit'
end
function rules.collection(s)
  if not s.ctx.commit then return true end
  return s:ancestor(s.ctx.commit) and (s:parents(s.ctx.commit) or 2) <= 1,
    'Select a non-merge commit on current history'
end
function rules.patch_source(s)
  local target = s:target()
  if target then
    local parents = s:parents(target)
    if not parents or parents > 1 then return false, 'Select a non-merge commit to apply its patch' end
    return (s:git({ 'diff-tree', '--root', '--no-commit-id', '--name-only', '-r', target }) or '') ~= '',
      'Selected commit has no patch'
  end
  if s.ctx.path and s.ctx.section == 'staged' then
    local _, code = s:git({ 'diff', '--cached', '--quiet', '--', s.ctx.path })
    return code == 1, 'Selected staged patch is empty'
  end
  return false, 'Select a commit or staged change'
end
function rules.startpoint(s)
  return s:target() ~= nil or s:head() ~= nil, 'Requires an existing starting commit'
end
function rules.diff_target(s)
  return s:target() ~= nil or s.ctx.path ~= nil or s:head() ~= nil, 'Requires a commit or file selection'
end
function rules.unoccupied_target(s)
  local ctx = s.ctx
  return not ctx.branch or (ctx.branch_kind ~= 'local_' and ctx.panel ~= 'worktree')
    or not s:occupied(ctx.branch), 'Branch is checked out in a worktree'
end
function rules.checkout_source(s)
  local ctx = s.ctx
  if ctx.branch_kind == 'local_' then
    local occupied = s:occupied(ctx.branch)
    if occupied and occupied ~= ctx.work_tree then return false, 'Branch is checked out in another worktree' end
  end
  if ctx.panel == 'branch' and ctx.branch and ctx.branch_kind ~= 'tags'
    and not s:option('recurse_submodules') and not s:option('merge') then
    return M.mapping(ctx, 'coo')
  end
  return true
end
function rules.reword(s)
  if not s.ctx.commit then return true end
  local ok, reason = rules.collection(s)
  if not ok then return false, reason end
  return M.mapping(s.ctx, 'cw')
end
function rules.edit_todo(s)
  return vim.fn.filereadable(s:dir() .. '/rebase-merge/git-rebase-todo') == 1,
    'This rebase has no editable todo list'
end
function rules.unshallow_option(s)
  return s:option('unshallow') or s:git({ 'rev-parse', '--is-shallow-repository' }) == 'true',
    'Repository already has full history'
end
function rules.linked_worktree(s)
  local entries = s:worktrees()
  for i, wt in ipairs(entries) do
    if wt.path == s.ctx.target_worktree then
      return i ~= 1 and not wt.bare and not wt.locked,
        i == 1 and 'Cannot move or remove the primary worktree' or 'Worktree is locked'
    end
  end
  if not s.ctx.target_worktree then
    for i, wt in ipairs(entries) do if i > 1 and not wt.bare and not wt.locked then return true end end
  end
  return false, s.ctx.target_worktree and 'Selected worktree no longer exists' or 'No unlocked linked worktrees available'
end
function rules.sparse(s)
  return s:boolean('core.sparseCheckout') == true, 'Sparse checkout is not enabled'
end
function rules.stashes(s)
  return s:resolve('refs/stash') ~= nil, 'No stashes available'
end
function rules.tags(s)
  return (s:git({ 'for-each-ref', '--count=1', '--format=%(refname)', 'refs/tags/' }) or '') ~= '', 'No tags available'
end
function rules.refs(s)
  return (s:git({ 'for-each-ref', '--count=1', '--format=%(refname)' }) or '') ~= '', 'No refs available'
end
function rules.bundle_source(s)
  if s:option('revisions') then return true end
  if s:option('all') then return rules.refs(s) end
  return rules.head(s)
end
function rules.amend(s)
  local op = s:operation()
  return s:head() ~= nil and (not op or op.kind == 'rebase' or op.kind == 'bisect'),
    'Cannot amend without HEAD or during merge, cherry-pick, revert, or mail application'
end
function rules.committable(s)
  return s:option('allow_empty') or s:staged() or (s:option('all') and s:unstaged()),
    'Stage changes, enable tracked changes, or allow an empty commit'
end
function rules.rebase_clean(s)
  return s:option('autostash') or s:boolean('rebase.autoStash') or (not s:staged() and not s:unstaged()),
    'Commit or stash tracked changes, or enable autostash'
end
function rules.pull_clean(s)
  local mode = s:option('rebase_mode')
  if mode == nil then
    if s:option('rebase') then mode = 'true'
    else
      local branch = s:branch()
      mode = branch and s:config('branch.' .. branch .. '.rebase') or nil
      mode = mode or s:config('pull.rebase')
    end
  end
  if not mode or vim.tbl_contains({ 'false', 'no', 'off', '0' }, mode) then return true end
  local autostash = s:boolean('pull.autostash')
  if autostash == nil then autostash = s:boolean('rebase.autoStash') end
  return s:option('autostash') or autostash or (not s:staged() and not s:unstaged()),
    'Rebase pull requires clean tracked files or autostash'
end
function rules.fixup_message(s)
  return not s:option('reuse_message') and not s:option('reedit_message'),
    'Clear reuse/reedit message arguments when creating a fixup commit'
end
function rules.tracked_clean(s)
  return not s:staged() and not s:unstaged(), 'Commit or stash tracked changes first'
end
function rules.log_arguments(s)
  if s:option('line') and s:option('path') then return false, 'Line evolution cannot be combined with a file limit' end
  if s:option('follow') and not s:option('path') then return false, 'Follow renames requires a single file limit' end
  return not (s:option('graph') and s:option('reverse')), 'Graph cannot be combined with reverse order'
end
function rules.stash_save(s)
  if s:staged() or s:unstaged() then return true end
  if s:option('all') then
    return (s:git({ 'status', '--porcelain', '--ignored', '--untracked-files=all' }) or '') ~= '', 'No changes to save'
  end
  return s:option('untracked') and not s:clean(), 'No tracked changes; enable untracked or ignored files if needed'
end
function rules.replay(s)
  local mainline = tonumber(s:option('mainline'))
  for _, ref in ipairs(s.ctx.commits or { s:target() }) do
    local parents = s:parents(ref)
    if not parents then return false, 'Selected commit no longer exists' end
    if parents > 1 and not mainline then return false, 'Set the mainline parent to replay a merge commit' end
    if mainline and mainline > parents then return false, 'Mainline parent does not exist in the selected commit' end
  end
  return true
end
function rules.commit_index(s)
  return s:option('no_commit') or not s:staged(), 'Commit or unstage the index, or apply without committing'
end
function rules.spin(s)
  return s:memo('spin', function()
    local from = (s.ctx.panel == 'status' or s.ctx.panel == 'log') and s.ctx.commit or nil
    local plan, err = require('git.features.branch_spin').plan(s.ctx.work_tree, 'spinoff', from)
    return plan ~= nil, err
  end)
end
local function move_commit(s, harvest)
  if not s.ctx.commit then return true end
  local ref = s.ctx.commit
  if s:parents(ref) ~= 1 then return false, 'Select a non-root, non-merge commit' end
  if s:ancestor(ref) == harvest then
    return false, harvest and 'Commit is already on the current branch' or 'Commit is not on the current branch'
  end
  local branches = s:git({ 'for-each-ref', '--format=%(refname:lstrip=2)', 'refs/heads/' }) or ''
  for name in branches:gmatch('[^\n]+') do
    if name ~= s:branch() and not s:occupied(name) and s:ancestor(ref, 'refs/heads/' .. name) == harvest then
      return true
    end
  end
  return false, harvest and 'No available local source branch contains this commit'
    or 'No available local destination branch excludes this commit'
end
function rules.harvest(s) return move_commit(s, true) end
function rules.donate(s) return move_commit(s, false) end
function rules.range_diff(s)
  return s:resolve('@{push}') ~= nil or s:resolve('@{upstream}') ~= nil, 'No push or upstream tracking ref available'
end
function rules.previous_branch(s)
  return s:resolve('@{-1}') ~= nil, 'No previous checkout available'
end
function rules.rebase_push(s)
  local remote, branch = s:push_remote(), s:branch()
  local ref = remote and branch and (remote == '.' and branch or 'refs/remotes/' .. remote .. '/' .. branch)
  return ref ~= nil and s:resolve(ref) ~= nil, 'Push destination has no local tracking ref'
end
function rules.rebase_upstream(s)
  return s:resolve('@{upstream}') ~= nil, 'Upstream tracking ref is unavailable'
end
function rules.default_remote(s)
  if s:option('all') then return rules.remotes(s) end
  local remote = s:branch() and s:config('branch.' .. s:branch() .. '.remote') or 'origin'
  remote = remote or 'origin'
  return s:remote(remote), 'No default fetch remote; use Fetch elsewhere'
end
function rules.shallow(s)
  return s:git({ 'rev-parse', '--is-shallow-repository' }) == 'true', 'Repository already has full history'
end
function rules.undo(s)
  local output = s:git({ 'reflog', '--format=%H%x00%gs' }) or ''
  local plan, err = require('git.features.history_undo').parse(output, false)
  return plan ~= nil, err
end
function rules.redo(s)
  local output = s:git({ 'reflog', '--format=%H%x00%gs' }) or ''
  local plan, err = require('git.features.history_undo').parse(output, true)
  return plan ~= nil, err
end
function rules.sparse_arguments(s)
  return not s:option('index') or s:option('cone'), 'Sparse index requires cone mode'
end
function rules.modules(s) return #s:modules() > 0, 'No submodules registered' end
function rules.note(s)
  local args = { 'notes' }
  if s:option('ref') then args[#args + 1] = '--ref=' .. s:option('ref') end
  args[#args + 1] = 'list'
  if s.ctx.commit then args[#args + 1] = s.ctx.commit end
  local output = s:git(args)
  return output ~= nil and output ~= '', 'No note available for this selection and notes ref'
end
function rules.notes_merge(s)
  return vim.fn.filereadable(s:dir() .. '/NOTES_MERGE_REF') == 1,
    'Notes merge is no longer in progress'
end
function rules.no_notes_merge(s)
  return vim.fn.filereadable(s:dir() .. '/NOTES_MERGE_REF') ~= 1,
    'Finish the current notes merge first'
end
function rules.fetch_arguments(s)
  return not s:option('unshallow') or s:git({ 'rev-parse', '--is-shallow-repository' }) == 'true',
    'Repository already has full history; clear the full-history argument'
end
function rules.fetch_one(s)
  return not s:option('all'), 'Clear Fetch all remotes to specify a remote'
end
function rules.merge_arguments(s)
  return not (s:option('squash') and s:option('no_ff')), 'Squash cannot be combined with a forced merge commit'
end
function rules.commit_author(s)
  return not s:option('reset_author') or s:option('reuse_message') or s:option('reedit_message'),
    'Reset author requires amend or a reused commit message'
end
function rules.patch_arguments(s)
  return not (s:option('cached') and s:option('reject')), 'Index-only application cannot write rejected hunks'
end
function rules.sync_worktree(s)
  local primary = s:worktrees()[1]
  return primary ~= nil and s.ctx.target_worktree ~= primary.path and s.ctx.target_head ~= nil
    and s.ctx.target_head ~= primary.HEAD, 'Select a linked worktree with a different HEAD from primary'
end
function rules.removable_worktree(s)
  if not s.ctx.target_worktree then return true end
  local output = s:git({ '-C', s.ctx.target_worktree, 'status', '--porcelain', '--untracked-files=all' })
  return output == '', 'Worktree has changes; use the worktree panel to remove with force'
end

function M.operation(kind)
  return function(s)
    local op = s:operation()
    return op and op.kind == kind, 'Operation changed; reopen the action menu'
  end
end

function M.start_or_resume(kinds)
  return function(s)
    local op = s:operation()
    if op and vim.tbl_contains(kinds, op.kind) then return true end
    local ok, reason = rules.no_sequence(s)
    if not ok then return false, reason end
    return rules.resolved(s)
  end
end

local function scoped(ctx, validate, callback, ...)
  local previous = ctx.validate
  ctx.validate = validate
  local result = pack(pcall(callback, ...))
  ctx.validate = previous
  if not result[1] then error(result[2], 0) end
  return unpack(result, 2, result.n)
end

function M.valid(ctx, targeted)
  local ok, reason = M.source(ctx, targeted)
  if not ok then vim.notify(reason, vim.log.levels.WARN); return false end
  return not ctx.validate or ctx.validate()
end

-- Input callbacks retain the particular action's validator, even after the
-- menu closes or another menu is opened while a prompt is pending.
function M.callback(ctx, callback)
  local validate = ctx.validate
  return function(...)
    local ok, reason = M.source(ctx, true)
    if not ok then vim.notify(reason, vim.log.levels.WARN); return end
    if validate and not validate() then return end
    return scoped(ctx, validate, callback, ...)
  end
end

for _, method in ipairs({ 'input', 'select' }) do
  M[method] = function(ctx, ...)
    local args = { ... }
    args[#args] = M.callback(ctx, args[#args])
    vim.ui[method](unpack(args))
  end
end

function M.bind(spec, ctx)
  for _, group in ipairs(spec.groups or {}) do
    for _, action in ipairs(group.actions) do
      if action.run then
        local run = action.run
        action.run = function(ui) return scoped(ctx, ui.validate, run, ui) end
      end
    end
  end
  return spec
end

function M.new(ctx)
  return function(spec)
    local s = setmetatable({ ctx = ctx, cache = {}, options = {} }, State)
    for _, group in ipairs(spec.groups or {}) do
      for _, a in ipairs(group.actions) do
        if a.option then s.options[a.option.name] = a.option.state[a.option.name] end
      end
    end
    return function(action, group)
      local ok, reason = M.source(ctx, false)
      if not ok then return false, reason end
      if (action.option and not action.requires) or group.title == 'Argument presets' then return true end
      if not ctx.work_tree or not s:dir() then
        return false, 'Repository is unavailable'
      end
      if action.source_key then
        ok, reason = M.mapping(ctx, action.source_key)
        if not ok then return false, reason end
      end
      local mutation = action.mutation
      if mutation == nil then mutation = group.mutation end
      if mutation == nil then mutation = spec.mutation end
      if type(mutation) == 'function' then mutation = mutation(s) end
      if mutation then
        if require('git.features.async').busy(ctx.work_tree) then
          return false, 'A Git history operation is already running'
        end
      end
      local requirements = action.option and { action.requires or {} }
        or { spec.requires or {}, group.requires or {}, action.requires or {} }
      for _, list in ipairs(requirements) do
        for _, rule in ipairs(list) do
          ok, reason = (type(rule) == 'function' and rule or assert(rules[rule], rule))(s)
          if not ok then return false, reason end
        end
      end
      return true
    end
  end
end

return M

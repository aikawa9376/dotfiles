local M = {}
local menu = require('git.features.transient_menu')
local utils = require('git.utils')
local options = require('git.features.transient_options')
local availability = require('git.features.magit_availability')
local flag, value_flag, exclusive_flag = options.flag, options.value, options.exclusive_flag

local function context(bufnr, row)
  local ft = vim.bo[bufnr].filetype
  local panel = ({ gitstatus = 'status', gitlog = 'log',
    gitbranch = 'branch', gitreflog = 'reflog',
    gitworktree = 'worktree', gitcommitview = 'commit',
    gitpatchcollection = 'commit', gitstatustree = 'tree' })[ft]
  if not panel then return nil end
  row = row or vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ''
  if panel == 'status' and require('git.features.status_modules').at(bufnr, row) then line = '' end
  local commit = (panel == 'status' or panel == 'log')
    and line:match('^(%x%x%x%x%x%x%x+)%s') or nil
  if panel == 'commit' then commit = vim.b[bufnr].git_commit end
  local branch = panel == 'branch' and (vim.b[bufnr].branch_map or {})[row] or nil
  local kind = panel == 'branch' and (vim.b[bufnr].branch_kinds or {})[row] or nil
  local reflog = panel == 'reflog' and require('git.features.reflog').entry_at(bufnr, row) or nil
  local worktree = panel == 'worktree' and (vim.b[bufnr].worktree_entries or {})[row] or nil
  if reflog then commit = reflog.hash end
  if worktree then branch = worktree.branch end
  local tree_node = panel == 'tree' and require('git.features.status_tree').entry_at(bufnr, row) or nil
  local entry = panel == 'status' and require('git.features.status_renderer').entry_at(bufnr, row)
    or (tree_node and tree_node.entry) or nil
  local hunk
  if entry and entry.section == 'staged' and not entry.header then
    local renderer = require('git.features.status_renderer')
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local first = row
    while first > 1 and renderer.entry_at(bufnr, first - 1) == entry do first = first - 1 end
    local number, start = 0, nil
    for at = first, row do
      if lines[at] and lines[at]:match('^@@') then number = number + 1; start = at end
    end
    if start then
      local expected = {}
      local at = start
      while renderer.entry_at(bufnr, at) == entry and lines[at]
        and (at == start or not lines[at]:match('^@@')) do
        expected[#expected + 1] = lines[at]
        at = at + 1
      end
      hunk = { number = number, expected = expected }
    end
  end
  local path = entry and not entry.header and entry.path or nil
  if not path and panel == 'status' then
    path = line:match('^[MADRCUT?!][MADRCUT?!]? (.+)$')
    if path then path = path:match('^.+ %-> (.+)$') or path end
  end
  return {
    panel = panel, bufnr = bufnr, work_tree = utils.get_buf_work_tree(bufnr),
    source_win = vim.api.nvim_get_current_win(), source_row = row,
    source_selections = { { row = row, value = require('git.features.action_selection').capture(bufnr, row) } },
    commit = commit, branch = branch, branch_kind = kind, path = path,
    section = entry and entry.section or (tree_node and tree_node.section),
    hunk = hunk,
    reflog_selector = reflog and reflog.selector or nil,
    target_worktree = worktree and worktree.path or nil,
    target_head = worktree and worktree.head or nil,
  }
end
M.context = context

local function git(args, ctx)
  if ctx and not availability.valid(ctx, true) then return end
  local quoted = {}
  for _, arg in ipairs(args) do
    if arg:find('[\r\n]') then error('Git arguments cannot contain newlines') end
    quoted[#quoted + 1] = arg:match('^[%w_./@+%-]+$') and arg or vim.fn.shellescape(arg)
  end
  local function run()
    return require('git.commands').git({ args = table.concat(quoted, ' '), bang = false,
      bufnr = ctx and ctx.bufnr })
  end
  if ctx and vim.api.nvim_win_is_valid(ctx.source_win) then
    vim.api.nvim_set_current_win(ctx.source_win)
  end
  return run()
end

local function existing_key(ctx, key)
  if not availability.valid(ctx, true) then return end
  local ok, reason, mapping = availability.mapping(ctx, key)
  if not ok then vim.notify(reason, vim.log.levels.WARN); return end
  vim.api.nvim_set_current_win(ctx.source_win)
  vim.api.nvim_win_set_cursor(ctx.source_win, { ctx.source_row, 0 })
  if type(mapping.callback) == 'function' then return mapping.callback() end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(mapping.rhs, true, false, true), 'n', false)
end

local function target_commit(ctx, callback)
  if ctx.commit then callback(ctx.commit); return end
  availability.input(ctx, { prompt = 'Commit or range: ' }, function(value)
    if value and vim.trim(value) ~= '' then callback(vim.trim(value)) end
  end)
end

local function target_commits(ctx, reverse, callback)
  if ctx.commits then
    local commits = vim.deepcopy(ctx.commits)
    if reverse then commits = vim.fn.reverse(commits) end
    callback(commits)
  else
    target_commit(ctx, function(commit) callback({ commit }) end)
  end
end

local function input(ctx, prompt, callback, default)
  availability.input(ctx, { prompt = prompt, default = default }, function(value)
    if value and vim.trim(value) ~= '' then callback(vim.trim(value)) end
  end)
end

local function git_value(ctx, args)
  if not ctx.work_tree then return nil end
  local argv = { 'git', '-C', ctx.work_tree }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  if result.code ~= 0 then return nil end
  local value = vim.trim(result.stdout)
  return value ~= '' and value or nil
end

local function commit_label(ctx)
  return ctx.commit_label or ('Commit: ' .. ctx.commit:sub(1, 12))
end

local function short_target(ctx)
  if ctx.commit then return ctx.commit:sub(1, 7) end
  if ctx.branch then
    return vim.fn.strchars(ctx.branch) > 18
      and vim.fn.strcharpart(ctx.branch, 0, 17) .. '…' or ctx.branch
  end
  return 'ref'
end

local function branch_remotes(ctx)
  local branch = git_value(ctx, { 'symbolic-ref', '--quiet', '--short', 'HEAD' })
  if not branch then return nil end
  local config = git_value(ctx, { 'config', '--get-regexp',
    '^(branch\\..*\\.(remote|merge|pushremote)|remote\\.pushdefault)$' }) or ''
  local values = {}
  for line in config:gmatch('[^\n]+') do
    local key, value = line:match('^(%S+)%s+(.*)$')
    if key and value ~= '' then values[key] = value end
  end
  local prefix = 'branch.' .. branch .. '.'
  local upstream = values[prefix .. 'remote']
  local merge_ref = values[prefix .. 'merge']
  local push_remote = values[prefix .. 'pushremote'] or values['remote.pushdefault'] or upstream
  return { branch = branch, upstream = upstream, merge_ref = merge_ref,
    push_remote = push_remote }
end

local function selected_transfer(ctx)
  if ctx.panel ~= 'branch' or not ctx.branch then
    return ctx.commit and { source = ctx.commit, kind = 'commit' } or nil
  end
  local branch, kind = ctx.branch, ctx.branch_kind
  if kind == 'tags' then
    return { source = 'refs/tags/' .. branch, destination = 'refs/tags/' .. branch,
      kind = 'tag' }
  end
  if kind == 'local_' then
    local prefix = 'branch.' .. branch .. '.'
    local upstream_remote = git_value(ctx, { 'config', '--get', prefix .. 'remote' })
    local upstream_ref = git_value(ctx, { 'config', '--get', prefix .. 'merge' })
    local push_remote = git_value(ctx, { 'config', '--get', prefix .. 'pushRemote' })
      or git_value(ctx, { 'config', '--get', 'remote.pushDefault' }) or upstream_remote
    return { source = 'refs/heads/' .. branch, destination = 'refs/heads/' .. branch,
      push_remote = push_remote, pull_remote = upstream_remote, pull_ref = upstream_ref,
      kind = 'local_' }
  end
  if kind == 'remote' then
    local remotes = git_value(ctx, { 'remote' }) or ''
    local matched
    for remote in remotes:gmatch('[^\n]+') do
      if branch:sub(1, #remote + 1) == remote .. '/'
        and (not matched or #remote > #matched) then
        matched = remote
      end
    end
    if matched then
      local name = branch:sub(#matched + 2)
      return { source = 'refs/remotes/' .. branch,
        destination = 'refs/heads/' .. name,
        push_remote = matched, pull_remote = matched,
        pull_ref = 'refs/heads/' .. name, kind = 'remote' }
    end
  end
  return nil
end

local function show_submenu(spec, ui)
  return menu.show(availability.bind(spec, ui.action_context), { source_win = ui.source_win, source_buf = ui.source_buf,
    layout = ui.layout, availability = ui.availability, action_context = ui.action_context })
end

local function branch_config_action(ctx)
  return { key = 'C', label = 'Configure branch…', run = function(ui)
    require('git.features.magit_config').open_branch(ctx, ui, show_submenu)
  end }
end

local function mainline_flag(state)
  return value_flag('-m', 'Replay merge relative to parent', state, 'mainline', '--mainline=',
    function(value)
      if value:match('^[1-9]%d*$') then return true end
      vim.notify('Mainline must be a positive parent number', vim.log.levels.WARN)
      return false
    end)
end

local function flag_args(state)
  local args = {}
  if state.mainline then args[#args + 1] = '--mainline=' .. state.mainline end
  if state.signoff then args[#args + 1] = '--signoff' end
  return args
end

local function active_operation(ctx)
  if not ctx.work_tree then return nil end
  local state = require('git.features.operation').inspect(ctx.work_tree)
  return state and state.kind or nil
end

local function sequence_menu(ctx, ui, title, kind)
  return show_submenu({ kind = kind, title = title,
    requires = { availability.operation(kind == 'cherry-pick' and 'cherry_pick' or kind) }, mutation = true,
    context = 'Operation in progress', groups = {
      { title = 'Actions', actions = {
        { key = kind == 'revert' and 'V' or 'A', label = 'Continue', requires = { 'resolved' },
          run = function() git({ kind, '--continue' }, ctx) end },
        { key = 's', label = 'Skip current commit',
          run = function() git({ kind, '--skip' }, ctx) end },
        { key = 'a', label = 'Abort sequence',
          run = function() git({ kind, '--abort' }, ctx) end },
      } },
    },
  }, ui)
end

local function cherry_menu(ctx, ui)
  local active = active_operation(ctx)
  if active == 'cherry_pick' or active == 'revert' then
    return sequence_menu(ctx, ui, active == 'revert' and 'Revert' or 'Cherry-pick',
      active == 'revert' and 'revert' or 'cherry-pick')
  end
  local state = { reference = false, no_commit = false, signoff = false,
    ff = true, edit = false }
  local function pick(no_commit)
    target_commits(ctx, true, function(commits)
      local args = { 'cherry-pick' }
      vim.list_extend(args, flag_args(state))
      if state.reference then args[#args + 1] = '-x' end
      if state.ff and not no_commit and not state.no_commit then args[#args + 1] = '--ff' end
      if state.edit then args[#args + 1] = '--edit' end
      if state.strategy then args[#args + 1] = '--strategy=' .. state.strategy end
      if state.gpg_sign then args[#args + 1] = '--gpg-sign=' .. state.gpg_sign end
      if no_commit or state.no_commit then args[#args + 1] = '--no-commit' end
      vim.list_extend(args, commits)
      git(args, ctx)
    end)
  end
  local function move(direction)
    target_commit(ctx, function(commit)
      local mover = require('git.features.magit_cherry_move')
      local function perform(branch)
        local ok, err = mover[direction](ctx.work_tree, commit, branch)
        if not ok then vim.notify(err, vim.log.levels.ERROR) end
      end
      if direction == 'donate' then
        input(ctx, 'Donate to local branch: ', perform)
        return
      end
      local containing = git_value(ctx, { 'for-each-ref', '--contains=' .. commit,
        '--format=%(refname:short)', 'refs/heads' })
      if not containing then
        vim.notify('No local branch contains the selected commit', vim.log.levels.WARN)
        return
      end
      local current = git_value(ctx, { 'symbolic-ref', '--quiet', '--short', 'HEAD' })
      local branches = vim.tbl_filter(function(branch) return branch ~= current end,
        vim.split(containing, '\n', { trimempty = true }))
      if #branches == 1 then perform(branches[1])
      elseif #branches > 1 then
        availability.select(ctx, branches, { prompt = 'Remove commit from branch: ' }, function(branch)
          if branch then perform(branch) end
        end)
      else vim.notify('No other local branch contains the selected commit', vim.log.levels.WARN) end
    end)
  end
  return show_submenu({ kind = 'cherry-pick', title = 'Cherry-pick',
    context = ctx.commits and ('%d selected commits'):format(#ctx.commits)
      or ctx.commit and commit_label(ctx) or 'Choose a commit on execution',
    groups = {
      { title = 'Arguments', actions = {
        exclusive_flag('-x', 'Reference source commit', state, 'reference', 'ff', '-x'),
        flag('-n', 'Apply without committing', state, 'no_commit', '--no-commit', 'ff'),
        flag('-s', 'Add Signed-off-by', state, 'signoff', '--signoff', 'ff'),
        exclusive_flag('-F', 'Fast-forward if possible', state, 'ff',
          { 'reference', 'no_commit', 'signoff', 'edit' }, '--ff'),
        flag('-e', 'Edit commit message', state, 'edit', '--edit', 'ff'),
        mainline_flag(state),
        value_flag('=s', 'Strategy', state, 'strategy', '--strategy='),
        value_flag('-S', 'Sign using GPG', state, 'gpg_sign', '--gpg-sign='),
      } },
      { title = 'Actions', mutation = true, requires = { 'no_sequence', 'resolved', 'selected' }, actions = {
        { key = 'A', requires = { 'replay', 'commit_index' }, label = 'Pick commit', run = function() pick(false) end },
        { key = 'a', requires = { 'replay' }, label = 'Apply changes without committing',
          run = function() pick(true) end },
        { key = 'h', requires = { 'head', 'branch', 'idle', 'clean', 'harvest' },
          label = 'Harvest commit from another branch', enabled = not ctx.commits,
          run = function() move('harvest') end },
        { key = 'd', requires = { 'head', 'branch', 'idle', 'clean', 'donate' },
          label = 'Donate commit to another branch', enabled = not ctx.commits,
          run = function() move('donate') end },
        { key = 's', requires = { 'spin' }, label = 'Spin off selected commits', enabled = not ctx.commits,
          source_key = 'bs', run = function() existing_key(ctx, 'bs') end },
        { key = 'n', requires = { 'spin' }, label = 'Spin out selected commits', enabled = not ctx.commits,
          source_key = 'bS', run = function() existing_key(ctx, 'bS') end },
      } },
    },
  }, ui)
end

local function apply_patch(ctx, reverse, three_way)
  if not availability.valid(ctx, true) then return end
  local ok, err = require('git.features.magit_apply').apply(ctx, three_way or false, reverse)
  if not ok then vim.notify(err, vim.log.levels.ERROR) end
end

local function apply_variants_menu(ctx, ui)
  local state = { three_way = false }
  local target = ctx.commit or ctx.target_head or availability.ref(ctx)
  local function apply(reverse)
    local patch_ctx = vim.tbl_extend('force', {}, ctx)
    if not patch_ctx.commit then patch_ctx.commit = target end
    apply_patch(patch_ctx, reverse, state.three_way)
  end
  local staged = ctx.panel == 'status' and ctx.path and ctx.section == 'staged'
  local can_patch = target or staged
  local can_discard = ctx.panel == 'status' and ctx.path ~= nil
  local context_label = ctx.commit and commit_label(ctx)
    or ctx.path and ((ctx.hunk and 'Hunk: ' or 'File: ') .. ctx.path)
    or ctx.branch and ('Ref: ' .. ctx.branch)
    or ctx.target_worktree and ('Worktree: ' .. ctx.target_worktree)
  return show_submenu({ kind = 'apply-variants', title = 'Apply variants',
    context = context_label, groups = {
      { title = 'Arguments', actions = {
        flag('-3', 'Three-way fallback (also stages)', state, 'three_way', '--3way'),
      } },
      { title = 'Patch', mutation = true, requires = { 'selected' }, actions = {
        { key = 'a', label = 'Apply to worktree', enabled = not not can_patch,
          requires = { 'patch_source' },
          reason = 'Select a commit or staged change',
          run = function() apply(false) end },
        { key = 'v', label = 'Reverse in worktree', enabled = not not can_patch,
          requires = { 'patch_source' },
          reason = 'Select a commit or staged change',
          run = function() apply(true) end },
        { key = 'k', label = 'Discard selected change', enabled = not not can_discard,
          reason = 'Select a changed file or hunk in status',
          source_key = 'X', run = function() existing_key(ctx, 'X') end },
      } },
      { title = 'Commit', mutation = true, requires = { 'no_sequence', 'resolved', 'selected', 'replay', 'commit_index' }, actions = {
        { key = 'C', label = 'Cherry-pick and commit', enabled = not not target,
          reason = 'Select a commit',
          run = function() git({ 'cherry-pick', target }, ctx) end },
        { key = 'V', label = 'Revert and commit', enabled = not not target,
          reason = 'Select a commit',
          run = function() git({ 'revert', target }, ctx) end },
      } },
    },
  }, ui)
end

local function revert_menu(ctx, ui)
  local active = active_operation(ctx)
  if active == 'cherry_pick' or active == 'revert' then
    return sequence_menu(ctx, ui, active == 'cherry_pick' and 'Cherry-pick' or 'Revert',
      active == 'cherry_pick' and 'cherry-pick' or 'revert')
  end
  local state = { no_commit = false, no_edit = false, edit = false, signoff = false }
  local function revert(no_commit)
    target_commits(ctx, false, function(commits)
      local args = { 'revert' }
      vim.list_extend(args, flag_args(state))
      if no_commit or state.no_commit then args[#args + 1] = '--no-commit' end
      if state.no_edit then args[#args + 1] = '--no-edit' end
      if state.edit then args[#args + 1] = '--edit' end
      if state.strategy then args[#args + 1] = '--strategy=' .. state.strategy end
      if state.gpg_sign then args[#args + 1] = '--gpg-sign=' .. state.gpg_sign end
      vim.list_extend(args, commits)
      git(args, ctx)
    end)
  end
  return show_submenu({ kind = 'revert', title = 'Revert',
    context = ctx.commits and ('%d selected commits'):format(#ctx.commits)
      or ctx.commit and commit_label(ctx) or 'Choose a commit on execution',
    groups = {
      { title = 'Arguments', actions = {
        flag('-n', 'Apply without committing', state, 'no_commit', '--no-commit'),
        exclusive_flag('-e', 'Edit commit message', state, 'edit', 'no_edit', '--edit'),
        exclusive_flag('-E', 'Do not edit commit message', state, 'no_edit', 'edit', '--no-edit'),
        flag('-s', 'Add Signed-off-by', state, 'signoff', '--signoff'),
        mainline_flag(state),
        value_flag('=s', 'Strategy', state, 'strategy', '--strategy='),
        value_flag('-S', 'Sign using GPG', state, 'gpg_sign', '--gpg-sign='),
      } },
      { title = 'Actions', mutation = true, requires = { 'no_sequence', 'resolved', 'selected', 'replay' }, actions = {
        { key = 'V', requires = { 'commit_index' }, label = 'Revert and commit', run = function() revert(false) end },
        { key = 'v', label = 'Revert changes without committing',
          run = function() revert(true) end },
      } },
    },
  }, ui)
end

local function commit_menu(ctx, ui)
  local state = { all = false, signoff = false, allow_empty = false,
    no_verify = false, verbose = false, reset_author = false }
  local function commit(extra)
    local args = { 'commit' }
    if state.all and not vim.tbl_contains(extra or {}, '--only') then args[#args + 1] = '--all' end
    if state.signoff then args[#args + 1] = '--signoff' end
    if state.allow_empty then args[#args + 1] = '--allow-empty' end
    if state.no_verify then args[#args + 1] = '--no-verify' end
    if state.verbose then args[#args + 1] = '--verbose' end
    if state.reset_author then args[#args + 1] = '--reset-author' end
    if state.author then args[#args + 1] = '--author=' .. state.author end
    if state.date then args[#args + 1] = '--date=' .. state.date end
    if state.gpg_sign then args[#args + 1] = '--gpg-sign=' .. state.gpg_sign end
    if state.reuse_message then args[#args + 1] = '--reuse-message=' .. state.reuse_message end
    if state.reedit_message then args[#args + 1] = '--reedit-message=' .. state.reedit_message end
    vim.list_extend(args, extra or {})
    git(args, ctx)
  end
  return show_submenu({ kind = 'commit', title = 'Commit',
    context = 'Repository: ' .. (ctx.work_tree or ''), groups = {
      { title = 'Arguments', actions = {
        flag('-a', 'Stage tracked changes', state, 'all', '--all'),
        flag('-e', 'Allow empty commit', state, 'allow_empty', '--allow-empty'),
        flag('-v', 'Verbose diff in editor', state, 'verbose', '--verbose'),
        flag('-n', 'Skip commit hooks', state, 'no_verify', '--no-verify'),
        flag('-R', 'Reset author', state, 'reset_author', '--reset-author'),
        value_flag('-A', 'Override author', state, 'author', '--author='),
        value_flag('-D', 'Override author date', state, 'date', '--date='),
        value_flag('-S', 'Sign using GPG', state, 'gpg_sign', '--gpg-sign='),
        flag('-s', 'Add Signed-off-by', state, 'signoff', '--signoff'),
        value_flag('-C', 'Reuse commit message', state, 'reuse_message', '--reuse-message=', nil, 'reedit_message'),
        value_flag('-c', 'Reedit commit message', state, 'reedit_message', '--reedit-message=', nil, 'reuse_message'),
      } },
      { title = 'Actions', mutation = true, requires = { 'resolved' }, actions = {
        { key = 'c', requires = { 'committable', 'commit_author' }, label = 'Commit staged changes', run = function() commit() end },
        { key = 'a', requires = { 'amend' }, label = 'Amend HEAD', run = function() commit({ '--amend' }) end },
        { key = 'e', requires = { 'amend' }, label = 'Amend without editing message',
          run = function() commit({ '--amend', '--no-edit' }) end },
        { key = 'w', requires = { 'amend', 'reword' }, label = ctx.commit and ('Reword ' .. short_target(ctx)) or 'Reword HEAD',
          run = function()
            if ctx.commit then existing_key(ctx, 'cw')
            else commit({ '--amend', '--only', '--edit' }) end
          end },
        { key = 'f', requires = { 'selected', 'committable', 'commit_author', 'fixup_message' },
          label = 'Create fixup commit', run = function()
          target_commit(ctx, function(ref) commit({ '--fixup=' .. ref }) end)
        end },
        { key = 'F', requires = { 'head', 'idle', 'tracked_changes' }, label = 'Find fixup target from changes', run = function()
          require('git.features.fixup_target').open(ctx)
        end },
        { key = 's', requires = { 'selected', 'committable', 'commit_author' }, label = 'Create squash commit', run = function()
          target_commit(ctx, function(ref) commit({ '--squash=' .. ref }) end)
        end },
      } },
    },
  }, ui)
end

local function target_ref(ctx, prompt, callback)
  local selected = availability.ref(ctx)
  if selected then callback(selected); return end
  availability.input(ctx, { prompt = prompt }, function(value)
    if value and vim.trim(value) ~= '' then callback(vim.trim(value)) end
  end)
end

local function branch_menu(ctx, ui)
  local chosen = ctx.branch
  local config = require('git.features.magit_config')
  local branch = config.branch(ctx)
  local state = { recurse_submodules = false }
  local actions = {
    { key = 'b', mutation = true, requires = { 'no_sequence', 'resolved', 'selected', 'checkout_source' },
      label = 'Check out branch or revision', run = function()
      if chosen then
        if ctx.panel == 'branch' and ctx.branch_kind ~= 'tags' and not state.recurse_submodules and not state.merge then
          existing_key(ctx, 'coo')
        else
          local args = { ctx.branch_kind == 'local_' and 'switch' or 'checkout' }
          if state.recurse_submodules then args[#args + 1] = '--recurse-submodules' end
          if state.merge then args[#args + 1] = '--merge' end
          if ctx.branch_kind == 'tags' then args[#args + 1] = '--detach' end
          args[#args + 1] = ctx.branch_kind == 'tags' and availability.ref(ctx) or chosen
          git(args, ctx)
        end
      else
        availability.input(ctx, { prompt = 'Branch or revision: ' }, function(ref)
          if ref and vim.trim(ref) ~= '' then
            local args = { 'checkout' }
            if state.recurse_submodules then args[#args + 1] = '--recurse-submodules' end
            if state.merge then args[#args + 1] = '--merge' end
            args[#args + 1] = vim.trim(ref)
            git(args, ctx)
          end
        end)
      end
    end },
    { key = 'c', mutation = true, requires = { 'no_sequence', 'resolved', 'selected' },
      label = 'Create and check out branch', run = function()
      availability.input(ctx, { prompt = 'New branch name: ' }, function(name)
        if name and name ~= '' then
          local args = { 'switch' }
          if state.recurse_submodules then args[#args + 1] = '--recurse-submodules' end
          if state.merge then args[#args + 1] = '--merge' end
          vim.list_extend(args, { '-c', name })
          if availability.ref(ctx) then args[#args + 1] = availability.ref(ctx) end
          git(args, ctx)
        end
      end)
    end },
    { key = 'n', mutation = true, requires = { 'startpoint', 'selected' }, label = 'Create branch without checkout', run = function()
      availability.input(ctx, { prompt = 'New branch name: ' }, function(name)
        if name and name ~= '' then
          git({ 'branch', name, availability.ref(ctx) or 'HEAD' }, ctx)
        end
      end)
    end },
    { key = 'l', mutation = true, requires = { 'no_sequence', 'resolved' }, label = 'Check out local branch', run = function()
      input(ctx, 'Local branch: ', function(branch)
        local args = { 'switch' }
        if state.recurse_submodules then args[#args + 1] = '--recurse-submodules' end
        if state.merge then args[#args + 1] = '--merge' end
        args[#args + 1] = branch
        git(args, ctx)
      end, chosen and ctx.branch_kind == 'local_' and chosen or nil)
    end },
    { key = 'v', mutation = true, requires = { 'no_sequence', 'resolved', 'previous_branch' }, label = 'Check out previous branch',
      run = function()
        local args = { 'switch' }
        if state.recurse_submodules then args[#args + 1] = '--recurse-submodules' end
        if state.merge then args[#args + 1] = '--merge' end
        args[#args + 1] = '-'
        git(args, ctx)
      end },
    { key = 'w', mutation = true, requires = { 'startpoint', 'selected', 'unoccupied_target' },
      label = 'Check out in new worktree', run = function()
      input(ctx, 'Worktree path: ', function(path)
        target_ref(ctx, 'Branch or revision: ', function(ref)
          git({ 'worktree', 'add', path, ref }, ctx)
        end)
      end)
    end },
    { key = 'W', mutation = true, requires = { 'head' }, label = 'Create branch in new worktree', run = function()
      input(ctx, 'Worktree path: ', function(path)
        input(ctx, 'New branch name: ', function(name)
          git({ 'worktree', 'add', '-b', name, path }, ctx)
        end)
      end)
    end },
    branch_config_action(ctx),
  }
  if chosen and ctx.branch_kind ~= 'tags' then
    vim.list_extend(actions, {
      { key = 'L', label = 'Log ' .. chosen, source_key = 'L', run = function() existing_key(ctx, 'L') end },
      { key = 'm', mutation = true, requires = { 'local_ref' }, label = 'Rename ' .. chosen, run = function()
        availability.input(ctx, { prompt = 'New branch name: ' }, function(name)
          if name and name ~= '' then git({ 'branch', '-m', chosen, name }, ctx) end
        end)
      end },
      { key = 'D', mutation = true, requires = { 'local_ref', 'unoccupied', 'deletable' },
        label = 'Delete ' .. chosen, run = function()
        if vim.fn.confirm('Delete branch ' .. chosen .. '?', '&Yes\n&No', 2) == 1 then
          git({ 'branch', '-d', chosen }, ctx)
        end
      end },
      { key = 'X', mutation = true, requires = { 'local_ref', 'unoccupied' }, label = 'Reset branch to ref', run = function()
        input(ctx, 'Reset ' .. chosen .. ' to ref: ', function(ref)
          if vim.fn.confirm('Move branch ' .. chosen .. ' to ' .. ref .. '?',
            '&Yes\n&No', 2) == 1 then
            git({ 'branch', '-f', chosen, ref }, ctx)
          end
        end)
      end },
    })
  end
  if ctx.panel == 'status' or ctx.panel == 'log' or ctx.panel == 'branch' then
    vim.list_extend(actions, {
      { key = 's', mutation = true, requires = { 'spin' },
        label = 'Spin off outgoing commits', source_key = 'bs', run = function() existing_key(ctx, 'bs') end },
      { key = 'S', mutation = true, requires = { 'spin' },
        label = 'Spin out outgoing commits', source_key = 'bS', run = function() existing_key(ctx, 'bS') end },
    })
  end
  local groups = config.branch_groups(ctx, branch)
  vim.list_extend(groups, {
    { title = 'Arguments', actions = {
      flag('-m', 'Merge local modifications', state, 'merge', '--merge'),
      flag('-r', 'Recurse submodules when checking out', state,
        'recurse_submodules', '--recurse-submodules'),
    } },
    { title = 'Actions', actions = actions },
  })
  return show_submenu({ kind = 'branch', title = 'Branch',
    context = ctx.commit and commit_label(ctx)
      or (chosen or branch) and ('Ref: ' .. (chosen or branch)) or 'No local branch selected',
    groups = groups,
  }, ui)
end

local function merge_menu(ctx, ui)
  if active_operation(ctx) == 'merge' then
    return show_submenu({ kind = 'merge', title = 'Merge',
      requires = { availability.operation('merge') }, mutation = true,
      context = 'Merge in progress', groups = {
        { title = 'Actions', mutation = true, actions = {
          { key = 'm', label = 'Continue merge', requires = { 'resolved' },
            run = function() git({ 'merge', '--continue' }, ctx) end },
          { key = 'a', label = 'Abort merge',
            run = function() git({ 'merge', '--abort' }, ctx) end },
        } },
      },
    }, ui)
  end
  local state = { ff_only = false, no_ff = false, no_commit = false, squash = false }
  local function merge(extra)
    target_ref(ctx, 'Merge branch or revision: ', function(ref)
      local args = { 'merge' }
      if state.ff_only then args[#args + 1] = '--ff-only' end
      if state.no_ff then args[#args + 1] = '--no-ff' end
      if state.no_commit then args[#args + 1] = '--no-commit' end
      if state.squash then args[#args + 1] = '--squash' end
      if state.strategy then args[#args + 1] = '--strategy=' .. state.strategy end
      if state.strategy_option then args[#args + 1] = '--strategy-option=' .. state.strategy_option end
      if state.ignore_space_change then args[#args + 1] = '-Xignore-space-change' end
      if state.ignore_all_space then args[#args + 1] = '-Xignore-all-space' end
      if state.diff_algorithm then args[#args + 1] = '-Xdiff-algorithm=' .. state.diff_algorithm end
      if state.gpg_sign then args[#args + 1] = '--gpg-sign=' .. state.gpg_sign end
      if state.signoff then args[#args + 1] = '--signoff' end
      if extra then vim.list_extend(args, extra) end
      args[#args + 1] = ref
      git(args, ctx)
    end)
  end
  return show_submenu({ kind = 'merge', title = 'Merge',
    context = ctx.commit and commit_label(ctx)
      or ctx.branch and ('Ref: ' .. ctx.branch) or 'Choose a branch on execution',
    groups = {
      { title = 'Arguments', actions = {
        exclusive_flag('-f', 'Fast-forward only', state, 'ff_only', 'no_ff', '--ff-only'),
        exclusive_flag('-n', 'Create merge commit', state, 'no_ff', 'ff_only', '--no-ff'),
        flag('-c', 'Do not commit', state, 'no_commit', '--no-commit'),
        flag('-q', 'Squash', state, 'squash', '--squash'),
        value_flag('-s', 'Strategy', state, 'strategy', '--strategy='),
        value_flag('-X', 'Strategy option', state, 'strategy_option', '--strategy-option='),
        flag('-b', 'Ignore whitespace changes', state, 'ignore_space_change', '-Xignore-space-change'),
        flag('-w', 'Ignore all whitespace', state, 'ignore_all_space', '-Xignore-all-space'),
        value_flag('-A', 'Diff algorithm', state, 'diff_algorithm', '-Xdiff-algorithm='),
        value_flag('-S', 'Sign using GPG', state, 'gpg_sign', '--gpg-sign='),
        flag('=s', 'Add Signed-off-by', state, 'signoff', '--signoff'),
      } },
      { title = 'Actions', mutation = true, requires = { 'no_sequence', 'resolved', 'selected', 'merge_arguments' }, actions = {
        { key = 'm', label = 'Merge ' .. short_target(ctx), run = function() merge() end },
        { key = 'e', label = 'Merge and edit message',
          run = function() merge({ '--edit' }) end },
        { key = 'n', label = 'Merge without commit',
          run = function() merge({ '--no-commit' }) end },
        { key = 's', label = 'Squash merge',
          run = function() merge({ '--squash' }) end },
      } },
    },
  }, ui)
end

local function rebase_menu(ctx, ui)
  if active_operation(ctx) == 'rebase' then
    return show_submenu({ kind = 'rebase', title = 'Rebase',
      requires = { availability.operation('rebase') }, mutation = true,
      context = 'Rebase in progress', groups = {
        { title = 'Actions', actions = {
          { key = 'r', label = 'Continue rebase', requires = { 'resolved' },
            run = function() git({ 'rebase', '--continue' }, ctx) end },
          { key = 's', label = 'Skip current commit',
            run = function() git({ 'rebase', '--skip' }, ctx) end },
          { key = 'e', label = 'Edit todo list', requires = { 'edit_todo' },
            run = function() git({ 'rebase', '--edit-todo' }, ctx) end },
          { key = 'a', label = 'Abort rebase',
            run = function() git({ 'rebase', '--abort' }, ctx) end },
        } },
      },
    }, ui)
  end
  local state = { autostash = false, rebase_merges = false, autosquash = false,
    interactive = false, update_refs = false, keep_empty = false }
  local function rebase(extra, target)
    local function execute(ref)
      local args = { 'rebase' }
      if state.autostash then args[#args + 1] = '--autostash' end
      if state.rebase_merges and not state.merge_mode then args[#args + 1] = '--rebase-merges' end
      if state.autosquash then args[#args + 1] = '--autosquash' end
      if state.interactive then args[#args + 1] = '--interactive' end
      if state.update_refs then args[#args + 1] = '--update-refs' end
      if state.keep_empty then args[#args + 1] = '--keep-empty' end
      if state.force_rebase then args[#args + 1] = '--force-rebase' end
      if state.committer_date then args[#args + 1] = '--committer-date-is-author-date' end
      if state.ignore_date then args[#args + 1] = '--ignore-date' end
      if state.no_verify then args[#args + 1] = '--no-verify' end
      if state.merge_mode then args[#args + 1] = '--rebase-merges=' .. state.merge_mode end
      if state.strategy then args[#args + 1] = '--strategy=' .. state.strategy end
      if state.strategy_option then args[#args + 1] = '--strategy-option=' .. state.strategy_option end
      if state.diff_algorithm then args[#args + 1] = '-Xdiff-algorithm=' .. state.diff_algorithm end
      if state.exec then args[#args + 1] = '--exec=' .. state.exec end
      if state.gpg_sign then args[#args + 1] = '--gpg-sign=' .. state.gpg_sign end
      if state.signoff then args[#args + 1] = '--signoff' end
      if extra then vim.list_extend(args, extra) end
      args[#args + 1] = ref
      git(args, ctx)
    end
    if target then execute(target)
    else target_ref(ctx, 'Rebase onto branch or revision: ', execute) end
  end
  local groups = {
      { title = 'Arguments', actions = {
        flag('-k', 'Keep empty commits', state, 'keep_empty', '--keep-empty'),
        flag('-r', 'Preserve merge topology', state, 'rebase_merges', '--rebase-merges'),
        value_flag('=r', 'Rebase merges mode', state, 'merge_mode', '--rebase-merges=', function(value)
          if vim.tbl_contains({ 'no-rebase-cousins', 'rebase-cousins' }, value) then return true end
          vim.notify('Rebase merges mode must be no-rebase-cousins or rebase-cousins',
            vim.log.levels.WARN)
          return false
        end),
        flag('-u', 'Update refs', state, 'update_refs', '--update-refs'),
        value_flag('-s', 'Strategy', state, 'strategy', '--strategy='),
        value_flag('-X', 'Strategy option', state, 'strategy_option', '--strategy-option='),
        value_flag('=X', 'Diff algorithm', state, 'diff_algorithm', '-Xdiff-algorithm='),
        flag('-f', 'Force rebase', state, 'force_rebase', '--force-rebase'),
        flag('-d', 'Use author date as committer date', state, 'committer_date', '--committer-date-is-author-date'),
        flag('-t', 'Use current time as author date', state, 'ignore_date', '--ignore-date'),
        flag('-a', 'Autosquash', state, 'autosquash', '--autosquash'),
        flag('-A', 'Autostash', state, 'autostash', '--autostash'),
        flag('-i', 'Interactive', state, 'interactive', '--interactive'),
        flag('-h', 'Disable hooks', state, 'no_verify', '--no-verify'),
        value_flag('-x', 'Run command after commits', state, 'exec', '--exec='),
        value_flag('-S', 'Sign using GPG', state, 'gpg_sign', '--gpg-sign='),
        flag('=s', 'Add Signed-off-by', state, 'signoff', '--signoff'),
      } },
      { title = 'Actions', mutation = true, requires = { 'head', 'no_sequence', 'resolved', 'selected', 'rebase_clean' }, actions = {
        { key = 'r', label = 'Rebase onto ' .. short_target(ctx), run = function() rebase() end },
        { key = 'p', requires = { 'push_remote', 'rebase_push' }, label = 'Rebase onto push remote', run = function()
          local remotes = branch_remotes(ctx)
          if remotes and remotes.push_remote then
            rebase(nil, remotes.push_remote == '.' and remotes.branch
              or remotes.push_remote .. '/' .. remotes.branch)
          end
        end },
        { key = 'u', requires = { 'upstream', 'rebase_upstream' }, label = 'Rebase onto upstream', run = function()
          local remotes = branch_remotes(ctx)
          if remotes and remotes.upstream and remotes.merge_ref then
            local branch = remotes.merge_ref:gsub('^refs/heads/', '')
            rebase(nil, remotes.upstream == '.' and branch or remotes.upstream .. '/' .. branch)
          end
        end },
        { key = 'e', label = 'Rebase onto another ref', run = function()
          input(ctx, 'Rebase onto: ', function(ref) rebase(nil, ref) end)
        end },
        { key = 'i', label = 'Interactive rebase',
          run = function() rebase({ '--interactive' }) end },
      } },
    }
  if ctx.commit and (ctx.panel == 'status' or ctx.panel == 'log') then
    groups[#groups + 1] = { title = 'Commit actions', mutation = true, requires = { 'head', 'idle', 'resolved', 'rewrite', 'nonmerge' }, actions = {
      { key = 'w', label = 'Reword commit and descendants',
        source_key = 'cw', run = function() existing_key(ctx, 'cw') end },
      { key = 'd', label = 'Drop commit and rewrite descendants',
        source_key = 'X', run = function() existing_key(ctx, 'X') end },
    } }
  end
  return show_submenu({ kind = 'rebase', title = 'Rebase',
    context = ctx.commit and commit_label(ctx)
      or ctx.branch and ('Ref: ' .. ctx.branch) or 'Choose an upstream on execution',
    groups = groups,
  }, ui)
end

local function push_menu(ctx, ui)
  local selected = selected_transfer(ctx)
  local state = { upstream = false, force_lease = false, tags = false,
    follow_tags = false, dry_run = false, no_verify = false }
  local function push(extra)
    local args = { 'push' }
    if state.upstream then args[#args + 1] = '--set-upstream' end
    if state.force_lease then args[#args + 1] = '--force-with-lease' end
    if state.force then args[#args + 1] = '--force' end
    if state.tags then args[#args + 1] = '--tags' end
    if state.follow_tags then args[#args + 1] = '--follow-tags' end
    if state.dry_run then args[#args + 1] = '--dry-run' end
    if state.no_verify then args[#args + 1] = '--no-verify' end
    if state.push_options then
      for option in state.push_options:gmatch('[^,]+') do
        args[#args + 1] = '--push-option=' .. vim.trim(option)
      end
    end
    if extra then vim.list_extend(args, extra) end
    git(args, ctx)
  end
  local spec = { kind = 'push', title = 'Push',
    context = selected and (ctx.commit and commit_label(ctx) or 'Ref: ' .. ctx.branch)
      or 'Repository: ' .. (ctx.work_tree or ''), groups = {
      { title = 'Arguments', actions = {
        exclusive_flag('-f', 'Force with lease', state, 'force_lease', 'force', '--force-with-lease'),
        exclusive_flag('-F', 'Force', state, 'force', 'force_lease', '--force'),
        flag('-h', 'Skip hooks', state, 'no_verify', '--no-verify'),
        flag('-n', 'Dry run', state, 'dry_run', '--dry-run'),
        flag('-u', 'Set upstream', state, 'upstream', '--set-upstream'),
        flag('-T', 'Push all tags', state, 'tags', '--tags'),
        flag('-t', 'Follow annotated tags', state, 'follow_tags', '--follow-tags'),
        value_flag('-o', 'Push options (comma separated)', state, 'push_options', '--push-option='),
      } },
      { title = 'Actions', actions = {
        { key = 'v', requires = { 'head', 'range_diff' },
          label = 'Review range-diff before push', run = function() require('git.features.range_diff').open(ctx.work_tree) end },
        branch_config_action(ctx),
        { key = 'p', mutation = true, requires = { 'head', 'push_remote' }, label = 'Push current to push remote', run = function()
          local remotes = branch_remotes(ctx)
          if remotes and remotes.push_remote then
            push({ remotes.push_remote, 'HEAD:refs/heads/' .. remotes.branch })
          end
        end },
        { key = 'u', mutation = true, requires = { 'head', 'upstream' }, label = 'Push current to upstream', run = function()
          local remotes = branch_remotes(ctx)
          if remotes and remotes.upstream and remotes.merge_ref then
            push({ remotes.upstream, 'HEAD:' .. remotes.merge_ref })
          end
        end },
        { key = 'e', mutation = true, requires = { 'head' }, label = 'Push current elsewhere', run = function()
          input(ctx, 'Remote: ', function(remote)
            input(ctx, 'Destination branch: ', function(branch)
              push({ remote, 'HEAD:' .. branch })
            end)
          end)
        end },
        { key = 'o', mutation = true, label = 'Push another ref', run = function()
          input(ctx, 'Source ref: ', function(source)
            input(ctx, 'Remote: ', function(remote)
              input(ctx, 'Destination ref: ', function(target)
                push({ remote, source .. ':' .. target })
              end)
            end)
          end, ctx.branch or ctx.commit)
        end },
        { key = 'r', mutation = true, label = 'Push explicit refspec', run = function()
          input(ctx, 'Remote: ', function(remote)
            input(ctx, 'Refspec: ', function(refspec) push({ remote, refspec }) end)
          end)
        end },
        { key = 'm', mutation = true, requires = { 'head' }, label = 'Push matching branches', run = function()
          input(ctx, 'Remote: ', function(remote) push({ remote, ':' }) end)
        end },
        { key = 't', mutation = true, requires = { 'tags' }, label = 'Push all tags', run = function()
          input(ctx, 'Remote: ', function(remote) push({ remote, '--tags' }) end)
        end },
        { key = 'T', mutation = true, requires = { 'tags' }, label = 'Push one tag', run = function()
          input(ctx, 'Remote: ', function(remote)
            input(ctx, 'Tag: ', function(tag) push({ remote, 'refs/tags/' .. tag }) end,
              ctx.branch_kind == 'tags' and ctx.branch or nil)
          end)
        end },
      } },
    },
  }
  if selected then
    table.insert(spec.groups[2].actions, 1, {
      key = 's', mutation = true, requires = { 'selected', function(s)
        local current = selected_transfer(ctx)
        return current and (not current.push_remote or s:remote(current.push_remote)), 'Selected push remote no longer exists'
      end }, label = function()
        local current = selected_transfer(ctx)
        local remote = current and current.push_remote
        return 'Push ' .. short_target(ctx) .. (remote and (' to ' .. remote) or ' to remote')
      end,
      run = function()
        local selected = selected_transfer(ctx)
        if not selected then return end
        local function send(remote)
          if selected.kind == 'commit' then
            input(ctx, 'Destination branch: ', function(branch)
              push({ remote, selected.source .. ':refs/heads/' .. branch })
            end)
          else
            push({ remote, selected.source .. ':' .. selected.destination })
          end
        end
        if selected.push_remote then send(selected.push_remote)
        else input(ctx, 'Remote: ', send) end
      end,
    })
  end
  return show_submenu(spec, ui)
end

local function pull_menu(ctx, ui)
  local selected = selected_transfer(ctx)
  local state = { rebase = false, ff_only = false, autostash = false, tags = false }
  local function pull(extra)
    local args = { 'pull' }
    if state.rebase_mode then args[#args + 1] = '--rebase=' .. state.rebase_mode
    elseif state.rebase then args[#args + 1] = '--rebase' end
    if state.ff_only then args[#args + 1] = '--ff-only' end
    if state.autostash then args[#args + 1] = '--autostash' end
    if state.tags then args[#args + 1] = '--tags' end
    if state.force then args[#args + 1] = '--force' end
    if extra then vim.list_extend(args, extra) end
    git(args, ctx)
  end
  local spec = { kind = 'pull', title = 'Pull',
    context = selected and (selected.kind == 'local_' or selected.kind == 'remote')
      and ('Ref: ' .. ctx.branch) or 'Repository: ' .. (ctx.work_tree or ''), groups = {
      { title = 'Arguments', actions = {
        exclusive_flag('-f', 'Fast-forward only', state, 'ff_only', 'rebase', '--ff-only'),
        exclusive_flag('-r', 'Rebase after fetching', state, 'rebase', 'ff_only', '--rebase'),
        value_flag('=r', 'Rebase mode', state, 'rebase_mode', '--rebase=', function(value)
          if vim.tbl_contains({ 'true', 'false', 'merges', 'interactive' }, value) then return true end
          vim.notify('Rebase mode must be true, false, merges, or interactive', vim.log.levels.WARN)
          return false
        end),
        flag('-A', 'Autostash', state, 'autostash', '--autostash'),
        flag('-t', 'Fetch tags', state, 'tags', '--tags'),
        flag('-F', 'Force', state, 'force', '--force'),
      } },
      { title = 'Actions', actions = {
        branch_config_action(ctx),
        { key = 'p', mutation = true, requires = { 'no_sequence', 'resolved', 'pull_clean', 'push_remote' },
          label = 'Pull from push remote', run = function()
          local remotes = branch_remotes(ctx)
          if remotes and remotes.push_remote then
            pull({ remotes.push_remote, remotes.branch })
          end
        end },
        { key = 'u', mutation = true, requires = { 'no_sequence', 'resolved', 'pull_clean', 'upstream' },
          label = 'Pull from upstream', run = function()
          local remotes = branch_remotes(ctx)
          if remotes and remotes.upstream and remotes.merge_ref then
            pull({ remotes.upstream, remotes.merge_ref })
          end
        end },
        { key = 'e', mutation = true, requires = { 'no_sequence', 'resolved', 'pull_clean' },
          label = 'Pull from elsewhere', run = function()
          input(ctx, 'Remote: ', function(remote)
            input(ctx, 'Branch: ', function(branch) pull({ remote, branch }) end)
          end)
        end },
      } },
    },
  }
  if selected and selected.kind ~= 'tag' and selected.kind ~= 'commit' then
    table.insert(spec.groups[2].actions, 1, {
      key = 's', mutation = true, requires = { 'no_sequence', 'resolved', 'pull_clean', 'selected', function(s)
        local current = selected_transfer(ctx)
        return current and s:remote(current.pull_remote), 'Selected upstream remote no longer exists'
      end }, label = (selected.kind == 'local_' and 'Pull upstream of '
        or 'Pull ') .. short_target(ctx) .. ' into HEAD',
      enabled = function()
        local current = selected_transfer(ctx)
        return current and current.pull_remote ~= nil and current.pull_ref ~= nil,
          'Selected branch has no configured upstream'
      end,
      reason = 'Selected branch has no configured upstream',
      run = function()
        local current = selected_transfer(ctx)
        if current and current.pull_remote and current.pull_ref then pull({ current.pull_remote, current.pull_ref }) end
      end,
    })
  end
  return show_submenu(spec, ui)
end

local function fetch_menu(ctx, ui)
  local state = { all = false, prune = false, tags = false }
  local function fetch(extra)
    local args = { 'fetch' }
    if state.all then args[#args + 1] = '--all' end
    if state.prune then args[#args + 1] = '--prune' end
    if state.tags then args[#args + 1] = '--tags' end
    if state.unshallow then args[#args + 1] = '--unshallow' end
    if state.force then args[#args + 1] = '--force' end
    if extra then vim.list_extend(args, extra) end
    git(args, ctx)
  end
  return show_submenu({ kind = 'fetch', title = 'Fetch', requires = { 'fetch_arguments' },
    context = 'Repository: ' .. (ctx.work_tree or ''), groups = {
      { title = 'Arguments', actions = {
        flag('-a', 'Fetch all remotes', state, 'all', '--all'),
        flag('-p', 'Prune removed refs', state, 'prune', '--prune'),
        flag('-t', 'Fetch tags', state, 'tags', '--tags'),
        vim.tbl_extend('force', flag('-u', 'Fetch full history', state, 'unshallow', '--unshallow'), { requires = { 'unshallow_option' } }),
        flag('-F', 'Force', state, 'force', '--force'),
      } },
      { title = 'Actions', actions = {
        branch_config_action(ctx),
        { key = 'f', mutation = true, requires = { 'default_remote' }, label = 'Fetch default remote', run = function() fetch() end },
        { key = 'p', mutation = true, requires = { 'push_remote', 'fetch_one' }, label = 'Fetch push remote', run = function()
          local remotes = branch_remotes(ctx)
          if remotes and remotes.push_remote then fetch({ remotes.push_remote })
          end
        end },
        { key = 'u', mutation = true, requires = { 'upstream_remote', 'fetch_one' }, label = 'Fetch upstream remote', run = function()
          local remotes = branch_remotes(ctx)
          if remotes and remotes.upstream then fetch({ remotes.upstream })
          end
        end },
        { key = 'a', mutation = true, requires = { 'remotes' }, label = 'Fetch all remotes', run = function() fetch({ '--all' }) end },
        { key = 'e', mutation = true, requires = { 'fetch_one' }, label = 'Fetch elsewhere', run = function()
          input(ctx, 'Remote: ', function(remote) fetch({ remote }) end)
        end },
        { key = 'o', mutation = true, requires = { 'fetch_one' }, label = 'Fetch another branch', run = function()
          input(ctx, 'Remote: ', function(remote)
            input(ctx, 'Branch: ', function(branch) fetch({ remote, branch }) end)
          end)
        end },
        { key = 'r', mutation = true, requires = { 'fetch_one' }, label = 'Fetch explicit refspec', run = function()
          input(ctx, 'Remote: ', function(remote)
            input(ctx, 'Refspec: ', function(refspec) fetch({ remote, refspec }) end)
          end)
        end },
        { key = 'm', mutation = true, requires = { 'default_remote' }, label = 'Fetch submodules', run = function()
          fetch({ '--recurse-submodules' })
        end },
      } },
    },
  }, ui)
end

function M.open(bufnr, selection)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local ctx = context(bufnr)
  if not ctx then
    return false, 'Action menu is available in status, log, branch, reflog, and worktree panels'
  end
  local function show_root(spec)
    return menu.show(availability.bind(spec, ctx), { availability = availability.new(ctx), action_context = ctx })
  end
  if selection and selection.first and selection.last then
    ctx.source_selections = {}
    for row = selection.first, selection.last do
      ctx.source_selections[#ctx.source_selections + 1] = { row = row,
        value = require('git.features.action_selection').capture(bufnr, row) }
    end
  end
  if selection then
    local diff = require('git.features.commit_diff')
    local count = #selection.values
    if selection.kind == 'commits' then
      ctx.commits = selection.values
      ctx.commit = selection.values[1]
      return show_root({ kind = 'root', context = ('%d selected commits'):format(count),
        groups = { { title = 'Selected commits', actions = {
          { key = 'd', label = 'Diff selected range', run = function()
            local ok, err = diff.open_selected(ctx.work_tree, ctx.commits)
            if not ok then vim.notify(err, vim.log.levels.WARN) end
          end },
          { key = 'A', requires = { availability.start_or_resume({ 'cherry_pick', 'revert' }) },
            label = 'Cherry-pick…', run = function(ui) cherry_menu(ctx, ui) end },
          { key = 'V', requires = { availability.start_or_resume({ 'cherry_pick', 'revert' }) },
            label = 'Revert…', run = function(ui) revert_menu(ctx, ui) end },
          { key = '!', label = 'Custom Git commands…', run = function(ui)
            require('git.features.custom_commands').open(ctx, ui, show_submenu)
          end },
          { key = 'W', label = 'Create selected commit patches…', run = function(ui)
            require('git.features.magit_workflows').patch(ctx, ui, show_submenu)
          end },
        } } },
      })
    end
    if selection.kind == 'stashes' then
      return show_root({ kind = 'root', context = ('%d selected stashes'):format(count),
        groups = { { title = 'Selected stashes', actions = {
          { key = 'd', label = 'Compare stash snapshots', run = function()
            local ok, err = diff.open_stashes(ctx.work_tree, selection.values)
            if not ok then vim.notify(err, vim.log.levels.WARN) end
          end },
        } } },
      })
    end
    ctx.paths = selection.values
    ctx.section = selection.section
    local function update(action)
      local renderer = require('git.features.status_renderer')
      local ok, err
      if action == 'discard' then
        ok, err = renderer.discard_range(bufnr, selection.first, selection.last)
      else
        ok, err = renderer.change_index_range(bufnr, selection.first, selection.last, action)
      end
      if not ok then vim.notify(err, vim.log.levels.WARN); return end
      require('git.features.status').refresh_buffer(bufnr)
      utils.fire_git_changed({ work_tree = ctx.work_tree })
    end
    return show_root({ kind = 'root', context = ('%d selected %s files'):format(count, ctx.section),
      groups = { { title = 'Selected files', actions = {
        { key = '!', label = 'Custom Git commands…', run = function(ui)
          require('git.features.custom_commands').open(ctx, ui, show_submenu)
        end },
        { key = 'W', label = 'Save selected diff…', run = function(ui)
          require('git.features.magit_workflows').patch(ctx, ui, show_submenu)
        end },
        { key = 'd', label = 'Diff selected files', run = function()
          local ok, err = diff.open_paths(ctx.work_tree, ctx.paths, ctx.section)
          if not ok then vim.notify(err, vim.log.levels.WARN) end
        end },
        { key = 's', mutation = true, label = ctx.section == 'staged' and 'Unstage selected files'
          or ctx.section == 'conflicted' and 'Accept selected conflicts'
          or 'Stage selected files', run = function() update('toggle') end },
        { key = 'u', mutation = true, label = 'Unstage selected files', enabled = ctx.section == 'staged',
          reason = 'Select staged files', run = function() update('unstage') end },
        { key = 'D', mutation = true, label = 'Discard selected files', run = function() update('discard') end },
      } } },
    })
  end
  if ctx.commit then
    local subject = git_value(ctx, { 'show', '-s', '--format=%s', ctx.commit })
    ctx.commit_label = 'Commit: ' .. ctx.commit:sub(1, 12)
      .. (subject and (' (' .. subject .. ')') or '')
  end
  local groups = {}
  if ctx.panel == 'status' and ctx.path then
    local file_actions = {
      { key = 's', mutation = true,
        label = ctx.section == 'staged' and 'Unstage' or ctx.section == 'conflicted' and 'Accept conflict' or 'Stage', source_key = 's',
        run = function() existing_key(ctx, 's') end },
      { key = 'u', mutation = true, enabled = ctx.section == 'staged', reason = 'Select staged changes',
        label = 'Unstage', source_key = 'u', run = function() existing_key(ctx, 'u') end },
      { key = 'D', mutation = true, label = 'Discard', source_key = 'X', run = function() existing_key(ctx, 'X') end },
    }
    if ctx.section == 'staged' then
      file_actions[#file_actions + 1] = { key = 'a', mutation = true, requires = { 'selected', 'patch_source' },
        label = 'Apply to worktree',
        run = function() apply_patch(ctx, false) end }
    end
    groups[#groups + 1] = { title = 'File: ' .. ctx.path, actions = file_actions }
  elseif ctx.panel == 'status' and ctx.commit then
    groups[#groups + 1] = { title = commit_label(ctx), actions = {
      { key = 'a', mutation = true, requires = { 'selected', 'patch_source' }, label = 'Apply to worktree',
        run = function() apply_patch(ctx, false) end },
    } }
  elseif ctx.panel == 'log' and ctx.commit then
    groups[#groups + 1] = { title = commit_label(ctx), actions = {
      { key = 'o', label = 'Inspect commit', source_key = '<CR>', run = function() existing_key(ctx, '<CR>') end },
      { key = 'cw', mutation = true, requires = { 'head', 'idle', 'resolved', 'rewrite', 'nonmerge' },
        label = 'Reword commit', source_key = 'cw', run = function() existing_key(ctx, 'cw') end },
    } }
  elseif ctx.panel == 'branch' and ctx.branch then
    groups[#groups + 1] = { title = 'Ref: ' .. ctx.branch, actions = {
      { key = 'L', label = 'Log ' .. short_target(ctx), source_key = 'L', run = function() existing_key(ctx, 'L') end },
    } }
  elseif ctx.panel == 'reflog' and ctx.commit then
    groups[#groups + 1] = { title = 'Reflog: ' .. ctx.reflog_selector, actions = {
      { key = 'o', label = 'Inspect destination', source_key = '<CR>', run = function() existing_key(ctx, '<CR>') end },
      { key = 'b', mutation = true, requires = { 'selected' },
        label = 'Create rescue branch', source_key = 'B', run = function() existing_key(ctx, 'B') end },
      { key = 'Y', label = 'Copy reflog selector', source_key = 'y', run = function() existing_key(ctx, 'y') end },
    } }
  elseif ctx.panel == 'worktree' and ctx.target_worktree then
    groups[#groups + 1] = { title = 'Worktree: ' .. ctx.target_worktree, actions = {
      { key = 'o', label = 'Open worktree', source_key = '<CR>', run = function() existing_key(ctx, '<CR>') end },
      { key = 's', mutation = true, requires = { 'sync_worktree' }, label = 'Sync primary to selected HEAD',
        source_key = 'gs', run = function() existing_key(ctx, 'gs') end },
      { key = 'D', mutation = true, requires = { 'linked_worktree' },
        label = 'Remove worktree', source_key = 'X', run = function() existing_key(ctx, 'X') end },
      { key = 'R', label = 'Refresh', source_key = 'R', run = function() existing_key(ctx, 'R') end },
    } }
  end
  local operations = {}
  operations[#operations + 1] = { key = 'H', label = 'History…', run = function(ui)
    show_submenu({ kind = 'history', title = 'History', context = 'Repository: ' .. (ctx.work_tree or ''), groups = {
      { title = 'Recovery', actions = {
        { key = 'u', mutation = true, requires = { 'head', 'idle', 'resolved', 'undo' },
          label = 'Undo last logical operation', run = function()
          require('git.features.history_undo').open(ctx.work_tree, false)
        end },
        { key = 'r', mutation = true, requires = { 'head', 'idle', 'resolved', 'redo' }, label = 'Redo operation', run = function()
          require('git.features.history_undo').open(ctx.work_tree, true)
        end },
        { key = 'l', label = 'Inspect reflog', run = function() git({ 'reflog' }, ctx) end },
      } },
      { title = 'Edit history', actions = {
        { key = 'b', label = 'Toggle old rebase base (excluded)', enabled = ctx.commit ~= nil, run = function()
          require('git.features.rebase_plan').mark(ctx.work_tree, ctx.commit)
        end },
        { key = 'p', requires = { 'head', 'idle', 'resolved' }, label = 'Edit rebase plan', run = function()
          require('git.features.rebase_plan').open(ctx)
        end },
        { key = 'f', requires = { 'head', 'idle', 'resolved', 'tracked_changes' }, label = 'Find fixup target', run = function()
          require('git.features.fixup_target').open(ctx)
        end },
        { key = '<Tab>', requires = { 'head', 'idle', 'resolved', 'collection' },
          label = 'Collect patch and split commit', run = function()
          require('git.features.patch_collection').open(ctx)
        end },
      } },
    } }, ui)
  end }
  if ctx.commit then
    operations[#operations + 1] = { key = '<Tab>', requires = { 'head', 'idle', 'resolved', 'collection' },
      label = 'Collect patch and split commit', run = function()
      require('git.features.patch_collection').open(ctx)
    end }
  end
  if ctx.panel == 'status' or ctx.panel == 'log' or ctx.panel == 'reflog' then
    vim.list_extend(operations, {
      { key = 'A', requires = { availability.start_or_resume({ 'cherry_pick', 'revert' }) },
        label = 'Cherry-pick…', run = function(ui) cherry_menu(ctx, ui) end },
      { key = 'V', requires = { availability.start_or_resume({ 'cherry_pick', 'revert' }) }, label = 'Revert…',
        run = function(ui) revert_menu(ctx, ui) end },
    })
  end
  if ctx.commit or ctx.branch or ctx.target_head or (ctx.panel == 'status' and ctx.path) then
    operations[#operations + 1] = {
      key = 'v', label = 'Apply variants…',
      run = function(ui) apply_variants_menu(ctx, ui) end,
    }
  end
  if ctx.panel == 'status' then
    operations[#operations + 1] = {
      key = 'c', label = 'Commit…', run = function(ui) commit_menu(ctx, ui) end,
    }
  end
  if ctx.panel == 'status' or ctx.panel == 'log' or ctx.panel == 'branch' then
    operations[#operations + 1] = {
      key = 'b', label = 'Branch…', run = function(ui) branch_menu(ctx, ui) end,
    }
    operations[#operations + 1] = {
      key = 'r', requires = { 'head', availability.start_or_resume({ 'rebase' }) },
        label = 'Rebase…', run = function(ui) rebase_menu(ctx, ui) end,
    }
  end
  if ctx.panel == 'status' or ctx.panel == 'branch' then
    vim.list_extend(operations, {
      { key = 'm', requires = { availability.start_or_resume({ 'merge' }) },
        label = 'Merge…', run = function(ui) merge_menu(ctx, ui) end },
      { key = 'P', label = 'Push…', run = function(ui) push_menu(ctx, ui) end },
      { key = 'F', aliases = { 'p' }, label = 'Pull…',
        run = function(ui) pull_menu(ctx, ui) end },
      { key = 'f', label = 'Fetch…', run = function(ui) fetch_menu(ctx, ui) end },
    })
  end
  operations[#operations + 1] = { key = '!', label = 'Custom Git commands…', run = function(ui)
    require('git.features.custom_commands').open(ctx, ui, show_submenu)
  end }
  local github_context = require('git.features.github_actions').context(bufnr)
  operations[#operations + 1] = { key = 'N', label = 'GitHub / pull requests…', run = function()
    require('git.features.github_actions').open(github_context)
  end }
  operations[#operations + 1] = { key = 'I', label = 'Repository setup…', run = function()
    require('git.features.repository_init').open({ base = ctx.work_tree })
  end }
  if ctx.panel == 'status' or ctx.panel == 'tree' then
    operations[#operations + 1] = { key = '=t', label = 'Changed files tree', run = function()
      require('git.features.status_tree').open({ work_tree = ctx.work_tree })
    end }
  end
  vim.list_extend(operations, require('git.features.magit_workflows').root(ctx, { show = show_submenu }))
  vim.list_extend(operations, require('git.features.magit_extra_actions').root(ctx, {
    git = git, show = show_submenu,
  }))
  groups[#groups + 1] = { title = 'Operations', actions = operations }
  return show_root({ kind = 'root', columns = 2, groups = groups })
end

function M.attach(bufnr)
  require('git.features.github_actions').attach(bufnr)
  vim.keymap.set('n', '<Space><Space>', function()
    local ok, err = M.open(bufnr)
    if not ok then vim.notify(err, vim.log.levels.WARN) end
  end, { buffer = bufnr, nowait = true, silent = true, desc = 'Git action menu' })
  if vim.bo[bufnr].filetype ~= 'gitstatus' then
    vim.keymap.set('n', '<Tab>', function()
      local ctx = context(bufnr)
      if ctx then require('git.features.patch_collection').open(ctx) end
    end, { buffer = bufnr, silent = true, desc = 'Collect patch in a dedicated tab' })
  end
  local panel = ({ gitstatus = 'status', gitlog = 'log',
    gitreflog = 'reflog' })[vim.bo[bufnr].filetype]
  if panel then
    vim.keymap.set('x', '<Space><Space>', function()
      local diff = require('git.features.commit_diff')
      local first, last = diff.visual_rows()
      local selection, err
      if panel == 'status' then
        selection, err = diff.status_items(bufnr, first, last)
      else
        local commits = {}
        for row = first, last do
          local commit
          if panel == 'reflog' then
            local entry = require('git.features.reflog').entry_at(bufnr, row)
            commit = entry and entry.hash
          else
            local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ''
            commit = line:match('^(%x%x%x%x%x%x%x+)')
          end
          if not commit then err = 'Select only commit rows'; break end
          if commits[#commits] ~= commit then commits[#commits + 1] = commit end
        end
        if not err then selection = { kind = 'commits', values = commits, first = first, last = last } end
      end
      if not selection then vim.notify(err, vim.log.levels.WARN); return end
      local ok, open_err = M.open(bufnr, selection)
      if not ok then vim.notify(open_err, vim.log.levels.WARN) end
    end, { buffer = bufnr, nowait = true, silent = true, desc = 'Git actions for selection' })
  end
end

return M

local M = {}
local options = require('git.features.transient_options')
local toggle, option_arg, choices = options.flag, options.value, options.choices

local function prompt(label, callback, default)
  vim.ui.input({ prompt = label, default = default }, function(value)
    if value and vim.trim(value) ~= '' then callback(vim.trim(value)) end
  end)
end

local function confirm(label, callback)
  if vim.fn.confirm(label, '&Yes\n&No', 2) == 1 then callback() end
end

local function selected_ref(ctx, label, callback)
  if ctx.commit then callback(ctx.commit)
  elseif ctx.branch then callback(ctx.branch)
  else prompt(label, callback) end
end

local function selected_context(ctx)
  if ctx.commit then return ctx.commit_label or ('Commit: ' .. ctx.commit:sub(1, 12)) end
  if ctx.branch then return 'Ref: ' .. ctx.branch end
  return nil
end

local function short_target(ctx)
  if ctx.commit then return ctx.commit:sub(1, 7) end
  if ctx.branch then
    return vim.fn.strchars(ctx.branch) > 18
      and vim.fn.strcharpart(ctx.branch, 0, 17) .. '…' or ctx.branch
  end
  return 'ref'
end

local function selected_path(ctx, label, callback)
  if ctx.path then callback(ctx.path) else prompt(label, callback) end
end

local function stash_ref(callback)
  prompt('Stash ref: ', callback, 'stash@{0}')
end

local function at_source(ctx, callback)
  if vim.api.nvim_win_is_valid(ctx.source_win) then
    vim.api.nvim_set_current_win(ctx.source_win)
  end
  return callback()
end

function M.root(ctx, helpers)
  local git, show = helpers.git, helpers.show

  local function diff_menu(ui)
    local state = { stat = false, word = false, space = false }
    local function diff_flags(show_commit)
      local args = {}
      if state.stat then args[#args + 1] = '--stat' end
      if state.word then args[#args + 1] = '--word-diff' end
      if state.space then args[#args + 1] = '--ignore-space-change' end
      if state.ignore_all_space then args[#args + 1] = '--ignore-all-space' end
      if state.irreversible then args[#args + 1] = '--irreversible-delete' end
      if state.ignore_submodules then args[#args + 1] = '--ignore-submodules=' .. state.ignore_submodules end
      if state.context then args[#args + 1] = '-U' .. state.context end
      if state.function_context then args[#args + 1] = '--function-context' end
      if state.algorithm then args[#args + 1] = '--diff-algorithm=' .. state.algorithm end
      if state.diff_merges then args[#args + 1] = '--diff-merges=' .. state.diff_merges end
      if state.renames and not state.rename_threshold then args[#args + 1] = '-M' end
      if state.rename_threshold then args[#args + 1] = '-M' .. state.rename_threshold end
      if state.copies and not state.copy_threshold then args[#args + 1] = '-C' end
      if state.copy_threshold then args[#args + 1] = '-C' .. state.copy_threshold end
      if state.copies_harder then args[#args + 1] = '--find-copies-harder' end
      if state.reverse then args[#args + 1] = '-R' end
      if state.color_moved then args[#args + 1] = '--color-moved=' .. state.color_moved end
      if state.color_moved_ws then args[#args + 1] = '--color-moved-ws=' .. state.color_moved_ws end
      if state.no_ext_diff then args[#args + 1] = '--no-ext-diff' end
      if show_commit and state.signature then args[#args + 1] = '--show-signature' end
      return args
    end
    local function diff(base, target, path)
      local args = { 'diff' }
      vim.list_extend(args, diff_flags(false))
      if base then args[#args + 1] = base end
      if target then args[#args + 1] = target end
      if state.path or path then vim.list_extend(args, { '--', state.path or path }) end
      git(args, ctx)
    end
    local signature = toggle('=S', 'Show signature', state, 'signature', '--show-signature')
    signature.enabled = ctx.commit ~= nil
    signature.reason = 'Select a commit to show its signature'
    show({ kind = 'diff', title = 'Diff', context = selected_context(ctx), groups = {
      { title = 'Limit arguments', actions = {
        option_arg('--', 'Limit to file', state, 'path', '-- '),
        option_arg('-i', 'Ignore submodules', state, 'ignore_submodules', '--ignore-submodules=',
          choices({ 'none', 'untracked', 'dirty', 'all' }, 'Ignore submodules')),
        toggle('-b', 'Ignore whitespace changes', state, 'space', '--ignore-space-change'),
        toggle('-w', 'Ignore all whitespace', state, 'ignore_all_space', '--ignore-all-space'),
        toggle('-D', 'Omit preimage for deletes', state, 'irreversible', '--irreversible-delete'),
        toggle('=W', 'Word diff', state, 'word', '--word-diff'),
      } },
      { title = 'Context arguments', actions = {
        option_arg('-U', 'Context lines', state, 'context', '-U', function(value)
          if value:match('^%d+$') then return true end
          vim.notify('Context lines must be a nonnegative integer', vim.log.levels.WARN)
          return false
        end),
        toggle('-W', 'Show surrounding functions', state, 'function_context', '--function-context'),
      } },
      { title = 'Tune arguments', actions = {
        option_arg('-A', 'Diff algorithm', state, 'algorithm', '--diff-algorithm=',
          choices({ 'default', 'minimal', 'patience', 'histogram' }, 'Diff algorithm')),
        option_arg('-X', 'Diff merges', state, 'diff_merges', '--diff-merges=',
          choices({ 'off', 'first-parent', 'combined', 'dense-combined' }, 'Diff merges')),
        toggle('-M', 'Detect renames', state, 'renames', '-M'),
        option_arg('=M', 'Rename similarity', state, 'rename_threshold', '-M'),
        toggle('-C', 'Detect copies', state, 'copies', '-C'),
        option_arg('=C', 'Copy similarity', state, 'copy_threshold', '-C'),
        toggle('-H', 'Find copies from unmodified files', state, 'copies_harder', '--find-copies-harder'),
        toggle('-R', 'Reverse sides', state, 'reverse', '-R'),
        option_arg('-m', 'Color moved lines', state, 'color_moved', '--color-moved=',
          choices({ 'default', 'plain', 'blocks', 'zebra', 'dimmed-zebra' }, 'Color moved')),
        option_arg('=w', 'Moved whitespace handling', state, 'color_moved_ws', '--color-moved-ws=',
          choices({ 'allow-indentation-change', 'ignore-space-at-eol', 'ignore-space-change',
            'ignore-all-space', 'no' }, 'Moved whitespace handling')),
        toggle('-x', 'Disallow external diff drivers', state, 'no_ext_diff', '--no-ext-diff'),
        toggle('-s', 'Show statistics', state, 'stat', '--stat'),
        signature,
      } },
      { title = 'Diff', actions = {
        { key = 'd', label = 'Selected item', run = function()
          if ctx.commit then
            if state.signature then
              local args = { 'show', '--format=fuller' }
              vim.list_extend(args, diff_flags(true))
              args[#args + 1] = ctx.commit
              if state.path then vim.list_extend(args, { '--', state.path }) end
              git(args, ctx)
              return
            end
            local result = vim.system({ 'git', '-C', ctx.work_tree, 'rev-list',
              '--parents', '-n1', ctx.commit }, { text = true }):wait()
            if result.code == 0 and #vim.split(vim.trim(result.stdout), ' ', { plain = true }) == 1 then
              local args = { 'show', '--root', '--format=' }
              vim.list_extend(args, diff_flags(true))
              args[#args + 1] = ctx.commit
              if state.path then vim.list_extend(args, { '--', state.path }) end
              git(args, ctx)
            else diff(ctx.commit .. '^', ctx.commit) end
          elseif ctx.path then diff(nil, nil, ctx.path)
          elseif ctx.branch then diff('HEAD', ctx.branch)
          else diff('HEAD') end
        end },
        { key = 'u', label = 'Unstaged', run = function() diff() end },
        { key = 's', label = 'Staged', run = function()
          local args = { 'diff', '--cached' }
          vim.list_extend(args, diff_flags(false))
          if state.path then vim.list_extend(args, { '--', state.path }) end
          git(args, ctx)
        end },
        { key = 'r', label = 'Revision range', run = function()
          prompt('Diff revisions (A..B): ', function(value) diff(value) end)
        end },
      } },
    } }, ui)
  end

  local function log_menu(ui)
    local state = { count = '256', all = false }
    local function value_arg(key, label, name, argument, validate)
      return option_arg(key, label, state, name, argument, validate)
    end
    local function switch_arg(key, label, name, argument, aliases)
      local action = toggle(key, label, state, name, argument)
      action.aliases = aliases
      return action
    end
    local function count_valid(value)
      if value:match('^%d+$') then return true end
      vim.notify('Commit limit must be a nonnegative integer', vim.log.levels.WARN)
      return false
    end
    local function order_valid(value)
      if vim.tbl_contains({ 'topo', 'author-date', 'date' }, value) then return true end
      vim.notify('Order must be topo, author-date, or date', vim.log.levels.WARN)
      return false
    end
    local order_arg = value_arg('-o', 'Order commits by', 'order', '', order_valid)
    order_arg.label = function()
      return 'Order commits by (--' .. (state.order or '[topo|author-date|date]') .. '-order)'
    end
    local function log(ref)
      if state.line and state.path then
        vim.notify('Line evolution cannot be combined with a file limit', vim.log.levels.WARN)
        return
      end
      if state.follow and not state.path then
        vim.notify('Follow renames requires a single file limit (--)', vim.log.levels.WARN)
        return
      end
      local args = {}
      if state.count then args[#args + 1] = '--max-count=' .. state.count end
      if state.author then args[#args + 1] = '--author=' .. state.author end
      if state.grep then args[#args + 1] = '--grep=' .. state.grep end
      if state.changes then vim.list_extend(args, { '-G', state.changes }) end
      if state.occurrences then vim.list_extend(args, { '-S', state.occurrences }) end
      if state.line then vim.list_extend(args, { '-L', state.line }) end
      if state.since then args[#args + 1] = '--since=' .. state.since end
      if state.until_date then args[#args + 1] = '--until=' .. state.until_date end
      if state.all then args[#args + 1] = '--all' end
      if state.first_parent then args[#args + 1] = '--first-parent' end
      if state.no_merges then args[#args + 1] = '--no-merges' end
      if state.invert_grep then args[#args + 1] = '--invert-grep' end
      if state.simplify then args[#args + 1] = '--simplify-by-decoration' end
      if state.follow then args[#args + 1] = '--follow' end
      if state.reverse then args[#args + 1] = '--reverse' end
      if state.order then args[#args + 1] = '--' .. state.order .. '-order' end
      if state.reflog then args[#args + 1] = '--reflog' end
      if state.graph then args[#args + 1] = '--graph' end
      if state.color then args[#args + 1] = '--color' end
      if state.decorate then args[#args + 1] = '--decorate' end
      if state.signature then args[#args + 1] = '--show-signature' end
      if ref then args[#args + 1] = ref end
      if state.path then vim.list_extend(args, { '--', state.path }) end
      local quoted = {}
      for _, arg in ipairs(args) do quoted[#quoted + 1] = vim.fn.shellescape(arg) end
      at_source(ctx, function()
        require('git.features.log').open({ args = table.concat(quoted, ' '), menu_flags = true })
      end)
    end
    show({ kind = 'log', title = 'Log', groups = {
      { title = 'Commit Limiting', actions = {
        value_arg('-n', 'Limit number of commits', 'count', '--max-count=', count_valid),
        value_arg('-A', 'Limit to author', 'author', '--author='),
        value_arg('-F', 'Search messages', 'grep', '--grep='),
        value_arg('-G', 'Search changes', 'changes', '-G'),
        value_arg('-S', 'Search occurrences', 'occurrences', '-S'),
        value_arg('-L', 'Trace line evolution', 'line', '-L'),
        value_arg('-s', 'Limit to commits since', 'since', '--since='),
        value_arg('-u', 'Limit to commits until', 'until_date', '--until='),
        switch_arg('=m', 'Omit merges', 'no_merges', '--no-merges', { '-m' }),
        switch_arg('=p', 'First parent', 'first_parent', '--first-parent', { '-p' }),
        switch_arg('-i', 'Invert search messages', 'invert_grep', '--invert-grep'),
        switch_arg('-a', 'All refs', 'all', '--all'),
      } },
      { title = 'History Simplification', actions = {
        switch_arg('-D', 'Simplify by decoration', 'simplify', '--simplify-by-decoration'),
        value_arg('--', 'Limit to files', 'path', '-- '),
        switch_arg('-f', 'Follow renames when showing single-file log', 'follow', '--follow'),
      } },
      { title = 'Commit Ordering', actions = {
        switch_arg('-r', 'Reverse order', 'reverse', '--reverse'),
        order_arg,
        switch_arg('=R', 'List reflog', 'reflog', '--reflog'),
      } },
      { title = 'Formatting', actions = {
        switch_arg('-g', 'Show graph', 'graph', '--graph'),
        switch_arg('-c', 'Show graph in color', 'color', '--color'),
        switch_arg('-d', 'Show refnames', 'decorate', '--decorate'),
        switch_arg('=S', 'Show signatures', 'signature', '--show-signature'),
      } },
      { title = 'Log', actions = {
        { key = 'l', label = 'Current branch', run = function() log() end },
        { key = 'h', label = 'HEAD', run = function() log('HEAD') end },
        { key = 'b', label = 'All branches', run = function()
          state.all = true; log()
        end },
        { key = 'o', label = 'Other ref', run = function()
          prompt('Log ref: ', log, ctx.branch)
        end },
        { key = 'r', label = 'Reflog', run = function()
          at_source(ctx, function() vim.cmd('Greflog') end)
        end },
      } },
    } }, ui)
  end

  local function reset_menu(ui)
    local function reset(mode)
      selected_ref(ctx, 'Reset to commit/ref: ', function(ref)
        local function run() git({ 'reset', '--' .. mode, ref }, ctx) end
        if mode == 'hard' then confirm('Discard index and worktree changes?', run)
        else run() end
      end)
    end
    show({ kind = 'reset', title = 'Reset', context = selected_context(ctx), groups = {
      { title = 'Reset HEAD to ' .. short_target(ctx), actions = {
        { key = 's', label = 'Soft: HEAD only', run = function() reset('soft') end },
        { key = 'm', label = 'Mixed: HEAD and index', run = function() reset('mixed') end },
        { key = 'h', label = 'Hard: HEAD, index, worktree', run = function() reset('hard') end },
        { key = 'k', label = 'Keep worktree changes', run = function() reset('keep') end },
        { key = 'i', label = 'Index only', run = function()
          selected_ref(ctx, 'Restore index from ref: ', function(ref)
            git({ 'reset', ref, '--', '.' }, ctx)
          end)
        end },
        { key = 'w', label = 'Worktree only', run = function()
          selected_ref(ctx, 'Restore worktree from ref: ', function(ref)
            confirm('Replace tracked worktree files?', function()
              git({ 'restore', '--source=' .. ref, '--worktree', '--', '.' }, ctx)
            end)
          end)
        end },
      } },
      { title = 'File', actions = {
        { key = 'u', label = 'Unstage file', run = function()
          selected_path(ctx, 'Path to unstage: ', function(path)
            git({ 'reset', 'HEAD', '--', path }, ctx)
          end)
        end },
        { key = 'f', label = 'Restore file from ref', run = function()
          selected_path(ctx, 'Path to restore: ', function(path)
            selected_ref(ctx, 'Restore file from ref: ', function(ref)
              confirm('Replace index and worktree file ' .. path .. '?', function()
                git({ 'restore', '--source=' .. ref, '--staged', '--worktree', '--', path }, ctx)
              end)
            end)
          end)
        end },
      } },
    } }, ui)
  end

  local function stash_menu(ui)
    local state = { untracked = false, all = false }
    local function push(extra)
      local args = { 'stash', 'push' }
      if extra ~= '--staged' then
        if state.all then args[#args + 1] = '--all'
        elseif state.untracked then args[#args + 1] = '--include-untracked' end
      end
      if extra then args[#args + 1] = extra end
      git(args, ctx)
    end
    show({ kind = 'stash', title = 'Stash', groups = {
      { title = 'Arguments', actions = {
        toggle('-u', 'Include untracked', state, 'untracked', '--include-untracked'),
        toggle('-a', 'Include ignored too', state, 'all', '--all'),
      } },
      { title = 'Push arguments', actions = {
        option_arg('--', 'Limit to file', state, 'path', '-- '),
        toggle('-k', 'Keep index', state, 'keep_index', '--keep-index', 'no_keep_index'),
        toggle('-K', "Don't keep index", state, 'no_keep_index', '--no-keep-index', 'keep_index'),
      } },
      { title = 'Save', actions = {
        { key = 'z', label = 'Index and worktree', run = function() push() end },
        { key = 'i', label = 'Staged changes', run = function() push('--staged') end },
        { key = 'w', label = 'Worktree changes', run = function() push('--keep-index') end },
        { key = 'P', label = 'Push selected changes', run = function()
          local args = { 'stash', 'push' }
          if state.all then args[#args + 1] = '--all'
          elseif state.untracked then args[#args + 1] = '--include-untracked' end
          if state.keep_index then args[#args + 1] = '--keep-index' end
          if state.no_keep_index then args[#args + 1] = '--no-keep-index' end
          if state.path then vim.list_extend(args, { '--', state.path }) end
          git(args, ctx)
        end },
      } },
      { title = 'Use', actions = {
        { key = 'p', label = 'Pop stash', run = function()
          stash_ref(function(ref) git({ 'stash', 'pop', ref }, ctx) end)
        end },
        { key = 'a', label = 'Apply stash', run = function()
          stash_ref(function(ref) git({ 'stash', 'apply', ref }, ctx) end)
        end },
        { key = 'k', aliases = { 'd' }, label = 'Drop stash', run = function()
          stash_ref(function(ref)
            confirm('Drop ' .. ref .. '?', function() git({ 'stash', 'drop', ref }, ctx) end)
          end)
        end },
        { key = 'v', label = 'Show stash patch', run = function()
          stash_ref(function(ref) git({ 'stash', 'show', '-p', ref }, ctx) end)
        end },
        { key = 'l', label = 'List stashes', run = function()
          at_source(ctx, function() vim.cmd('Gstash') end)
        end },
        { key = 'b', label = 'Create branch from stash', run = function()
          stash_ref(function(ref)
            prompt('New branch name: ', function(name)
              git({ 'stash', 'branch', name, ref }, ctx)
            end)
          end)
        end },
      } },
    } }, ui)
  end

  local function tag_menu(ui)
    local state = { annotated = false, signed = false, force = false }
    show({ kind = 'tag', title = 'Tag', context = selected_context(ctx), groups = {
      { title = 'Arguments', actions = {
        toggle('-f', 'Force update', state, 'force', '--force'),
        toggle('-e', 'Edit message', state, 'edit', '--edit'),
        toggle('-a', 'Annotated', state, 'annotated', '--annotate'),
        toggle('-s', 'Signed', state, 'signed', '--sign'),
        option_arg('-u', 'Sign as', state, 'sign_as', '--local-user='),
      } },
      { title = 'Actions', actions = {
        { key = 't', label = 'Create tag at ' .. short_target(ctx), run = function()
          prompt('New tag name: ', function(name)
            local args = { 'tag' }
            if state.force then args[#args + 1] = '-f' end
            if state.signed or state.sign_as then args[#args + 1] = '-s'
            elseif state.annotated or state.edit then args[#args + 1] = '-a' end
            if state.sign_as then args[#args + 1] = '--local-user=' .. state.sign_as end
            if state.edit then args[#args + 1] = '--edit' end
            local function create(message)
              if message then vim.list_extend(args, { '-m', message }) end
              args[#args + 1] = name
              args[#args + 1] = ctx.commit or ctx.branch or 'HEAD'
              git(args, ctx)
            end
            if (state.annotated or state.signed or state.sign_as) and not state.edit then
              prompt('Tag message: ', create, name)
            else create() end
          end)
        end },
        { key = 'k', aliases = { 'x' }, label = 'Delete tag', run = function()
          prompt('Tag to delete: ', function(name)
            confirm('Delete tag ' .. name .. '?', function() git({ 'tag', '-d', name }, ctx) end)
          end, ctx.branch_kind == 'tags' and ctx.branch or nil)
        end },
        { key = 'l', label = 'List tags', run = function() git({ 'tag', '-n' }, ctx) end },
        { key = 'r', label = 'Create release tag', run = function()
          prompt('Release tag name: ', function(name)
            prompt('Release message: ', function(message)
              git({ 'tag', '-a', '-m', message, name, ctx.commit or 'HEAD' }, ctx)
            end, name)
          end)
        end },
      } },
    } }, ui)
  end

  local function bisect_menu(ui)
    local active = require('git.features.operation').inspect(ctx.work_tree)
    local running = active and active.kind == 'bisect'
    local actions
    if running then
      actions = {
        { key = 'b', label = 'Mark bad', run = function() git({ 'bisect', 'bad' }, ctx) end },
        { key = 'g', label = 'Mark good', run = function() git({ 'bisect', 'good' }, ctx) end },
        { key = 's', label = 'Skip commit', run = function() git({ 'bisect', 'skip' }, ctx) end },
        { key = 'r', label = 'Reset bisect', run = function() git({ 'bisect', 'reset' }, ctx) end },
        { key = 'S', label = 'Run test command', run = function()
          prompt('Test command and arguments: ', function(command)
            local args = { 'bisect', 'run' }
            vim.list_extend(args, require('git.commands').argv(command))
            git(args, ctx)
          end)
        end },
      }
    else
      actions = { { key = 'B', label = 'Start with bad and good commits', run = function()
        prompt('Bad commit: ', function(bad)
          prompt('Good commit: ', function(good)
            git({ 'bisect', 'start', bad, good }, ctx)
          end)
        end, ctx.commit or 'HEAD')
      end } }
    end
    show({ kind = 'bisect', title = 'Bisect',
      context = not running and selected_context(ctx) or nil, groups = {
      { title = running and 'Bisect in progress' or 'Bisect', actions = actions },
    } }, ui)
  end

  local function worktree_menu(ui)
    show({ kind = 'worktree', title = 'Worktree', context = ctx.target_worktree, groups = {
      { title = 'Actions', actions = {
        { key = 'b', label = 'Add existing branch in worktree', run = function()
          prompt('Worktree path: ', function(path)
            selected_ref(ctx, 'Branch: ', function(ref)
              git({ 'worktree', 'add', path, ref }, ctx)
            end)
          end)
        end },
        { key = 'c', label = 'Create branch and worktree', run = function()
          prompt('Worktree path: ', function(path)
            prompt('New branch: ', function(branch)
              git({ 'worktree', 'add', '-b', branch, path }, ctx)
            end)
          end)
        end },
        { key = 'm', label = 'Move worktree', run = function()
          local function move(old)
            prompt('New worktree path: ', function(new)
              git({ 'worktree', 'move', old, new }, ctx)
            end)
          end
          if ctx.target_worktree then move(ctx.target_worktree)
          else prompt('Current worktree path: ', move) end
        end },
        { key = 'k', label = 'Remove worktree', run = function()
          local function remove(path)
            confirm('Remove worktree ' .. path .. '?', function()
              git({ 'worktree', 'remove', path }, ctx)
            end)
          end
          if ctx.target_worktree then remove(ctx.target_worktree)
          else prompt('Worktree path to remove: ', remove) end
        end },
        { key = 'g', label = 'List worktrees', run = function()
          if ctx.target_worktree then
            require('git.features.worktree').open_worktree_path(ctx.target_worktree)
          else at_source(ctx, function() vim.cmd('Gworktree') end) end
        end },
      } },
    } }, ui)
  end

  local function remote_menu(ui)
    local state = { fetch_after_add = false }
    show({ kind = 'remote', title = 'Remote', groups = {
      { title = 'Arguments for add', actions = {
        toggle('-f', 'Fetch after add', state, 'fetch_after_add', '-f'),
      } },
      { title = 'Actions', actions = {
        { key = 'a', label = 'Add remote', run = function()
          prompt('Remote name: ', function(name)
            prompt('Remote URL: ', function(url)
              local args = { 'remote', 'add' }
              if state.fetch_after_add then args[#args + 1] = '-f' end
              vim.list_extend(args, { name, url })
              git(args, ctx)
            end)
          end)
        end },
        { key = 'r', label = 'Rename remote', run = function()
          prompt('Current remote name: ', function(old)
            prompt('New remote name: ', function(new)
              git({ 'remote', 'rename', old, new }, ctx)
            end)
          end)
        end },
        { key = 'x', label = 'Remove remote', run = function()
          prompt('Remote to remove: ', function(name)
            confirm('Remove remote ' .. name .. '?', function()
              git({ 'remote', 'remove', name }, ctx)
            end)
          end)
        end },
        { key = 'p', label = 'Prune stale refs', run = function()
          prompt('Remote to prune: ', function(name) git({ 'remote', 'prune', name }, ctx) end)
        end },
        { key = 'l', label = 'List remotes', run = function() git({ 'remote', '-v' }, ctx) end },
      } },
    } }, ui)
  end

  local function ignore_menu(ui)
    show({ kind = 'ignore', title = 'Ignore', groups = {
      { title = 'Add ignore pattern', actions = {
        { key = 't', label = 'Repository .gitignore', run = function()
          prompt('Ignore pattern: ', function(pattern)
            if pattern:find('[\r\n]') then return end
            vim.fn.writefile({ pattern }, ctx.work_tree .. '/.gitignore', 'a')
            require('git.utils').fire_fugitive_changed({ work_tree = ctx.work_tree })
          end, ctx.path)
        end },
        { key = 'p', label = 'Private repository exclude', run = function()
          prompt('Ignore pattern: ', function(pattern)
            if pattern:find('[\r\n]') then return end
            local result = vim.system({ 'git', '-C', ctx.work_tree, 'rev-parse',
              '--git-path', 'info/exclude' }, { text = true }):wait()
            if result.code ~= 0 then return end
            local path = vim.trim(result.stdout)
            if not vim.startswith(path, '/') then path = ctx.work_tree .. '/' .. path end
            vim.fn.mkdir(vim.fs.dirname(path), 'p')
            vim.fn.writefile({ pattern }, path, 'a')
            require('git.utils').fire_fugitive_changed({ work_tree = ctx.work_tree })
          end, ctx.path)
        end },
      } },
    } }, ui)
  end

  local function yank_menu(ui)
    if not ctx.commit then return end
    local function yank(args)
      local argv = { 'git', '-C', ctx.work_tree }
      vim.list_extend(argv, args)
      local result = vim.system(argv, { text = true }):wait()
      if result.code ~= 0 then
        vim.notify(vim.trim(result.stderr or 'Could not read commit'), vim.log.levels.ERROR)
        return
      end
      vim.fn.setreg('"', vim.trim(result.stdout))
      vim.notify('Copied commit information')
    end
    show({ kind = 'yank', title = 'Copy commit', context = selected_context(ctx), groups = {
      { title = 'Copy', actions = {
        { key = 'Y', label = 'Full hash', run = function() vim.fn.setreg('"', ctx.commit) end },
        { key = 's', label = 'Subject', run = function()
          yank({ 'show', '-s', '--format=%s', ctx.commit })
        end },
        { key = 'm', label = 'Message', run = function()
          yank({ 'show', '-s', '--format=%B', ctx.commit })
        end },
        { key = 'a', label = 'Author', run = function()
          yank({ 'show', '-s', '--format=%an <%ae>', ctx.commit })
        end },
        { key = 'd', label = 'Patch', run = function()
          yank({ 'show', '--format=', ctx.commit })
        end },
      } },
    } }, ui)
  end

  local function refs_menu(ui)
    local function refs(filter)
      at_source(ctx, function()
        vim.cmd('Gbranch')
        if filter then
          local mapping = vim.fn.maparg(filter, 'n', false, true)
          if type(mapping.callback) == 'function' then mapping.callback() end
        end
      end)
    end
    show({ kind = 'refs', title = 'References', groups = {
      { title = 'Show', actions = {
        { key = 'y', label = 'All refs', run = function() refs('ga') end },
        { key = 'c', label = 'Local branches', run = function() refs('gl') end },
        { key = 'r', label = 'Remote branches', run = function() refs('gr') end },
        { key = 't', label = 'Tags', run = function() refs('gt') end },
      } },
    } }, ui)
  end

  local function submodule_menu(ui)
    local state = { recursive = true }
    local function module_path(label, callback)
      selected_path(ctx, label, callback)
    end
    local function update_flags()
      local args = {}
      if state.force then args[#args + 1] = '--force' end
      if state.recursive then args[#args + 1] = '--recursive' end
      if state.no_fetch then args[#args + 1] = '--no-fetch' end
      if state.remote_tip then args[#args + 1] = '--remote' end
      if state.checkout then args[#args + 1] = '--checkout' end
      if state.rebase then args[#args + 1] = '--rebase' end
      if state.merge then args[#args + 1] = '--merge' end
      return args
    end
    local function mode(key, label, name, argument)
      return toggle(key, label, state, name, argument, { 'checkout', 'rebase', 'merge' })
    end
    show({ kind = 'submodule', title = 'Submodule', groups = {
      { title = 'Arguments', actions = {
        toggle('-f', 'Force', state, 'force', '--force'),
        toggle('-r', 'Recursive', state, 'recursive', '--recursive'),
        toggle('-N', 'Do not fetch', state, 'no_fetch', '--no-fetch'),
        mode('-C', 'Checkout tip', 'checkout', '--checkout'),
        mode('-R', 'Rebase onto tip', 'rebase', '--rebase'),
        mode('-M', 'Merge tip', 'merge', '--merge'),
        toggle('-U', 'Use upstream tip', state, 'remote_tip', '--remote'),
      } },
      { title = 'Actions', actions = {
        { key = 'a', label = 'Add submodule', run = function()
          prompt('Submodule URL: ', function(url)
            prompt('Submodule path: ', function(path)
              local args = { 'submodule', 'add' }
              if state.force then args[#args + 1] = '--force' end
              vim.list_extend(args, { url, path })
              git(args, ctx)
            end)
          end)
        end },
        { key = 'p', label = 'Initialize and populate', run = function()
          module_path('Submodule path: ', function(path)
            local args = { 'submodule', 'update', '--init' }
            if state.recursive then args[#args + 1] = '--recursive' end
            vim.list_extend(args, { '--', path })
            git(args, ctx)
          end)
        end },
        { key = 'r', label = 'Register submodule URL', run = function()
          module_path('Submodule path: ', function(path)
            git({ 'submodule', 'init', '--', path }, ctx)
          end)
        end },
        { key = 'u', label = 'Update recursively', run = function()
          local args = { 'submodule', 'update', '--init' }
          vim.list_extend(args, update_flags())
          git(args, ctx)
        end },
        { key = 's', label = 'Synchronize URLs', run = function()
          local args = { 'submodule', 'sync' }
          if state.recursive then args[#args + 1] = '--recursive' end
          git(args, ctx)
        end },
        { key = 'd', label = 'Deinitialize', run = function()
          module_path('Submodule path: ', function(path)
            confirm('Deinitialize submodule ' .. path .. '?', function()
              local args = { 'submodule', 'deinit' }
              if state.force then args[#args + 1] = '--force' end
              vim.list_extend(args, { '--', path })
              git(args, ctx)
            end)
          end)
        end },
        { key = 'l', label = 'List submodules', run = function()
          git({ 'submodule', 'status', '--recursive' }, ctx)
        end },
        { key = 'f', label = 'Fetch submodules', run = function()
          git({ 'fetch', '--recurse-submodules' }, ctx)
        end },
      } },
    } }, ui)
  end

  local function clone_menu(ui)
    local state = {}
    local function clone(flags)
      prompt('Repository URL or path: ', function(source)
        prompt('Clone destination path: ', function(destination)
          local args = { 'clone' }
          for _, item in ipairs({ { 'single_branch', '--single-branch' },
            { 'no_tags', '--no-tags' }, { 'submodules', '--recurse-submodules' },
            { 'no_local', '--no-local' }, { 'shared', '--shared' },
            { 'no_hardlinks', '--no-hardlinks' } }) do
            if state[item[1]] then args[#args + 1] = item[2] end
          end
          for _, item in ipairs({ { 'origin', '--origin=' }, { 'branch', '--branch=' },
            { 'filter', '--filter=' }, { 'git_dir', '--separate-git-dir=' },
            { 'template', '--template=' } }) do
            if state[item[1]] then args[#args + 1] = item[2] .. state[item[1]] end
          end
          vim.list_extend(args, flags)
          vim.list_extend(args, { source, vim.fn.fnamemodify(destination, ':p') })
          git(args, ctx)
        end)
      end)
    end
    show({ kind = 'clone', title = 'Clone', groups = {
      { title = 'Fetch arguments', actions = {
        toggle('-B', 'Clone a single branch', state, 'single_branch', '--single-branch'),
        toggle('-n', 'Do not clone tags', state, 'no_tags', '--no-tags'),
        toggle('-S', 'Clone submodules', state, 'submodules', '--recurse-submodules'),
        toggle('-l', 'Do not optimize locally', state, 'no_local', '--no-local'),
      } },
      { title = 'Setup arguments', actions = {
        option_arg('-o', 'Remote name', state, 'origin', '--origin='),
        option_arg('-b', 'HEAD branch', state, 'branch', '--branch='),
        option_arg('-f', 'Filter objects', state, 'filter', '--filter='),
        option_arg('-g', 'Separate Git directory', state, 'git_dir', '--separate-git-dir='),
        option_arg('-t', 'Template directory', state, 'template', '--template='),
      } },
      { title = 'Local sharing arguments', actions = {
        toggle('-s', 'Share objects', state, 'shared', '--shared'),
        toggle('-h', 'Do not use hardlinks', state, 'no_hardlinks', '--no-hardlinks'),
      } },
      { title = 'Clone repository', actions = {
        { key = 'C', label = 'Regular', run = function() clone({}) end },
        { key = 's', label = 'Shallow', run = function() clone({ '--depth=1' }) end },
        { key = 'b', label = 'Bare', run = function() clone({ '--bare' }) end },
        { key = 'm', label = 'Mirror', run = function() clone({ '--mirror' }) end },
        { key = '>', label = 'Sparse', run = function()
          clone({ '--filter=blob:none', '--sparse' })
        end },
        { key = 'd', label = 'Shallow since date', run = function()
          prompt('Shallow since date: ', function(date)
            clone({ '--shallow-since=' .. date })
          end)
        end },
        { key = 'e', label = 'Shallow excluding ref', run = function()
          prompt('Exclude commits reachable from ref: ', function(ref)
            clone({ '--shallow-exclude=' .. ref })
          end)
        end },
      } },
    } }, ui)
  end

  local entries = {}
  local function add(key, label, run, panels)
    if not panels or panels[ctx.panel] then
      entries[#entries + 1] = { key = key, label = label, run = run }
    end
  end
  local repository = { status = true }
  local references = { status = true, branch = true, worktree = true }
  add('C', 'Clone…', clone_menu, repository)
  add('d', 'Diff…', diff_menu)
  add('l', 'Log…', log_menu)
  add('X', 'Reset…', reset_menu, { status = true, log = true, reflog = true })
  add('z', 'Stash…', stash_menu, repository)
  add('t', 'Tag…', tag_menu, { status = true, log = true, branch = true, reflog = true })
  add('B', 'Bisect…', bisect_menu, { status = true, log = true, reflog = true })
  add('Z', 'Worktree…', worktree_menu, references)
  add('M', 'Remote…', remote_menu, references)
  add('i', 'Ignore…', ignore_menu, repository)
  add('o', 'Submodule…', submodule_menu, repository)
  add('y', 'References…', refs_menu)
  if ctx.commit and ctx.panel ~= 'reflog' then
    entries[#entries + 1] = { key = 'Y', label = 'Copy commit…', run = yank_menu }
  end
  return entries
end

return M

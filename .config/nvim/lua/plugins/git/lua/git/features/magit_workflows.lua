-- Less frequent Magit-style workflows share the existing transient UI.
local M = {}
local workflow = require('git.features.workflow')
local options = require('git.features.transient_options')
local flag, value = options.flag, options.value
local function prompt(label, cb, default)
  vim.ui.input({ prompt = label, default = default }, function(text)
    if text and text:find('%S') then cb(text) end
  end)
end
local function confirm(label, cb)
  vim.ui.select({ 'Proceed', 'Cancel' }, { prompt = label }, function(choice) if choice == 'Proceed' then cb() end end)
end
local function words(text)
  local ok, args = pcall(require('git.commands').argv, text)
  if not ok then vim.notify(args, vim.log.levels.WARN); return end
  return args
end
local function file(ctx, label, cb, default)
  prompt(label, function(path) cb(workflow.path(ctx.work_tree, path)) end, default or ctx.path)
end
local function add_flags(args, state, mapping)
  for _, pair in ipairs(mapping) do if state[pair[1]] then args[#args + 1] = pair[2] end end
end

function M.sparse(ctx, ui, show)
  local state = { cone = true }
  local function run(action, paths)
    if state.index and not state.cone and action ~= 'disable' and action ~= 'add' then
      vim.notify('Sparse index requires cone mode', vim.log.levels.WARN); return
    end
    local args = { 'sparse-checkout', action }
    if action == 'init' or action == 'set' or action == 'reapply' then
      args[#args + 1] = state.cone and '--cone' or '--no-cone'
      args[#args + 1] = state.index and '--sparse-index' or '--no-sparse-index'
    end
    if paths then
      vim.list_extend(args, { '--' }); vim.list_extend(args, paths)
    end
    workflow.run(ctx.work_tree, args)
  end
  local function directories(action)
    prompt('Directories / patterns (quote paths with spaces): ', function(text)
      local paths = words(text)
      if paths and #paths > 0 then run(action, paths) end
    end, ctx.path and vim.fn.shellescape(vim.fs.dirname(ctx.path)) or nil)
  end
  return show({ kind = 'sparse-checkout', title = 'Sparse checkout', groups = {
    { title = 'Arguments', actions = {
      flag('-c', 'Cone directories', state, 'cone', '--cone'),
      flag('-s', 'Sparse index', state, 'index', '--sparse-index'),
    } },
    { title = 'Actions', actions = {
      { key = 'e', label = 'Enable / restore previous selection', run = function() run('init') end },
      { key = 's', label = 'Set directories / patterns', run = function() directories('set') end },
      { key = 'a', label = 'Add directories / patterns', run = function() directories('add') end },
      { key = 'r', label = 'Reapply', run = function() run('reapply') end },
      { key = 'd', label = 'Disable (full checkout)', run = function() run('disable') end },
      { key = 'l', label = 'List current selection', run = function()
        workflow.run(ctx.work_tree, { 'sparse-checkout', 'list' }, { mutation = false, output = true })
      end },
    } },
  } }, ui)
end

function M.subtree(ctx, ui, show)
  local function submenu(export, origin)
    local state = {}
    local function run(action)
      local function prefix(path)
        local args = { 'subtree', action, '--prefix=' .. path }
        if not export then
          if state.squash then args[#args + 1] = '--squash' end
          if state.message then vim.list_extend(args, { '--message', state.message }) end
        else
          add_flags(args, state, { { 'rejoin', '--rejoin' }, { 'ignore', '--ignore-joins' } })
          for name, option in pairs({ branch = '--branch=', annotate = '--annotate=', onto = '--onto=' }) do
            if state[name] and (name ~= 'branch' or action == 'split') then args[#args + 1] = option .. state[name] end
          end
        end
        local function execute(extra)
          vim.list_extend(args, extra)
          workflow.run(ctx.work_tree, args, { editor = true, output = action == 'split',
            mutation = action ~= 'split' or state.rejoin or state.branch ~= nil })
        end
        if action == 'add' or action == 'pull' or action == 'push' then
          prompt('Subtree repository / remote: ', function(remote)
            prompt(action == 'push' and 'Destination refspec: ' or 'Subtree revision: ', function(ref)
              execute({ remote, ref })
            end)
          end)
        else prompt('Subtree commit: ', function(ref) execute({ ref }) end, ctx.commit or 'HEAD') end
      end
      if state.prefix then prefix(state.prefix) else prompt('Subtree prefix: ', prefix, ctx.path) end
    end
    local arguments = { value('-P', 'Prefix', state, 'prefix', '--prefix=') }
    if export then
      vim.list_extend(arguments, {
        value('-b', 'Split branch', state, 'branch', '--branch='),
        value('-a', 'Annotate subjects', state, 'annotate', '--annotate='),
        value('-o', 'Connect to previous history', state, 'onto', '--onto='),
        flag('-r', 'Rejoin split history', state, 'rejoin', '--rejoin'),
        flag('-i', 'Ignore prior joins', state, 'ignore', '--ignore-joins'),
      })
    else vim.list_extend(arguments, {
      flag('-s', 'Squash imported history', state, 'squash', '--squash'),
      value('-m', 'Merge message', state, 'message', '--message='),
    }) end
    local actions = export and {
      { key = 'p', label = 'Push subtree', run = function() run('push') end },
      { key = 's', label = 'Split subtree', run = function() run('split') end },
    } or {
      { key = 'a', label = 'Add from repository', run = function() run('add') end },
      { key = 'c', label = 'Add existing commit', run = function() run('add-commit') end },
      { key = 'm', label = 'Merge existing commit', run = function() run('merge') end },
      { key = 'f', label = 'Pull from repository', run = function() run('pull') end },
    }
    -- Git uses the same add command for a local commit and a repository/ref.
    local original = actions[export and 1 or 2]
    if not export then original.run = function()
      local function prefix(path)
        prompt('Subtree commit: ', function(ref)
          local args = { 'subtree', 'add', '--prefix=' .. path }
          if state.squash then args[#args + 1] = '--squash' end
          if state.message then args[#args + 1] = '--message=' .. state.message end
          args[#args + 1] = ref
          workflow.run(ctx.work_tree, args, { editor = true })
        end, ctx.commit)
      end
      if state.prefix then prefix(state.prefix) else prompt('Subtree prefix: ', prefix, ctx.path) end
    end end
    return show({ kind = export and 'subtree-export' or 'subtree-import', title = export and 'Export subtree' or 'Import subtree',
      groups = { { title = 'Arguments', actions = arguments }, { title = 'Actions', actions = actions } } }, origin)
  end
  return show({ kind = 'subtree', title = 'Subtree', groups = { { title = 'Actions', actions = {
    { key = 'i', label = 'Import subtree', run = function(origin) submenu(false, origin) end },
    { key = 'e', label = 'Export subtree', run = function(origin) submenu(true, origin) end },
  } } } }, ui)
end

function M.bundle(ctx, ui, show)
  local state = { all = true }
  return show({ kind = 'bundle', title = 'Bundle', groups = {
    { title = 'Arguments', actions = {
      flag('-a', 'All refs', state, 'all', '--all'),
      value('-r', 'Revision arguments', state, 'revisions', ''),
    } },
    { title = 'Actions', actions = {
      { key = 'c', label = 'Create bundle', run = function()
        file(ctx, 'New bundle file: ', function(path)
          local revisions = state.revisions and words(state.revisions) or { state.all and '--all' or 'HEAD' }
          if not revisions then return end
          local args = { 'bundle', 'create', path }; vim.list_extend(args, revisions)
          workflow.run(ctx.work_tree, args, { mutation = false, new_file = path })
        end, 'repository.bundle')
      end },
      { key = 'v', label = 'Verify prerequisites', run = function()
        file(ctx, 'Bundle file: ', function(path) workflow.run(ctx.work_tree, { 'bundle', 'verify', path }, { mutation = false, output = true, include_stderr = true }) end)
      end },
      { key = 'l', label = 'List bundled refs', run = function()
        file(ctx, 'Bundle file: ', function(path) workflow.run(ctx.work_tree, { 'bundle', 'list-heads', path }, { mutation = false, output = true }) end)
      end },
      { key = 'u', label = 'Unbundle objects (keep refs)', run = function()
        file(ctx, 'Bundle file: ', function(path) workflow.run(ctx.work_tree, { 'bundle', 'unbundle', path }, { output = true }) end)
      end },
      { key = 'f', label = 'Fetch bundled ref', run = function()
        file(ctx, 'Bundle file: ', function(path)
          prompt('Source:destination refspec: ', function(ref) workflow.run(ctx.work_tree, { 'fetch', path, ref }, { editor = true }) end)
        end)
      end },
    } },
  } }, ui)
end

function M.patch(ctx, ui, show)
  local state = { binary = true }
  local function format()
    file(ctx, 'Output directory for numbered patches: ', function(path)
      local function execute(revisions)
        if vim.fn.isdirectory(path) == 1 and #vim.fn.readdir(path) > 0 then
          vim.notify('Choose an empty patch output directory: ' .. path, vim.log.levels.WARN); return
        end
        local args = { 'format-patch', '--no-color', '--no-ext-diff', '--no-textconv', '--src-prefix=a/', '--dst-prefix=b/',
          state.binary and '--binary' or '--no-binary', '--output-directory=' .. path }
        add_flags(args, state, { { 'cover', '--cover-letter' }, { 'signoff', '--signoff' } })
        if state.number then args[#args + 1] = '--start-number=' .. state.number end
        if state.prefix then args[#args + 1] = '--subject-prefix=' .. state.prefix end
        vim.list_extend(args, revisions)
        workflow.run(ctx.work_tree, args, { mutation = false, output = true })
      end
      if state.range then local revisions = words(state.range); if revisions then execute(revisions) end
      elseif ctx.commits then
        local revisions = { '--no-walk=unsorted' }; vim.list_extend(revisions, vim.deepcopy(ctx.commits)); execute(revisions)
      elseif ctx.commit then execute({ '-1', ctx.commit })
      else prompt('Commit range (base..HEAD): ', function(range) local revisions = words(range); if revisions then execute(revisions) end end) end
    end, 'patches')
  end
  return show({ kind = 'patch', title = 'Plain patches', groups = {
    { title = 'Arguments', actions = {
      flag('-c', 'Cover letter', state, 'cover', '--cover-letter'),
      flag('-s', 'Sign off', state, 'signoff', '--signoff'),
      flag('-b', 'Include binary changes', state, 'binary', '--binary'),
      value('-r', 'Commit range', state, 'range', ''),
      value('-p', 'Subject prefix', state, 'prefix', '--subject-prefix='),
      value('-n', 'Starting number', state, 'number', '--start-number=', function(text) return text:match('^%d+$') ~= nil end),
    } },
    { title = 'Actions', actions = {
      { key = 'c', label = 'Create commit patches', run = format },
      { key = 's', label = 'Save selected / current diff', run = function()
        file(ctx, 'New patch file: ', function(path)
          local args
          if ctx.commit then args = { 'show', '--format=', '--binary', '--no-ext-diff', '--no-textconv', '--no-color', '--src-prefix=a/', '--dst-prefix=b/', ctx.commit }
          else args = { 'diff', '--binary', '--no-ext-diff', '--no-textconv', '--no-color', '--src-prefix=a/', '--dst-prefix=b/' }; if ctx.section == 'staged' then args[#args + 1] = '--cached' end end
          if ctx.paths then table.insert(args, 1, '--literal-pathspecs'); args[#args + 1] = '--'; vim.list_extend(args, ctx.paths)
          elseif ctx.path then table.insert(args, 1, '--literal-pathspecs'); vim.list_extend(args, { '--', ctx.path }) end
          workflow.run(ctx.work_tree, args, { mutation = false, output_file = path, success = 'Patch saved: ' .. path })
        end, 'changes.patch')
      end },
      { key = 'a', label = 'Apply plain patch', run = function(origin) M.apply(ctx, origin, show) end },
    } },
  } }, ui)
end

function M.apply(ctx, ui, show)
  local state = {}
  local function apply(check)
    file(ctx, 'Plain patch file: ', function(path)
      local args = { 'apply' }
      add_flags(args, state, { { 'index', '--index' }, { 'cached', '--cached' }, { 'reverse', '--reverse' },
        { 'threeway', '--3way' }, { 'reject', '--reject' } })
      if state.whitespace then args[#args + 1] = '--whitespace=' .. state.whitespace end
      if check then args[#args + 1] = '--check' end
      vim.list_extend(args, { '--', path })
      workflow.run(ctx.work_tree, args, { mutation = not check, success = check and 'Patch can be applied' or nil })
    end)
  end
  return show({ kind = 'patch-apply', title = 'Apply plain patch', groups = {
    { title = 'Arguments', actions = {
      flag('-i', 'Also update index', state, 'index', '--index', 'cached'),
      flag('-c', 'Index only', state, 'cached', '--cached', 'index'),
      flag('-R', 'Reverse', state, 'reverse', '--reverse'),
      flag('-3', 'Three-way fallback', state, 'threeway', '--3way', 'reject'),
      flag('-r', 'Write rejected hunks', state, 'reject', '--reject', 'threeway'),
      value('-w', 'Whitespace handling', state, 'whitespace', '--whitespace=', options.choices({ 'nowarn', 'warn', 'fix', 'error', 'error-all' }, 'Whitespace handling')),
    } },
    { title = 'Actions', actions = {
      { key = 'a', label = 'Apply patch', run = function() apply(false) end },
      { key = 'c', label = 'Check applicability', run = function() apply(true) end },
    } },
  } }, ui)
end

function M.am(ctx, ui, show)
  local operation = require('git.features.operation').inspect(ctx.work_tree)
  if operation and operation.kind == 'am' then
    local function run(action) workflow.run(ctx.work_tree, { 'am', '--' .. action }, { editor = true }) end
    return show({ kind = 'am', title = 'Apply mail patches', groups = { { title = 'Sequence in progress', actions = {
      { key = 'w', label = 'Continue after resolving / staging', run = function() run('continue') end },
      { key = 's', label = 'Skip current patch', run = function() confirm('Skip this mail patch?', function() run('skip') end) end },
      { key = 'a', label = 'Abort mail patch sequence', run = function() confirm('Abort mail patch sequence and restore original history?', function() run('abort') end) end },
      { key = 'p', label = 'Inspect current mail patch', run = function()
        workflow.run(ctx.work_tree, { 'am', '--show-current-patch=raw' }, { mutation = false, output = true })
      end },
    } } } }, ui)
  end
  local state = {}
  local function apply(maildir)
    local function execute(paths)
      local args = { 'am' }
      add_flags(args, state, { { 'threeway', '--3way' }, { 'signoff', '--signoff' }, { 'keep', '--keep' },
        { 'cr', '--keep-cr' }, { 'scissors', '--scissors' }, { 'date', '--committer-date-is-author-date' } })
      vim.list_extend(args, { '--' }); vim.list_extend(args, paths)
      workflow.run(ctx.work_tree, args, { editor = true })
    end
    if maildir then file(ctx, 'Maildir directory: ', function(path) execute({ path }) end)
    else prompt('Patch / mbox files (quote paths with spaces): ', function(text)
      local paths = words(text); if not paths or #paths == 0 then return end
      for i, path in ipairs(paths) do paths[i] = workflow.path(ctx.work_tree, path) end
      execute(paths)
    end, ctx.path and vim.fn.shellescape(ctx.path) or nil) end
  end
  return show({ kind = 'am', title = 'Apply mail patches', groups = {
    { title = 'Arguments', actions = {
      flag('-3', 'Three-way fallback', state, 'threeway', '--3way'),
      flag('-s', 'Sign off', state, 'signoff', '--signoff'),
      flag('-k', 'Keep subject prefixes', state, 'keep', '--keep'),
      flag('-c', 'Keep carriage returns', state, 'cr', '--keep-cr'),
      flag('-S', 'Use scissors', state, 'scissors', '--scissors'),
      flag('-d', 'Use author date as committer date', state, 'date', '--committer-date-is-author-date'),
    } },
    { title = 'Actions', actions = {
      { key = 'w', label = 'Apply patch / mbox files', run = function() apply(false) end },
      { key = 'm', label = 'Apply Maildir', run = function() apply(true) end },
      { key = 'a', label = 'Apply plain patch without commit', run = function(origin) M.apply(ctx, origin, show) end },
    } },
  } }, ui)
end
function M.notes(ctx, ui, show)
  local state = {}
  local function args(action)
    local result = { 'notes' }
    if state.ref then result[#result + 1] = '--ref=' .. state.ref end
    result[#result + 1] = action; return result
  end
  local function selected(action)
    local function run(commit)
      local argv = args(action); argv[#argv + 1] = commit
      workflow.run(ctx.work_tree, argv, { editor = action == 'edit', mutation = action ~= 'show', output = action == 'show' })
    end
    if ctx.commit then run(ctx.commit) else prompt('Commit for note: ', run, 'HEAD') end
  end
  local function sync(fetch)
    prompt('Notes remote: ', function(remote)
      prompt('Notes ref to synchronize: ', function(ref)
        if not ref:match('^refs/notes/.+') or ref:find('*', 1, true) then
          vim.notify('Use one explicit refs/notes/<name> reference', vim.log.levels.WARN); return
        end
        local incoming = 'refs/notes/incoming/' .. ref:sub(12)
        local argv = { fetch and 'fetch' or 'push', remote, ref .. ':' .. (fetch and incoming or ref) }
        workflow.run(ctx.work_tree, argv, { editor = true,
          success = fetch and ('Fetched notes into ' .. incoming .. '; merge with T m when ready') or nil })
      end, state.ref or 'refs/notes/commits')
    end, 'origin')
  end
  local git_dir = require('git.utils').get_git_dir(ctx.work_tree)
  local merging = git_dir and vim.fn.filereadable(git_dir .. '/NOTES_MERGE_REF') == 1
  local actions = {
    { key = 'T', label = 'Edit note', run = function() selected('edit') end },
    { key = 's', label = 'Show note', run = function() selected('show') end },
    { key = 'r', label = 'Remove note', run = function() confirm('Remove note for selected commit?', function() selected('remove') end) end },
    { key = 'p', label = 'Prune unreachable notes', run = function() confirm('Prune notes for unreachable commits?', function() workflow.run(ctx.work_tree, args('prune')) end) end },
    { key = 'm', label = 'Merge another notes ref', run = function()
      prompt('Notes ref to merge: ', function(ref)
        local argv = args('merge'); if state.strategy then argv[#argv + 1] = '--strategy=' .. state.strategy end
        argv[#argv + 1] = ref; workflow.run(ctx.work_tree, argv)
      end, 'refs/notes/incoming/commits')
    end },
    { key = 'f', label = 'Fetch notes into incoming ref', run = function() sync(true) end },
    { key = 'P', label = 'Push notes ref', run = function() sync(false) end },
  }
  if merging then
    actions = {
      { key = 'c', label = 'Commit resolved notes merge', run = function() local argv = args('merge'); argv[#argv + 1] = '--commit'; workflow.run(ctx.work_tree, argv) end },
      { key = 'a', label = 'Abort notes merge', run = function() confirm('Abort notes merge?', function() local argv = args('merge'); argv[#argv + 1] = '--abort'; workflow.run(ctx.work_tree, argv) end) end },
    }
  end
  return show({ kind = 'notes', title = 'Git Notes', groups = {
    { title = 'Arguments', actions = {
      value('-r', 'Notes ref (empty uses Git default)', state, 'ref', '--ref='),
      value('-s', 'Merge strategy', state, 'strategy', '--strategy=', options.choices({ 'manual', 'ours', 'theirs', 'union', 'cat_sort_uniq' }, 'Notes merge strategy')),
    } }, { title = merging and 'Resolve .git/NOTES_MERGE_WORKTREE then commit' or 'Actions', actions = actions },
  } }, ui)
end
function M.root(ctx, helpers)
  local actions = {}
  for _, entry in ipairs({ { '>', 'Sparse checkout…', 'sparse' }, { 'O', 'Subtree…', 'subtree' },
    { 'U', 'Bundle…', 'bundle' }, { 'T', 'Git Notes…', 'notes' }, { 'W', 'Plain patches…', 'patch' }, { 'w', 'Mail patches…', 'am' } }) do
    actions[#actions + 1] = { key = entry[1], label = entry[2], run = function(ui) return M[entry[3]](ctx, ui, helpers.show) end }
  end
  return actions
end
return M

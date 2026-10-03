-- A paused plan owns its saved WIP and editor scripts until continue or abort.
-- Store these in the worktree Git directory so an editor restart is harmless.
local M = {}
local git = require('git.features.commit_model').git
local history = require('git.features.history_rewrite')
local utils = require('git.utils')
local function directory(root)
  local dir = assert(utils.get_git_dir(root), 'Git directory not found')
  return dir .. '/git-ui-rebase-plan', dir
end
local function save(dir, state)
  local path = dir .. '/state.json'
  vim.fn.writefile({ vim.json.encode(state) }, path .. '.tmp')
  assert(os.rename(path .. '.tmp', path))
end
function M.pending(root)
  local dir = directory(root)
  if not vim.uv.fs_stat(dir) then return nil end
  local ok, state = pcall(function() return vim.json.decode(table.concat(vim.fn.readfile(dir .. '/state.json'), '\n')) end)
  if not ok or type(state) ~= 'table' or state.version ~= 1 or state.root ~= root then
    error('Invalid rebase recovery data in ' .. dir .. '; inspect it before starting another plan', 0)
  end
  return state, dir
end
function M.options(model)
  local dir, gitdir = directory(model.root)
  local state = { version = 1, root = model.root, head = model.head, branch = model.branch,
    owner = tostring(vim.uv.hrtime()) .. '-' .. tostring(vim.fn.getpid()) }
  local opts = { owner = state.owner }
  function opts.before_change(tx, stash)
    if vim.uv.fs_stat(dir) then error('A saved rebase plan already exists; continue or abort it first', 0) end
    vim.fn.mkdir(dir, 'p')
    state.stash = stash
    save(dir, state)
    function tx:temp(text)
      local path = dir .. '/editor-' .. (#self.files + 1) .. '.lua'
      self.files[#self.files + 1] = path
      vim.fn.writefile(vim.split(table.concat(text, '\n'), '\n', { plain = true }), path)
      return path
    end
  end
  function opts.editor(command)
    state.editor = command
    save(dir, state)
  end
  function opts.suspend(tx, _, ok, failure)
    vim.fn.writefile({ state.owner }, gitdir .. '/rebase-merge/git-ui-plan-owner')
    state.paused = true
    save(dir, state)
    return { head = vim.trim(tx:run({ 'rev-parse', 'HEAD' })), warning =
      (not ok and (tostring(failure) .. '\n') or '') ..
      'Rebase paused. Resolve/amend as needed, then GitRebaseContinue; GitRebaseAbort restores the original history. Saved WIP stays in stash until then.' }
  end
  function opts.cleanup(paused)
    if not paused and not vim.uv.fs_stat(gitdir .. '/rebase-merge') then vim.fn.delete(dir, 'rf') end
  end
  return opts
end

function M.resume(root, action)
  if not vim.tbl_contains({ 'continue', 'skip', 'abort' }, action) then return nil, 'Unknown rebase continuation' end
  local state, dir = M.pending(root)
  if not state then return nil, 'No saved rebase plan for this worktree' end
  local gitdir = utils.get_git_dir(root)
  local active = vim.uv.fs_stat(gitdir .. '/rebase-merge')
  if vim.uv.fs_stat(gitdir .. '/rebase-apply') then return nil, 'Another rebase is active; saved plan WIP was retained' end
  if active then
    local ok, owner = pcall(vim.fn.readfile, gitdir .. '/rebase-merge/git-ui-plan-owner')
    if not ok or owner[1] ~= state.owner then return nil, 'Another rebase is active; saved plan WIP was retained' end
    local out, err = git(root, { 'rebase', '--' .. action }, { env = { GIT_EDITOR = assert(state.editor, 'Saved message editor missing') } })
    if vim.uv.fs_stat(gitdir .. '/rebase-merge') then
      utils.fire_fugitive_changed({ work_tree = root })
      return vim.trim(assert(git(root, { 'rev-parse', 'HEAD' }))), err or 'Rebase paused; continue or abort when ready', true, true
    end
    if not out then return nil, err end
  else
    -- Native Git may already have finished/aborted. Restore WIP once, without
    -- resetting HEAD or attaching it to an unrelated active operation.
    for _, marker in ipairs({ 'MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'BISECT_START' }) do
      if vim.uv.fs_stat(gitdir .. '/' .. marker) then return nil, 'Finish the current Git operation before restoring saved plan WIP' end
    end
    local branch = vim.trim(git(root, { 'symbolic-ref', '--quiet', 'HEAD' }) or '')
    if branch ~= state.branch then return nil, 'Return to the original branch before restoring saved plan WIP' end
  end
  local tx = { root = root }
  function tx:run(args, opts)
    local out, err = git(root, args, opts)
    if not out then error(err, 0) end
    return out
  end
  local warning = history.restore_saved(tx, state.stash, nil, true)
  vim.fn.delete(dir, 'rf') -- A failed restoration retains the stash itself.
  utils.fire_fugitive_changed({ work_tree = root })
  return vim.trim(tx:run({ 'rev-parse', 'HEAD' })), warning, true, false
end

function M.open(root, action)
  if not root then return end
  local valid, saved = pcall(M.pending, root)
  if not valid or not saved then vim.notify(valid and 'No saved rebase plan for this worktree' or saved, vim.log.levels.WARN); return end
  local expected_head
  local function execute()
    local job, failure = require('git.features.async').run(root, function()
      local current = M.pending(root)
      if not current or current.owner ~= saved.owner then return nil, 'Saved rebase plan changed; review again' end
      if expected_head and vim.trim(assert(git(root, { 'rev-parse', 'HEAD' }))) ~= expected_head then
        return nil, 'Rebase HEAD changed; review again'
      end
      return M.resume(root, action)
    end,
      function(ok, head, warning, _, paused)
        if not ok or not head then vim.notify(ok and warning or head, vim.log.levels.WARN); return end
        if warning then vim.notify(warning, vim.log.levels.WARN) end
        require('git.features.rebase_plan').resume_result(root, paused)
        if not paused then vim.notify('Rebase ' .. (action == 'abort' and 'aborted' or 'complete') .. ': ' .. head:sub(1, 12)) end
      end, { mutation = true })
    if not job then vim.notify(failure, vim.log.levels.WARN) end
    return job
  end
  if action == 'continue' then return execute() end
  return require('git.features.async').run(root, function() return vim.trim(assert(git(root, { 'rev-parse', 'HEAD' }))) end,
    function(ok, head)
      if not ok then vim.notify(head, vim.log.levels.WARN); return end
      expected_head = head
      vim.ui.select({ action == 'abort' and 'Abort rebase plan' or 'Skip current commit', 'Cancel' },
        { prompt = action == 'abort' and 'Restore the original history and saved WIP?' or 'Discard the current rebase commit?' },
        function(choice) if choice and choice ~= 'Cancel' then execute() end end)
    end)
end
return M

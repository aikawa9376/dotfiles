-- Commit-view edits use the same saved-worktree transaction as log history edits.
local M = {}
local git = require('git.features.commit_model').git
local history = require('git.features.history_rewrite')

function M.apply(root, revision, opts)
  opts = opts or {}
  local tx, err = history.prepare(root, { revision }, opts.expected_head)
  if not tx then return nil, err end
  local commit = tx.commits[1]
  local parents = tx.parents[commit]
  if opts.message and vim.trim(table.concat(opts.message, '\n')) == '' then return nil, 'Commit message cannot be empty' end
  if opts.drop and (#parents > 1 or (#parents == 0 and commit == tx.head)) then
    return nil, 'Cannot drop a merge or the only root commit with this action'
  end
  local has_patch = opts.patch and #opts.patch > 0
  if opts.split and (not has_patch or not opts.message or #parents > 1) then
    return nil, 'Splitting requires a patch, a new commit message and a non-merge commit'
  end
  if not opts.drop and not has_patch then
    if not opts.message then return commit, nil, false end
    local same, message_err = history.same_message(root, commit, table.concat(opts.message, '\n'))
    if same == nil then return nil, message_err end
    if same then return commit, nil, false end
  end
  local function restore_mixed(warning)
    if not opts.mixed or not has_patch then return warning end
    local restore_err
    if not warning then
      local args = { 'apply', '--binary', '--unidiff-zero' }
      if not opts.reverse then args[#args + 1] = '--reverse' end
      args[#args + 1] = '-'
      local restored
      restored, restore_err = git(root, args, { stdin = table.concat(opts.patch, '\n') .. '\n' })
      if restored then return end
    end
    -- Preserve the removed patch even if restoring the user's stash conflicted.
    local recovery = vim.fn.tempname() .. '.patch'
    vim.fn.writefile(opts.patch, recovery)
    local reason = warning or ('Commit rewritten, but restoring unstaged changes failed: ' .. restore_err)
    return reason .. '\nRecovery patch: ' .. recovery .. (opts.reverse and '' or ' (apply with --reverse)')
  end
  return history.execute(tx, function()
    if opts.drop and commit == tx.head then
      tx.mutated = true
      tx:run({ 'reset', '--hard', parents[1] }, { env = { GIT_REFLOG_ACTION = '[nvim git drop]' } })
      return parents[1]
    end
    if commit ~= tx.head then
      tx:rebase(parents[1], { action = opts.drop and 'drop' or 'stop', commits = { commit } })
      if opts.drop then return vim.trim(tx:run({ 'rev-parse', 'HEAD' })) end
      if not vim.uv.fs_stat(tx.dir .. '/rebase-merge') then error('Rebase did not stop at the selected commit', 0) end
      if tx:run({ 'rev-parse', commit .. '^{tree}' }) ~= tx:run({ 'rev-parse', 'HEAD^{tree}' }) then
        error('Rebase stopped at an unexpected tree', 0)
      end
    end
    tx.mutated = true
    if has_patch then
      local args = { 'apply', '--index', '--binary', '--unidiff-zero' }
      if opts.reverse then args[#args + 1] = '--reverse' end
      args[#args + 1] = '-'
      tx:run(args, { stdin = table.concat(opts.patch, '\n') .. '\n' })
    end
    local amend = { 'commit', '--amend', '--allow-empty' }
    if opts.message and not opts.split then vim.list_extend(amend, { '--only', '--cleanup=verbatim', '-F', '-' })
    else amend[#amend + 1] = '--no-edit' end
    tx:run(amend, opts.message and not opts.split and { stdin = table.concat(opts.message, '\n') .. '\n' } or nil)
    if opts.split then
      -- Recompute after removal: reapplying a partial addition's original
      -- context can conflict with the very lines that were just removed.
      local extracted = tx:run({ 'diff', '--binary', '--full-index', '--no-color',
        '--no-ext-diff', '--no-textconv', 'HEAD', commit, '--' })
      if extracted == '' then error('The selected patch does not change this commit', 0) end
      tx:run({ 'apply', '--index', '--binary', '-' }, { stdin = extracted })
      tx:run({ 'commit', '--cleanup=verbatim', '-F', '-' },
        { stdin = table.concat(opts.message, '\n') .. '\n' })
    end
    -- The view follows the target, not the tip created by replaying descendants.
    local target = vim.trim(tx:run({ 'rev-parse', 'HEAD' }))
    if commit ~= tx.head then tx:run({ 'rebase', '--continue' }, { env = { GIT_EDITOR = 'true' } }) end
    return target
  end, { after_restore = restore_mixed })
end

return M

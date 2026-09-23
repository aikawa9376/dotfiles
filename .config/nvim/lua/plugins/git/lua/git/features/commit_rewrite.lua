-- Shared history rewrite for the custom view. All mutations are explicit actions.
local M = {}
local git = require('git.features.commit_model').git
local utils = require('git.utils')
local function run(root, args, opts)
  local out, err = git(root, args, opts)
  if not out then error(err, 0) end
  return out
end
function M.apply(root, commit, opts)
  opts = opts or {}
  local git_dir = utils.get_git_dir(root)
  if not git_dir then return nil, 'Git directory not found' end
  for _, path in ipairs({ 'rebase-merge', 'rebase-apply', 'MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'BISECT_START' }) do
    if vim.uv.fs_stat(git_dir .. '/' .. path) then return nil, 'Finish the current Git operation first' end
  end
  local head, err = git(root, { 'rev-parse', 'HEAD' })
  if not head then return nil, err end
  head = vim.trim(head)
  if opts.expected_head and head ~= opts.expected_head then return nil, 'HEAD changed; reopen the commit before rewriting' end
  if not git(root, { 'merge-base', '--is-ancestor', commit, head }) then
    return nil, 'The displayed commit is not an ancestor of HEAD'
  end
  if opts.message and vim.trim(table.concat(opts.message, '\n')) == '' then return nil, 'Commit message cannot be empty' end
  local parents = vim.split(vim.trim(git(root, { 'show', '-s', '--format=%P', commit }) or ''), ' ', { trimempty = true })
  if opts.drop and (#parents > 1 or (#parents == 0 and commit == head)) then
    return nil, 'Cannot drop a merge or the only root commit with this action'
  end
  if opts.message then
    local tree = git(root, { 'rev-parse', commit .. '^{tree}' })
    if not tree then return nil, 'Commit tree not found' end
  end
  local rebase_started, stash, new_hash, patch_applied = false, nil, nil, false
  local sequence_file, patch_file
  local ok, failure = pcall(function()
    local dirty = run(root, { 'status', '--porcelain', '--untracked-files=all' })
    if dirty ~= '' then
      run(root, { 'stash', 'push', '--include-untracked', '-m', 'fugitive-ext commit rewrite' })
      stash = vim.trim(run(root, { 'rev-parse', 'refs/stash' }))
    end
    if opts.drop and commit == head then
      run(root, { 'reset', '--hard', parents[1] })
      new_hash = parents[1]
      return
    end
    if commit ~= head then
      -- Full hashes avoid core.abbrev settings affecting the stop point. A break
      -- after the target also handles merge commits recreated by --rebase-merges.
      sequence_file = vim.fn.tempname()
      vim.fn.writefile({ '#!/bin/sh',
        "grep -Eq '^(pick " .. commit .. " |merge -[Cc] " .. commit .. " )' \"$1\" || exit 1",
        "sed -i '/^pick " .. commit .. " /a break' \"$1\"",
        "sed -i '/^merge -[Cc] " .. commit .. " /a break' \"$1\"",
      }, sequence_file)
      if opts.drop then
        vim.fn.writefile({ '#!/bin/sh',
          "grep -q '^pick " .. commit .. " ' \"$1\" || exit 1",
          "sed -i 's/^pick " .. commit .. " /drop " .. commit .. " /' \"$1\"",
        }, sequence_file)
      end
      local parent = git(root, { 'rev-parse', '--verify', commit .. '^' })
      local args = { '-c', 'core.abbrev=40', 'rebase', '--interactive', '--rebase-merges', '--empty=keep' }
      args[#args + 1] = parent and vim.trim(parent) or '--root'
      rebase_started = true
      run(root, args, { env = { GIT_SEQUENCE_EDITOR = 'sh ' .. vim.fn.shellescape(sequence_file), GIT_EDITOR = 'true' } })
      if opts.drop then
        rebase_started = false
        new_hash = vim.trim(run(root, { 'rev-parse', 'HEAD' }))
        return
      end
      if not vim.uv.fs_stat(git_dir .. '/rebase-merge') then error('Rebase did not stop at the selected commit', 0) end
      -- If Git did not encounter the target, never amend an unrelated commit.
      local stopped = git(root, { 'rev-parse', 'HEAD' })
      local target_tree = run(root, { 'rev-parse', commit .. '^{tree}' })
      local stopped_tree = run(root, { 'rev-parse', 'HEAD^{tree}' })
      if not stopped or target_tree ~= stopped_tree then error('Rebase stopped at an unexpected tree', 0) end
    end
    if opts.patch then
      patch_file = vim.fn.tempname()
      vim.fn.writefile(opts.patch, patch_file)
      local args = { 'apply', '--index', '--binary', '--unidiff-zero' }
      if opts.reverse then args[#args + 1] = '--reverse' end
      args[#args + 1] = patch_file
      run(root, args)
      patch_applied = true
    end
    local amend = { 'commit', '--amend', '--allow-empty' }
    if opts.message then
      vim.list_extend(amend, { '--only', '--cleanup=verbatim', '-F', '-' })
    else
      amend[#amend + 1] = '--no-edit'
    end
    run(root, amend, opts.message and { stdin = table.concat(opts.message, '\n') .. '\n' } or nil)
    new_hash = vim.trim(run(root, { 'rev-parse', 'HEAD' }))
    if rebase_started then
      run(root, { 'rebase', '--continue' }, { env = { GIT_EDITOR = 'true' } })
      rebase_started = false
    end
  end)
  if sequence_file then os.remove(sequence_file) end
  if patch_file then os.remove(patch_file) end
  if not ok and rebase_started and vim.uv.fs_stat(git_dir .. '/rebase-merge') then
    local aborted, abort_err = git(root, { 'rebase', '--abort' })
    if not aborted then return nil, tostring(failure) .. '\nRebase abort failed: ' .. abort_err .. '\nSaved changes remain in the stash.' end
  elseif not ok and patch_applied then
    -- Undo only our staged patch after a failed HEAD amend; user changes were stashed.
    git(root, { 'reset', '--hard', head })
  end
  local restore_error
  if stash then
    local restored, restore_err = git(root, { 'stash', 'apply', '--index', stash })
    if not restored then
      restore_error = 'Saved changes remain in stash ' .. stash .. ': ' .. restore_err
    else
      local top = git(root, { 'rev-parse', 'refs/stash' })
      if top and vim.trim(top) == stash then git(root, { 'stash', 'drop', '--quiet', 'stash@{0}' }) end
    end
  end
  if not ok then return nil, tostring(failure) .. (restore_error and ('\n' .. restore_error) or '') end
  if opts.mixed and opts.patch and not restore_error then
    local args = { 'apply', '--binary', '--unidiff-zero' }
    if not opts.reverse then args[#args + 1] = '--reverse' end
    args[#args + 1] = '-'
    local restored, restore_err = git(root, args, { stdin = table.concat(opts.patch, '\n') .. '\n' })
    if not restored then
      local recovery = vim.fn.tempname() .. '.patch'
      vim.fn.writefile(opts.patch, recovery)
      restore_error = 'Commit rewritten, but restoring unstaged changes failed: ' .. restore_err .. '\nRecovery patch: ' .. recovery
    end
  end
  utils.fire_fugitive_changed({ work_tree = root })
  return new_hash, restore_error
end
return M

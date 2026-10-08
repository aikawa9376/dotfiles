local M = {}

local function run(root, args)
  local argv = { 'git', '-C', root }
  vim.list_extend(argv, args)
  return vim.system(argv, { text = true }):wait()
end

local function value(root, args)
  local result = run(root, args)
  if result.code ~= 0 then return nil, vim.trim(result.stderr) end
  return vim.trim(result.stdout)
end

local function fail(result, phase)
  return false, phase .. ': ' .. vim.trim(result.stderr ~= '' and result.stderr or result.stdout)
end

local function changed(root)
  require('git.utils').fire_git_changed({ work_tree = root })
end

local function changed_failure(root, result, phase)
  changed(root)
  return fail(result, phase)
end

local function prepare(root, commit)
  local current = value(root, { 'symbolic-ref', '--quiet', '--short', 'HEAD' })
  if not current then return nil, 'A checked-out branch is required' end
  local dirty = value(root, { 'status', '--porcelain', '--untracked-files=all' })
  if dirty == nil then return nil, 'Could not inspect the worktree' end
  if dirty ~= '' then return nil, 'Commit, stash, or discard worktree changes first' end
  local resolved, err = value(root, { 'rev-parse', '--verify', commit .. '^{commit}' })
  if not resolved then return nil, err end
  local parents = value(root, { 'rev-list', '--parents', '-n1', resolved })
  local parts = vim.split(parents or '', ' ', { plain = true })
  if #parts ~= 2 then return nil, 'Select a non-merge commit with a parent' end
  return { current = current, current_tip = value(root, { 'rev-parse', 'HEAD' }),
    commit = resolved, parent = parts[2] }
end

local function branch_tip(root, branch)
  if not branch or branch:find('[\r\n]') then return nil end
  return value(root, { 'show-ref', '--verify', '--hash', 'refs/heads/' .. branch })
end

local function contains(root, older, newer)
  return run(root, { 'merge-base', '--is-ancestor', older, newer }).code == 0
end

local function checked_out_elsewhere(root, branch)
  local listing = value(root, { 'worktree', 'list', '--porcelain' }) or ''
  local current = value(root, { 'rev-parse', '--show-toplevel' })
  local path
  for line in (listing .. '\n'):gmatch('(.-)\n') do
    if line:match('^worktree ') then path = line:sub(10) end
    if line == 'branch refs/heads/' .. branch and path ~= current then return true end
  end
  return false
end

local function remove_commit(root, plan, source, old_tip)
  if old_tip == plan.commit then
    if source == plan.current then
      local reset = run(root, { 'reset', '--hard', plan.parent })
      if reset.code ~= 0 then return changed_failure(root, reset, 'Removing source tip failed') end
    else
      local updated = run(root, { 'update-ref', '-m',
        'cherry-pick: move ' .. plan.commit:sub(1, 12),
        'refs/heads/' .. source, plan.parent, old_tip })
      if updated.code ~= 0 then return changed_failure(root, updated, 'Updating source branch failed') end
    end
    return true
  end
  local rebased = run(root, { 'rebase', '--onto', plan.parent, plan.commit, source })
  if rebased.code ~= 0 then
    return changed_failure(root, rebased,
      'Rebase stopped while removing the source commit; resolve and continue or abort it')
  end
  if source ~= plan.current then
    local switched = run(root, { 'switch', plan.current })
    if switched.code ~= 0 then return changed_failure(root, switched,
      'Move succeeded but switching back failed') end
  end
  return true
end

local function done(root)
  changed(root)
  return true
end

function M.harvest(root, commit, source)
  local plan, err = prepare(root, commit)
  if not plan then return false, err end
  if source == plan.current then return false, 'Source must be another local branch' end
  local tip = branch_tip(root, source)
  if not tip then return false, 'Source must be an existing local branch' end
  if checked_out_elsewhere(root, source) then
    return false, 'Source branch is checked out in another worktree'
  end
  if not contains(root, plan.commit, tip) then
    return false, 'Selected commit is not on the source branch'
  end
  if contains(root, plan.commit, 'HEAD') then
    return false, 'Selected commit is already on the current branch'
  end
  local picked = run(root, { 'cherry-pick', plan.commit })
  if picked.code ~= 0 then
    return changed_failure(root, picked,
      'Cherry-pick stopped; resolve and continue or abort it before retrying harvest')
  end
  local ok, remove_err = remove_commit(root, plan, source, tip)
  if not ok then return false, remove_err end
  return done(root)
end

function M.donate(root, commit, destination)
  local plan, err = prepare(root, commit)
  if not plan then return false, err end
  if destination == plan.current then return false, 'Destination must be another local branch' end
  local tip = branch_tip(root, destination)
  if not tip then return false, 'Destination must be an existing local branch' end
  if not contains(root, plan.commit, 'HEAD') then
    return false, 'Selected commit is not on the current branch'
  end
  if contains(root, plan.commit, tip) then
    return false, 'Selected commit is already on the destination branch'
  end
  local switched = run(root, { 'switch', destination })
  if switched.code ~= 0 then return fail(switched, 'Switching to destination failed') end
  local picked = run(root, { 'cherry-pick', plan.commit })
  if picked.code ~= 0 then
    return changed_failure(root, picked,
      'Cherry-pick stopped on destination; resolve and continue or abort it')
  end
  switched = run(root, { 'switch', plan.current })
  if switched.code ~= 0 then return changed_failure(root, switched,
    'Donation copied the commit but switching back failed') end
  local ok, remove_err = remove_commit(root, plan, plan.current, plan.current_tip)
  if not ok then return false, remove_err end
  return done(root)
end

return M

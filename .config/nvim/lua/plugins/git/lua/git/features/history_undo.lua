-- Reconstruct logical actions from HEAD reflog, with persistent undo/redo marks.
local M = {}
local git = require('git.features.commit_model').git
local async = require('git.features.async')
local function run(root, args, opts)
  local out, err = git(root, args, opts)
  if not out then error(err, 0) end
  return out
end
local function snapshot(root)
  return { head = vim.trim(run(root, { 'rev-parse', 'HEAD' })),
    branch = vim.trim(git(root, { 'symbolic-ref', '--quiet', 'HEAD' }) or ''),
    log = run(root, { 'reflog', 'show', '--format=%H%x00%gs', '-n', '10000', 'HEAD' }) }
end
local function same(a, b) return a.head == b.head and a.branch == b.branch and a.log == b.log end

function M.parse(output, redo)
  local entries = {}
  for line in output:gmatch('[^\n]+') do
    local hash, label = line:match('^(%x+)%z(.*)$')
    if hash then entries[#entries + 1] = { hash = hash, label = label } end
  end
  local counter, ending = 0, nil
  for i, entry in ipairs(entries) do
    local label, previous, action = entry.label, entries[i + 1]
    if ending then
      if label:match('^rebase.*%(start%)') then
        if not previous then return nil, 'Rebase start falls outside available reflog' end
        action = { kind = 'rebase', from = previous.hash, to = ending }
        ending = nil
      end
    elseif label:match('^%[nvim git undo%]') then counter = counter + 1
    elseif label:match('^%[nvim git redo%]') then counter = counter - 1
    elseif label:match('^rebase.*%(finish%)') or label:match('^rebase.*%(abort%)') then ending = entry.hash
    elseif label:match('^rebase') then
      return nil, 'Rebase is incomplete or reflog is truncated; use abort or select a recovery entry'
    else
      local from, to = label:match('^checkout: moving from (%S+) to (%S+)$')
      if from then action = { kind = 'checkout', from = from, to = to }
      elseif label:match('^commit') or label:match('^reset:') or label:match('^pull')
        or label:match('^cherry%-pick:') or label:match('^revert:') or label:match('^merge') then
        if not previous then return nil, 'Previous destination is unavailable in reflog' end
        action = { kind = 'commit', from = previous.hash, to = entry.hash }
      else
        return nil, 'Unsupported reflog action: ' .. label .. '; choose a reflog entry manually'
      end
    end
    if action and action.from ~= action.to then
      if (not redo and counter == 0) or (redo and counter == 1) then return action end
      if redo and counter == 0 then return nil, 'Nothing to redo' end
      counter = counter - 1
    end
  end
  return nil, ending and 'Rebase boundary is missing from reflog' or (redo and 'Nothing to redo' or 'No older supported actions')
end

function M.plan(root, redo)
  local tx, err = require('git.features.history_rewrite').prepare(root, {})
  if not tx then error(err, 0) end
  local saved = snapshot(root)
  local action, failure = M.parse(saved.log, redo)
  if not action then error(failure, 0) end
  action.target = redo and action.to or action.from
  action.mode = action.kind == 'checkout' and 'checkout' or ((redo or action.kind == 'rebase') and 'hard' or 'soft')
  action.snapshot, action.redo, action.root = saved, redo, root
  return action
end

function M.execute(plan)
  local root = plan.root
  if not same(snapshot(root), plan.snapshot) then return nil, 'HEAD, branch or reflog changed; reopen Undo/Redo' end
  local tx, err = require('git.features.history_rewrite').prepare(root, {}, plan.snapshot.head)
  if not tx then return nil, err end
  local env = { GIT_REFLOG_ACTION = plan.redo and '[nvim git redo]' or '[nvim git undo]' }
  if plan.mode == 'soft' then
    local out, failure = git(root, { 'reset', '--soft', plan.target }, { env = env })
    if out then require('git.utils').fire_fugitive_changed({ work_tree = root }) end
    return out ~= nil and plan.target or nil, failure
  end
  -- The shared transaction preserves staged, unstaged and untracked changes.
  local consume_index = false
  if plan.redo and plan.kind == 'commit' then
    -- Soft Undo leaves exactly the undone tree staged. After Redo that
    -- contribution is committed again, so restore only index-to-worktree WIP.
    -- An independently edited index must retain the normal restoration path.
    local index = git(root, { 'write-tree' })
    local target_tree = git(root, { 'rev-parse', plan.target .. '^{tree}' })
    consume_index = index ~= nil and index == target_tree
  end
  return require('git.features.history_rewrite').execute(tx, function()
    if plan.mode == 'checkout' then
      -- No force checkout: saved changes are restored by the transaction.
      tx:run({ 'checkout', plan.target }, { env = env })
      tx.mutated = true
    else
      tx.mutated = true
      tx:run({ 'reset', '--hard', plan.target }, { env = env })
    end
    return plan.target
  end, { consume_index = consume_index })
end

function M.open(root, redo)
  if not root then return end
  return async.run(root, function() return M.plan(root, redo) end, function(ok, plan)
    if not ok then vim.notify(plan, vim.log.levels.WARN); return end
    local verb = redo and 'Redo' or 'Undo'
    local detail = plan.mode == 'checkout' and ('checkout ' .. plan.target)
      or (plan.mode .. ' reset to ' .. plan.target:sub(1, 12))
    vim.ui.select({ verb .. ': ' .. detail, 'Cancel' }, { prompt = verb .. ' ' .. plan.kind .. '?' }, function(choice)
      if not choice or choice == 'Cancel' then return end
      local task, failure = async.run(root, function()
        local target, warning = M.execute(plan)
        if not target then error(warning, 0) end
        return target, warning
      end, function(success, target, warning)
        vim.notify(success and (warning or (verb .. ': ' .. target)) or target,
          success and (warning and vim.log.levels.WARN or vim.log.levels.INFO) or vim.log.levels.ERROR)
      end, { mutation = true })
      if not task then vim.notify(failure, vim.log.levels.WARN) end
    end)
  end)
end
return M

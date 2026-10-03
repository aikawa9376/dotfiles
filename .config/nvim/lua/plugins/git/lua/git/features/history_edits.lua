-- Log/status history actions. UI callbacks only choose targets and report results.
local M = {}
local history = require('git.features.history_rewrite')
local git = require('git.features.commit_model').git

local function first_parent(tx)
  local out, err = git(tx.root, { 'rev-list', '--first-parent', tx.head })
  if not out then return nil, err end
  local chain = vim.split(vim.trim(out), '\n', { plain = true, trimempty = true })
  local positions = {}
  for i, hash in ipairs(chain) do positions[hash] = i end
  for _, hash in ipairs(tx.commits) do
    if not positions[hash] then return nil, 'Select commits on the current first-parent history' end
  end
  return positions
end

function M.move(root, current, target, direction)
  local tx, err = history.prepare(root, { current, target })
  if not tx then return nil, err end
  local a, b = unpack(tx.commits)
  if direction ~= 'up' and direction ~= 'down' then return nil, 'Invalid move direction' end
  local positions, chain_err = first_parent(tx)
  if not positions then return nil, chain_err end
  local older = direction == 'down' and b or a
  local newer = direction == 'down' and a or b
  if a == b or positions[newer] + 1 ~= positions[older] then return nil, 'Select adjacent commits to move' end
  if #tx.parents[a] > 1 or #tx.parents[b] > 1 then return nil, 'Cannot move a merge commit' end
  if not git(root, { 'symbolic-ref', '--quiet', 'HEAD' }) then return nil, 'Cannot move commits in detached HEAD state' end
  return history.execute(tx, function()
    tx:rebase(tx.parents[older][1], { action = 'move', commits = { a, b } })
    return vim.trim(tx:run({ 'rev-parse', 'HEAD' }))
  end)
end

function M.drop(root, revisions)
  if not revisions or #revisions == 0 then return nil, 'No commits selected' end
  local tx, err = history.prepare(root, revisions)
  if not tx then return nil, err end
  local positions, chain_err = first_parent(tx)
  if not positions then return nil, chain_err end
  local selected, oldest, count = {}, nil, 0
  for _, hash in ipairs(tx.commits) do
    if #tx.parents[hash] > 1 then return nil, 'Cannot drop a merge commit' end
    if not selected[hash] then selected[hash], count = true, count + 1 end
    if not oldest or positions[hash] > positions[oldest] then oldest = hash end
  end
  local base = tx.parents[oldest][1]
  if not base and positions[oldest] == count then return nil, 'Cannot drop the entire commit history' end
  local commits = vim.tbl_keys(selected)
  return history.execute(tx, function()
    if base and positions[oldest] == count then
      tx.mutated = true
      tx:run({ 'reset', '--hard', base }, { env = { GIT_REFLOG_ACTION = '[nvim git drop]' } })
    else tx:rebase(base, { action = 'drop', commits = commits }) end
    return vim.trim(tx:run({ 'rev-parse', 'HEAD' }))
  end)
end

function M.fixup(root, revision)
  local tx, err = history.prepare(root, { revision })
  if not tx then return nil, err end
  local hash = tx.commits[1]
  local positions, chain_err = first_parent(tx)
  if not positions then return nil, chain_err end
  if #tx.parents[hash] ~= 1 then return nil, 'Fixup requires a non-root, non-merge commit' end
  local parent = tx.parents[hash][1]
  local grandparents = git(root, { 'show', '-s', '--format=%P', parent })
  if not grandparents then return nil, 'Cannot resolve the parent commit' end
  local parents = vim.split(vim.trim(grandparents), ' ', { trimempty = true })
  if #parents > 1 then return nil, 'Cannot fixup into a merge commit' end
  return history.execute(tx, function()
    tx:rebase(parents[1], { action = 'fixup', commits = { hash }, parent = parent })
    return vim.trim(tx:run({ 'rev-parse', 'HEAD' }))
  end)
end

function M.mix_index(root, revision, message)
  local tx, err = history.prepare(root, { revision })
  if not tx then return nil, err end
  local hash = tx.commits[1]
  local positions, chain_err = first_parent(tx)
  if not positions then return nil, chain_err end
  if #tx.parents[hash] > 1 then return nil, 'Cannot fold the index into a merge commit' end
  if message and message ~= '' and vim.trim(message) == '' then return nil, 'Commit message cannot be empty' end
  message = message ~= '' and message or nil
  local patch, patch_err = history.index_patch(root)
  if not patch then return nil, patch_err end
  if message then
    local same, message_err = history.same_message(root, hash, message)
    if same == nil then return nil, message_err end
    if same then message = nil end
  end
  if patch == '' then
    if not message then return tx.head, nil, false end
    return require('git.features.commit_rewrite').apply(root, hash, { message = vim.split(message, '\n', { plain = true }) })
  end
  return history.execute(tx, function()
    tx.mutated = true
    if patch ~= '' then tx:run({ 'apply', '--index', '--binary', '-' }, { stdin = patch }) end
    local args = { 'commit', '--allow-empty', '--no-edit' }
    if message then
      vim.list_extend(args, { '--cleanup=verbatim', '-F', '-' })
      tx:run(args, { stdin = 'amend! ' .. hash .. '\n\n' .. message .. '\n' })
    else
      args[#args + 1] = '--fixup=' .. hash
      tx:run(args)
    end
    local helper = vim.trim(tx:run({ 'rev-parse', 'HEAD' }))
    tx:rebase(tx.parents[hash][1], { action = 'fold', commits = { hash, helper }, message = message ~= nil })
    return vim.trim(tx:run({ 'rev-parse', 'HEAD' }))
  end, { consume_index = true })
end

return M

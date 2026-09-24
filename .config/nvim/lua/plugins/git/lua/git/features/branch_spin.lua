local M = {}

local function run(work_tree, args)
  local command = { 'git' }
  vim.list_extend(command, args)
  return vim.system(command, { cwd = work_tree, text = true }):wait()
end

local function output(result)
  return vim.trim((result.stderr or '') ~= '' and result.stderr or result.stdout or '')
end

local function value(work_tree, args)
  local result = run(work_tree, args)
  if result.code ~= 0 then return nil end
  return vim.trim(result.stdout or '')
end

function M.plan(work_tree, mode, from)
  if mode ~= 'spinoff' and mode ~= 'spinout' then return nil, 'Unknown spin mode' end
  local branch = value(work_tree, { 'symbolic-ref', '--quiet', '--short', 'HEAD' })
  if not branch or branch == '' then return nil, 'Spin requires a checked-out branch' end
  local tip = value(work_tree, { 'rev-parse', '--verify', 'HEAD' })
  if not tip then return nil, 'Spin requires at least one commit' end

  local operation = require('git.features.operation').inspect(work_tree)
  if operation then return nil, 'Finish the current ' .. operation.kind .. ' before spinning a branch' end
  local unmerged = value(work_tree, { 'ls-files', '-u' })
  if unmerged and unmerged ~= '' then return nil, 'Resolve unmerged files before spinning a branch' end

  local status = run(work_tree, { '--no-optional-locks', 'status', '--porcelain=v1', '-z', '--untracked-files=all' })
  if status.code ~= 0 then return nil, output(status) end
  local dirty = (status.stdout or '') ~= ''
  local upstream = value(work_tree, { 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}' })
  local base, ahead
  if upstream and upstream ~= '' then
    ahead = tonumber(value(work_tree, { 'rev-list', '--count', upstream .. '..' .. branch })) or 0
    if ahead > 0 then base = value(work_tree, { 'merge-base', branch, upstream }) end
  end
  if from and from ~= '' then
    local selected = value(work_tree, { 'rev-parse', '--verify', '--end-of-options', from .. '^{commit}' })
    if not selected then return nil, 'Selected commit does not exist' end
    local first_parent = value(work_tree, { 'rev-list', '--first-parent', 'HEAD' }) or ''
    if not ('\n' .. first_parent .. '\n'):find('\n' .. selected .. '\n', 1, true) then
      return nil, 'Selected commit is not on the current branch first-parent history'
    end
    if upstream and upstream ~= '' then
      local shared = run(work_tree, { 'merge-base', '--is-ancestor', selected, upstream })
      if shared.code == 0 then return nil, 'Selected commit is already in the upstream' end
    end
    base = value(work_tree, { 'rev-parse', '--verify', selected .. '^' })
    if not base then return nil, 'Cannot spin from the root commit' end
    from = selected
  end
  if base == tip then base = nil end

  return {
    mode = mode,
    branch = branch,
    tip = tip,
    upstream = upstream,
    base = base,
    ahead = ahead or 0,
    from = from,
    dirty = dirty,
    checkout = mode == 'spinoff' or dirty,
  }
end

function M.run(work_tree, name, mode, expected, from)
  from = from or (expected and expected.from)
  local plan, err = M.plan(work_tree, mode, from)
  if not plan then return nil, err end
  if expected and (plan.branch ~= expected.branch or plan.tip ~= expected.tip
    or plan.base ~= expected.base or plan.dirty ~= expected.dirty or plan.upstream ~= expected.upstream)
  then
    return nil, 'Branch state changed while preparing the spin; retry it'
  end

  local checked = run(work_tree, { 'check-ref-format', '--branch', name })
  if checked.code ~= 0 then return nil, output(checked) end
  local exists = run(work_tree, { 'show-ref', '--verify', '--quiet', 'refs/heads/' .. name })
  if exists.code == 0 then return nil, 'Branch already exists: ' .. name end

  local created
  if plan.checkout then
    created = run(work_tree, { 'switch', '--track', '-c', name, plan.branch })
  else
    created = run(work_tree, { 'branch', '--track', name, plan.branch })
  end
  if created.code ~= 0 then return nil, output(created) end

  if plan.base then
    local reset
    if plan.checkout then
      reset = run(work_tree, { 'branch', '-f', plan.branch, plan.base })
    else
      reset = run(work_tree, { 'reset', '--keep', plan.base })
    end
    if reset.code ~= 0 then
      return nil, ('Created %s, but could not reset %s: %s'):format(name, plan.branch, output(reset))
    end
  end

  return plan
end

return M

-- Apply or discard a hunk displayed in the status buffer.
local M = {}

local function diff_args(section, path)
  local args = { 'git', 'diff', '--no-ext-diff', '--no-textconv', '--no-color', '--no-renames',
    '--src-prefix=a/', '--dst-prefix=b/', '--unified=3' }
  if section == 'staged' then table.insert(args, '--cached') end
  vim.list_extend(args, { '--', path })
  return args
end

function M.diff(work_tree, section, path)
  return vim.system(diff_args(section, path), { cwd = work_tree, text = true }):wait()
end

local function split_lines(text)
  local lines = vim.split(text or '', '\n', { plain = true })
  if lines[#lines] == '' then table.remove(lines) end
  return lines
end

local function build_patch(work_tree, section, path, hunk_number, selected, expected, reverse)
  local result = M.diff(work_tree, section, path)
  if result.code ~= 0 then return nil, vim.trim(result.stderr or 'Could not read diff') end
  local lines = split_lines(result.stdout)
  local first_hunk, target, count
  count = 0
  for index, line in ipairs(lines) do
    if line:match('^@@') then
      first_hunk = first_hunk or index
      count = count + 1
      if count == hunk_number then target = index; break end
    end
  end
  if not target then return nil, 'The displayed hunk has changed; refresh status' end
  local last = target
  while last < #lines and not lines[last + 1]:match('^@@') and not lines[last + 1]:match('^diff %-%-git') do
    last = last + 1
  end
  if expected then
    local actual = {}
    for index = target, last do actual[#actual + 1] = lines[index] end
    if not vim.deep_equal(actual, expected) then
      return nil, 'The displayed hunk has changed; refresh status'
    end
  end
  local partial = next(selected) ~= nil
  local patch = {}
  for index = 1, first_hunk - 1 do
    local line = lines[index]
    if partial and line:match('^new file mode') or partial and line:match('^deleted file mode') then
      -- A partial selection keeps the file; represent it as a modification.
    elseif partial and line:match('^index ') then
      -- The shortened patch no longer has the original blob identities.
    else
      if partial and line == '--- /dev/null' then
        local other = lines[index + 1] or ''
        line = other:gsub('^%+%+%+ ', '--- '):gsub('b/', 'a/', 1)
      elseif partial and line == '+++ /dev/null' then
        local other = lines[index - 1] or ''
        line = other:gsub('^%-%-%- ', '+++ '):gsub('a/', 'b/', 1)
      end
      patch[#patch + 1] = line
    end
  end
  patch[#patch + 1] = lines[target]
  local changed = 0
  local previous_kept = true
  for index = target + 1, last do
    local line = lines[index]
    local prefix = line:sub(1, 1)
    if not partial then
      patch[#patch + 1] = line
    elseif prefix == '+' or prefix == '-' then
      local keep = selected[index - target] == true
      if keep then
        changed = changed + 1
        patch[#patch + 1] = line
      elseif (not reverse and prefix == '-') or (reverse and prefix == '+') then
        patch[#patch + 1] = ' ' .. line:sub(2)
      end
      previous_kept = keep or (not reverse and prefix == '-') or (reverse and prefix == '+')
    elseif prefix ~= '\\' or previous_kept then
      patch[#patch + 1] = line
      previous_kept = true
    end
  end
  if partial and changed == 0 then return nil, 'Select added or removed lines in this hunk' end
  return table.concat(patch, '\n') .. '\n'
end

M.build_patch = build_patch

function M.apply(work_tree, section, path, hunk_number, selected, expected)
  local patch, err = build_patch(work_tree, section, path, hunk_number, selected, expected, section == 'staged')
  if not patch then return false, err end

  local args = { 'git', 'apply', '--cached', '--recount' }
  if section == 'staged' then table.insert(args, '--reverse') end
  if next(selected) then table.insert(args, '--unidiff-zero') end
  table.insert(args, '-')
  local applied = vim.system(args, { cwd = work_tree, text = true, stdin = patch }):wait()
  if applied.code ~= 0 then return false, vim.trim(applied.stderr or 'Could not apply hunk') end
  return true
end

function M.discard(work_tree, section, path, hunk_number, selected, expected)
  local patch, err = build_patch(work_tree, section, path, hunk_number, selected, expected, true)
  if not patch then return false, err end
  local partial = next(selected) ~= nil
  local function apply(cached, check, reverse)
    local args = { 'git', 'apply', '--recount' }
    if cached then args[#args + 1] = '--cached' end
    if check then args[#args + 1] = '--check' end
    if reverse then args[#args + 1] = '--reverse' end
    if partial then args[#args + 1] = '--unidiff-zero' end
    args[#args + 1] = '-'
    return vim.system(args, { cwd = work_tree, text = true, stdin = patch }):wait()
  end
  local worktree_check = apply(false, true, true)
  if worktree_check.code ~= 0 then
    return false, vim.trim(worktree_check.stderr or 'Could not discard worktree hunk')
  end
  if section == 'staged' then
    local index_check = apply(true, true, true)
    if index_check.code ~= 0 then
      return false, vim.trim(index_check.stderr or 'Could not discard staged hunk')
    end
    local index_result = apply(true, false, true)
    if index_result.code ~= 0 then
      return false, vim.trim(index_result.stderr or 'Could not discard staged hunk')
    end
  end
  local worktree_result = apply(false, false, true)
  if worktree_result.code ~= 0 then
    if section == 'staged' then
      local rollback = apply(true, false, false)
      if rollback.code ~= 0 then
        return false, 'Worktree discard failed and index rollback failed: '
          .. vim.trim(worktree_result.stderr or '') .. '; ' .. vim.trim(rollback.stderr or '')
      end
    end
    return false, vim.trim(worktree_result.stderr or 'Could not discard worktree hunk')
  end
  return true
end

return M

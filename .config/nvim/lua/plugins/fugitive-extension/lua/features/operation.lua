local M = {}
local utils = require('fugitive_utils')

local function run(work_tree, args)
  local command = { 'git' }
  vim.list_extend(command, args)
  return vim.system(command, { cwd = work_tree, text = true }):wait()
end

local function commit_summary(work_tree, revision)
  local result = run(work_tree, { 'show', '--no-patch', '--format=%h%x09%s', revision })
  if result.code ~= 0 then return nil end
  local hash, subject = vim.trim(result.stdout or ''):match('^(%x+)%s+(.+)$')
  if not hash then return nil end
  return { revision = revision, hash = hash, subject = subject or '' }
end

local function parse_bisect_vars(value)
  local variables = {}
  for line in (value or ''):gmatch('[^\r\n]+') do
    local key, raw = line:match("^([%w_]+)='?(.-)'?$")
    if key then variables[key] = tonumber(raw) or raw end
  end
  return variables
end

local function inspect_bisect(work_tree, git_dir)
  if vim.fn.filereadable(git_dir .. '/BISECT_START') ~= 1 then return nil end

  local start_lines = vim.fn.readfile(git_dir .. '/BISECT_START', '', 1)
  local state = {
    kind = 'bisect',
    start = start_lines[1] or '',
    current = commit_summary(work_tree, 'HEAD'),
    bad = commit_summary(work_tree, 'refs/bisect/bad'),
    good = {},
  }

  local refs_result = run(work_tree, {
    'for-each-ref', '--format=%(refname)', 'refs/bisect/good-*',
  })
  local good_refs = {}
  if refs_result.code == 0 then
    for ref in (refs_result.stdout or ''):gmatch('[^\r\n]+') do
      table.insert(good_refs, ref)
      local summary = commit_summary(work_tree, ref)
      if summary then table.insert(state.good, summary) end
    end
  end

  if state.bad and #good_refs > 0 then
    local args = { 'rev-list', '--bisect-vars', 'refs/bisect/bad', '--not' }
    vim.list_extend(args, good_refs)
    local vars_result = run(work_tree, args)
    if vars_result.code == 0 then
      local variables = parse_bisect_vars(vars_result.stdout)
      state.remaining = variables.bisect_nr
      state.steps = variables.bisect_steps
      state.total = variables.bisect_all
    end
  end

  return state
end

local function read_first(path)
  if vim.fn.filereadable(path) ~= 1 then return nil end
  local lines = vim.fn.readfile(path, '', 1)
  return lines[1]
end

local function count_todo(path)
  if vim.fn.filereadable(path) ~= 1 then return 0 end
  local count = 0
  for _, line in ipairs(vim.fn.readfile(path)) do
    if line ~= '' and not line:match('^%s*#') then count = count + 1 end
  end
  return count
end

local function sequencer_state(work_tree, git_dir, kind, label, head_file)
  local done = count_todo(git_dir .. '/sequencer/done')
  local remaining = count_todo(git_dir .. '/sequencer/todo')
  local revision = read_first(git_dir .. '/' .. head_file)
  return {
    kind = kind,
    label = label,
    current = revision and commit_summary(work_tree, revision) or nil,
    current_step = done + (remaining > 0 and 1 or 0),
    total_steps = done + remaining,
  }
end

local function rebase_state(work_tree, git_dir)
  local directory
  if vim.fn.isdirectory(git_dir .. '/rebase-merge') == 1 then
    directory = git_dir .. '/rebase-merge'
  elseif vim.fn.isdirectory(git_dir .. '/rebase-apply') == 1 then
    directory = git_dir .. '/rebase-apply'
  else
    return nil
  end

  local current_step = tonumber(read_first(directory .. '/msgnum') or read_first(directory .. '/next'))
  local total_steps = tonumber(read_first(directory .. '/end') or read_first(directory .. '/last'))
  local revision = read_first(directory .. '/stopped-sha')
  if not revision and vim.fn.filereadable(git_dir .. '/REBASE_HEAD') == 1 then revision = 'REBASE_HEAD' end
  return {
    kind = 'rebase',
    label = 'Rebase in progress',
    current = revision and commit_summary(work_tree, revision) or nil,
    current_step = current_step,
    total_steps = total_steps,
  }
end

function M.inspect(work_tree)
  local git_dir = utils.get_git_dir(work_tree)
  if not git_dir then return nil end

  local bisect = inspect_bisect(work_tree, git_dir)
  if bisect then return bisect end

  local rebase = rebase_state(work_tree, git_dir)
  if rebase then
    return rebase
  elseif vim.fn.filereadable(git_dir .. '/CHERRY_PICK_HEAD') == 1 then
    return sequencer_state(work_tree, git_dir, 'cherry_pick', 'Cherry-pick in progress', 'CHERRY_PICK_HEAD')
  elseif vim.fn.filereadable(git_dir .. '/MERGE_HEAD') == 1 then
    local revision = read_first(git_dir .. '/MERGE_HEAD')
    return {
      kind = 'merge',
      label = 'Merge in progress',
      current = revision and commit_summary(work_tree, revision) or nil,
    }
  elseif vim.fn.filereadable(git_dir .. '/REVERT_HEAD') == 1 then
    return sequencer_state(work_tree, git_dir, 'revert', 'Revert in progress', 'REVERT_HEAD')
  end
  return nil
end

local function summary_line(summary)
  if not summary then return 'unknown' end
  return summary.hash .. (summary.subject ~= '' and (' ' .. summary.subject) or '')
end

function M.status_lines(state)
  if not state then return {} end
  if state.kind ~= 'bisect' then
    local label = state.label
    if state.current_step and state.total_steps and state.total_steps > 0 then
      label = label .. (' (%d/%d)'):format(state.current_step, state.total_steps)
    end
    local lines = { label }
    if state.current then table.insert(lines, 'Current: ' .. summary_line(state.current)) end
    table.insert(lines, 'Operation keys: rr continue  rs skip  ra abort')
    return lines
  end

  local progress = ''
  if type(state.remaining) == 'number' then
    progress = (' (%d revisions left'):format(state.remaining)
    if type(state.steps) == 'number' then
      progress = progress .. (', roughly %d %s'):format(state.steps, state.steps == 1 and 'step' or 'steps')
    end
    progress = progress .. ')'
  end

  local lines = { 'Bisecting' .. progress }
  if state.current then table.insert(lines, summary_line(state.current)) end
  if #state.good > 0 then
    local good = {}
    for _, item in ipairs(state.good) do table.insert(good, summary_line(item)) end
    table.insert(lines, 'Good: ' .. table.concat(good, ', '))
  end
  if state.bad then table.insert(lines, 'Bad: ' .. summary_line(state.bad)) end
  if state.start ~= '' then table.insert(lines, 'Start: ' .. state.start) end
  table.insert(lines, 'Bisect keys: bg good  bb bad  bk skip  br reset  bx run')
  return lines
end

local bisect_actions = {
  bad = true,
  good = true,
  reset = true,
  run = true,
  skip = true,
  start = true,
}

function M.bisect(work_tree, action, args, callback)
  if not bisect_actions[action] then
    callback(false, 'Unsupported bisect action: ' .. tostring(action))
    return
  end

  local command = { 'git', 'bisect', action }
  vim.list_extend(command, args or {})
  vim.system(command, { cwd = work_tree, text = true }, function(result)
    vim.schedule(function()
      local output = vim.trim((result.stdout or '') .. (result.stderr or ''))
      callback(result.code == 0, output ~= '' and output or ('git bisect ' .. action .. ' completed'), result)
    end)
  end)
end

return M

local M = {}

local function run(work_tree, args, opts)
  local command = { 'git' }
  vim.list_extend(command, args)
  local system_opts = { cwd = work_tree, text = true }
  if opts and opts.stdin ~= nil then system_opts.stdin = opts.stdin end
  return vim.system(command, system_opts):wait()
end

local function nul_records(value)
  return vim.split(value or '', '\0', { plain = true, trimempty = true })
end

local function index_entries(work_tree)
  local result = run(work_tree, { 'ls-files', '--stage', '-z' })
  if result.code ~= 0 then return {} end
  local entries = {}
  for _, record in ipairs(nul_records(result.stdout)) do
    local mode, oid, stage, path = record:match('^(%d+) (%x+) (%d+)\t(.*)$')
    if mode and stage == '0' then entries[path] = { mode = mode, oid = oid } end
  end
  return entries
end

local function worktree_oid(work_tree, entry)
  local absolute = vim.fs.joinpath(work_tree, entry.path)
  local stat = (vim.uv or vim.loop).fs_lstat(absolute)
  if not stat then return nil, 'missing' end

  if entry.mode == '160000' then
    if stat.type ~= 'directory' then return nil, 'modified' end
    local result = vim.system({ 'git', 'rev-parse', 'HEAD' }, { cwd = absolute, text = true }):wait()
    if result.code ~= 0 then return nil, 'modified' end
    return vim.trim(result.stdout or '')
  end

  local result = run(work_tree, { 'hash-object', '--path=' .. entry.path, '--', entry.path })
  if result.code ~= 0 then return nil, 'modified' end
  return vim.trim(result.stdout or '')
end

local function local_state(work_tree, entry)
  local oid, state = worktree_oid(work_tree, entry)
  if state then return state end
  return oid == entry.oid and 'clean' or 'modified'
end

local function display_line(entry)
  local state = entry.state == 'clean' and '' or ('  [' .. entry.state .. ']')
  return ('  %-7s %s%s'):format(entry.flag, entry.path, state)
end

function M.inspect(work_tree)
  local result = run(work_tree, { 'ls-files', '-v', '-z' })
  if result.code ~= 0 then
    return { entries = {}, changed_count = 0, error = vim.trim(result.stderr or 'git ls-files failed') }
  end

  local staged = index_entries(work_tree)
  local state = { entries = {}, changed_count = 0 }
  for _, record in ipairs(nul_records(result.stdout)) do
    local tag, path = record:match('^(.) (.*)$')
    local flag
    if tag and tag:upper() == 'S' then
      flag = 'skip'
    elseif tag and tag:match('%l') then
      flag = 'assume'
    end
    local index_entry = path and staged[path] or nil
    if flag and index_entry then
      local entry = {
        flag = flag,
        path = path,
        mode = index_entry.mode,
        oid = index_entry.oid,
      }
      entry.state = local_state(work_tree, entry)
      entry.line = display_line(entry)
      if entry.state ~= 'clean' then state.changed_count = state.changed_count + 1 end
      table.insert(state.entries, entry)
    end
  end
  table.sort(state.entries, function(left, right) return left.path < right.path end)
  return state
end

function M.header_line(state, expanded)
  if not state or #state.entries == 0 then return nil end
  return ('Index flags [local] (%d) [%s]'):format(#state.entries, expanded and 'expanded' or 'collapsed')
end

function M.warning_line(state)
  if not state or state.changed_count == 0 then return nil end
  return ('Hidden changes: %d %s (Index flags)'):format(
    state.changed_count,
    state.changed_count == 1 and 'file' or 'files'
  )
end

function M.status_lines(state, expanded)
  local header = M.header_line(state, expanded)
  if not header then return {} end
  local lines = { '', header }
  if expanded then
    for _, entry in ipairs(state.entries) do table.insert(lines, entry.line) end
  end
  return lines
end

function M.entry_from_line(state, line)
  for _, entry in ipairs(state and state.entries or {}) do
    if entry.line == line then return entry end
  end
  return nil
end

function M.flag_for_path(state, path)
  for _, entry in ipairs(state and state.entries or {}) do
    if entry.path == path then return entry.flag end
  end
  return nil
end

function M.tracked_paths(work_tree)
  local result = run(work_tree, { 'ls-files', '-z' })
  if result.code ~= 0 then return {}, vim.trim(result.stderr or 'git ls-files failed') end
  return nul_records(result.stdout)
end

function M.update(work_tree, path, flag)
  local operations
  if flag == 'skip' then
    operations = { '--no-assume-unchanged', '--skip-worktree' }
  elseif flag == 'assume' then
    operations = { '--no-skip-worktree', '--assume-unchanged' }
  elseif flag == nil then
    operations = { '--no-skip-worktree', '--no-assume-unchanged' }
  else
    return false, 'Unknown index flag: ' .. tostring(flag)
  end
  for _, operation in ipairs(operations) do
    local result = run(work_tree, { 'update-index', operation, '--', path })
    if result.code ~= 0 then return false, vim.trim(result.stderr or 'git update-index failed') end
  end
  return true
end

local function blob_lines(work_tree, path)
  local result = run(work_tree, { 'show', ':' .. path })
  if result.code ~= 0 then return {} end
  local lines = vim.split((result.stdout or ''):gsub('\r\n', '\n'), '\n', { plain = true })
  if lines[#lines] == '' then table.remove(lines) end
  return lines
end

local function worktree_lines(work_tree, path)
  local absolute = vim.fs.joinpath(work_tree, path)
  if vim.fn.filereadable(absolute) ~= 1 then return {} end
  local ok, lines = pcall(vim.fn.readfile, absolute, 'b')
  return ok and lines or {}
end

function M.diff_sides(work_tree, entry)
  if not entry then return nil, 'No index flag at cursor' end
  if entry.mode == '160000' then return nil, 'Submodule diff is not supported here' end
  return {
    path = entry.path,
    left = blob_lines(work_tree, entry.path),
    right = worktree_lines(work_tree, entry.path),
    left_label = 'index',
    right_label = entry.state == 'missing' and 'missing' or 'current file',
  }
end

return M

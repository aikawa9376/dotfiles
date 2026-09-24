local M = {}
local change_display = require('git.features.change_display')

local function run(work_tree, args, opts)
  local command = { 'git' }
  vim.list_extend(command, args)
  local system_opts = { cwd = work_tree, text = not (opts and opts.binary) }
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

local function worktree_bytes(work_tree, entry)
  local absolute = vim.fs.joinpath(work_tree, entry.path)
  local stat = (vim.uv or vim.loop).fs_lstat(absolute)
  if not stat then return '' end
  if stat.type == 'link' then return (vim.uv or vim.loop).fs_readlink(absolute) end
  if stat.type ~= 'file' then return nil end
  local file = io.open(absolute, 'rb')
  if not file then return nil end
  local content = file:read('*a')
  file:close()
  return content
end

local function inspect_diff(work_tree, entry)
  if entry.state == 'clean' or entry.mode == '160000' then return end
  local blob = run(work_tree, { 'show', ':' .. entry.path }, { binary = true })
  local current = worktree_bytes(work_tree, entry)
  if blob.code ~= 0 or current == nil then return end
  local original = blob.stdout or ''
  if original:find('\0', 1, true) or current:find('\0', 1, true) then
    entry.binary = true
    return
  end
  local ok, hunks = pcall(vim.diff, original, current, { result_type = 'indices' })
  if not ok then return end
  entry.additions, entry.deletions = 0, 0
  for _, hunk in ipairs(hunks) do
    entry.deletions = entry.deletions + hunk[2]
    entry.additions = entry.additions + hunk[4]
  end
  local patch = vim.diff(original, current, { result_type = 'unified', ctxlen = 3 })
  entry.patch_lines = patch ~= ''
    and vim.split(patch:gsub('\n$', ''), '\n', { plain = true }) or {}
end

local function fingerprint(path)
  local stat = (vim.uv or vim.loop).fs_lstat(path)
  if not stat then return 'missing' end
  local function time(value)
    return value and (tostring(value.sec) .. ':' .. tostring(value.nsec)) or ''
  end
  return table.concat({ stat.type or '', stat.size or 0, stat.mode or 0,
    stat.ino or 0, time(stat.mtime), time(stat.ctime) }, ':')
end

local function index_path(work_tree)
  local result = run(work_tree, { 'rev-parse', '--git-path', 'index' })
  if result.code ~= 0 then return nil end
  local path = vim.trim(result.stdout or '')
  if path == '' then return nil end
  if not vim.startswith(path, '/') then path = vim.fs.joinpath(work_tree, path) end
  return path
end

local function unchanged(work_tree, previous)
  local cache = previous and previous.cache
  if not cache or cache.work_tree ~= work_tree then return false end
  if fingerprint(cache.index_path) ~= cache.index_fingerprint then return false end
  for _, entry in ipairs(previous.entries) do
    if entry.mode == '160000' then return false end
    if fingerprint(vim.fs.joinpath(work_tree, entry.path)) ~= cache.files[entry.path] then
      return false
    end
  end
  return true
end

function M.inspect(work_tree, previous)
  if unchanged(work_tree, previous) then return previous end
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
      entry.status = entry.state == 'missing' and 'D'
        or (entry.state == 'modified' and 'M' or '.')
      entry.section = 'index_flags'
      entry.line = change_display.line(entry)
      inspect_diff(work_tree, entry)
      if entry.state ~= 'clean' then state.changed_count = state.changed_count + 1 end
      table.insert(state.entries, entry)
    end
  end
  table.sort(state.entries, function(left, right) return left.path < right.path end)
  local path = previous and previous.cache and previous.cache.work_tree == work_tree
    and previous.cache.index_path or index_path(work_tree)
  if path then
    local files = {}
    for _, entry in ipairs(state.entries) do
      files[entry.path] = fingerprint(vim.fs.joinpath(work_tree, entry.path))
    end
    state.cache = {
      work_tree = work_tree,
      index_path = path,
      index_fingerprint = fingerprint(path),
      files = files,
    }
  end
  return state
end

function M.header_line(state)
  if not state or #state.entries == 0 then return nil end
  return ('Index flags [local] (%d)'):format(#state.entries)
end

function M.warning_line(state)
  if not state or state.changed_count == 0 then return nil end
  return ('Hidden changes: %d %s (Index flags)'):format(
    state.changed_count,
    state.changed_count == 1 and 'file' or 'files'
  )
end

function M.status_lines(state, expanded_paths)
  local header = M.header_line(state)
  if not header then return {} end
  local lines = { '', header }
  for _, entry in ipairs(state.entries) do
    table.insert(lines, entry.line)
    if expanded_paths and expanded_paths[entry.path] then
      vim.list_extend(lines, entry.patch_lines or {})
    end
  end
  return lines
end

function M.entry_from_line(state, line)
  for _, entry in ipairs(state and state.entries or {}) do
    if entry.line == line then return entry end
  end
  return nil
end

function M.entry_at_row(state, lines, row)
  if not state then return nil end
  local found, found_row
  for candidate = row, 1, -1 do
    local line = lines[candidate] or ''
    if line:match('^Index flags %[local%]') then return found, found_row end
    if line == '' then return nil end
    if not found then found, found_row = M.entry_from_line(state, line), candidate end
  end
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

-- Immutable commit data; only expanded files require patch collection.
local M = {}
function M.git(root, args, opts)
  local argv = { 'git', '--no-optional-locks', '-c', 'core.quotePath=false' }
  vim.list_extend(argv, args)
  opts = vim.tbl_extend('force', { cwd = root, text = false }, opts or {})
  local result = vim.system(argv, opts):wait()
  if result.code ~= 0 then
    local err = vim.trim(result.stderr or '')
    if err == '' then err = vim.trim(result.stdout or '') end
    if err == '' then err = 'git ' .. table.concat(args, ' ') .. ' failed (exit ' .. result.code .. ')' end
    return nil, err
  end
  return result.stdout or ''
end
local function nul(text) return vim.split(text, '\0', { plain = true, trimempty = true }) end
local function lines(text)
  local result = vim.split(text, '\n', { plain = true })
  if result[#result] == '' then table.remove(result) end
  return result
end
M.lines = lines
function M.load(root, revision, parent_index)
  local hash, err = M.git(root, { 'rev-parse', '--verify', '--end-of-options', revision .. '^{commit}' })
  if not hash then return nil, err end
  hash = vim.trim(hash)
  local info, info_err = M.git(root, { 'show', '-s', '--format=%H%x00%P%x00%an <%ae>%x00%ad%x00%B%x00%T%x00%cn <%ce>%x00%cd%x00%e', hash, '--' })
  if not info then return nil, info_err end
  local fields = vim.split(info, '\0', { plain = true })
  local parents = vim.split(fields[2], ' ', { trimempty = true })
  parent_index = parent_index or 1
  if #parents > 0 and not parents[parent_index] then return nil, 'Invalid parent index' end
  local base = parents[parent_index]
  if not base then base = vim.trim(assert(M.git(root, { 'hash-object', '-t', 'tree', '--stdin' }, { stdin = '' }))) end
  local message = lines(fields[5])
  local model = { root = root, hash = hash, parents = parents, parent_index = parent_index,
    base = base, author = fields[3], date = fields[4], message = message, entries = {},
    tree = fields[6], committer = fields[7], commit_date = fields[8], encoding = vim.trim(fields[9]) }
  local header, header_err = require('features.commit_info').header(root, hash)
  if not header then return nil, header_err end
  model.header = header
  local names, names_err = M.git(root, { 'diff', '--name-status', '-z', '--find-renames', '--no-ext-diff', base, hash, '--' })
  if not names then return nil, names_err end
  local records, i = nul(names), 1
  while i <= #records do
    local status, path = records[i]:sub(1, 1), records[i + 1]
    local entry = { status = status, path = path }
    i = i + 2
    if status == 'R' or status == 'C' then
      entry.old_path, entry.path = path, records[i]
      i = i + 1
    end
    model.entries[#model.entries + 1] = entry
  end
  local stats, stats_err = M.git(root, { 'diff', '--numstat', '-z', '--no-renames', '--no-ext-diff', base, hash, '--' })
  if not stats then return nil, stats_err end
  local by_path = {}
  for _, record in ipairs(nul(stats)) do
    local add, del, path = record:match('^([^\t]+)\t([^\t]+)\t(.*)$')
    if path then by_path[path] = { tonumber(add) or 0, tonumber(del) or 0, add == '-' } end
  end
  for _, entry in ipairs(model.entries) do
    entry.additions, entry.deletions, entry.binary = 0, 0, false
    for _, path in ipairs({ entry.path, entry.old_path }) do
      local stat = by_path[path]
      if stat then
        entry.additions, entry.deletions = entry.additions + stat[1], entry.deletions + stat[2]
        entry.binary = entry.binary or stat[3]
      end
    end
  end
  return model
end
function M.patch(model, entry)
  if entry.patch then return entry.patch end
  local args = { '--literal-pathspecs', 'diff', '--binary', '--full-index', '--no-color', '--no-ext-diff',
    '--no-textconv', '--find-renames', model.base, model.hash, '--', entry.path }
  if entry.old_path then args[#args + 1] = entry.old_path end
  local patch, err = M.git(model.root, args)
  if not patch then return nil, err end
  entry.patch = lines(patch)
  return entry.patch
end
function M.inline(model, entry)
  local patch, err = M.patch(model, entry)
  if not patch then return nil, err end
  if entry.binary then return { 'Binary file changed' } end
  for i, line in ipairs(patch) do
    if line:match('^@@') then return vim.list_slice(patch, i), i end
  end
  local result = {}
  for _, line in ipairs(patch) do
    if line:match('mode ') or line:match('^rename ') or line:match('^similarity ') then result[#result + 1] = line end
  end
  return result
end
return M

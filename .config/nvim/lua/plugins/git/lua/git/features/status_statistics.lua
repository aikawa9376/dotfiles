-- Diff statistics and cached raw-content counts for Status enrichment.
local M = {}
local fs = require('git.fs')
local caches = {}

local function run(work_tree, args)
  local command = { 'git', '--no-optional-locks' }
  vim.list_extend(command, args)
  return vim.system(command, { cwd = work_tree, text = false }):wait()
end

local function parse_numstat(work_tree, cached)
  local args = { 'diff', '--numstat', '-z', '--no-ext-diff', '--no-renames' }
  if cached then table.insert(args, '--cached') end
  local result = run(work_tree, args)
  if result.code ~= 0 then return {} end

  local stats = {}
  for record in (result.stdout or ''):gmatch('[^%z]+') do
    local added, deleted, path = record:match('^([^\t]+)\t([^\t]+)\t(.*)$')
    if path and path ~= '' then
      stats[path] = {
        additions = tonumber(added) or 0,
        deletions = tonumber(deleted) or 0,
        binary = added == '-' or deleted == '-',
      }
    end
  end
  return stats
end

local function attach_numstat(entries, stats)
  for _, entry in ipairs(entries) do
    local paths = { entry.path }
    if entry.old_path and entry.old_path ~= entry.path then table.insert(paths, entry.old_path) end

    local found = false
    local additions, deletions = 0, 0
    local binary = false
    for _, path in ipairs(paths) do
      local stat = stats[path]
      if stat then
        found = true
        additions = additions + stat.additions
        deletions = deletions + stat.deletions
        binary = binary or stat.binary
      end
    end
    if found then
      entry.additions = additions
      entry.deletions = deletions
      entry.binary = binary
    end
  end
end

local function untracked_numstat(path, stat)
  if not stat then return nil end
  if stat.type == 'link' then
    local target = vim.uv.fs_readlink(path)
    if not target then return nil end
    local _, count = target:gsub('\n', '')
    return count + (target ~= '' and target:sub(-1) ~= '\n' and 1 or 0), false
  end
  -- Do not follow symlinks or try to read directories and special files.
  if stat.type ~= 'file' then return nil end
  local file = io.open(path, 'rb')
  if not file then return nil end
  local count, last, first = 0, '', true
  while true do
    local chunk, err = file:read(65536)
    if err then file:close(); return nil end
    if not chunk then break end
    -- Match Git's default binary heuristic without loading the entire file.
    if first and chunk:sub(1, 8000):find('\0', 1, true) then
      file:close()
      return 0, true
    end
    first = false
    local _, newlines = chunk:gsub('\n', '')
    count = count + newlines
    last = chunk:sub(-1)
  end
  file:close()
  return count + (last ~= '' and last ~= '\n' and 1 or 0), false
end

function M.enrich(bufnr, model)
  for _, section in ipairs({ 'unstaged', 'staged' }) do
    if #model[section] > 0 then
      attach_numstat(model[section], parse_numstat(model.work_tree, section == 'staged'))
    end
  end

  local previous = caches[bufnr]
  local files = previous and previous.root == model.work_tree and previous.files or {}
  local retained = {}
  for _, entry in ipairs(model.untracked) do
    local path = vim.fs.joinpath(model.work_tree, entry.path)
    local stat = vim.uv.fs_lstat(path)
    local key = fs.stat_key(stat)
    local cached = files[entry.path]
    if not cached or cached.key ~= key then
      local additions, binary = untracked_numstat(path, stat)
      cached = { key = key, additions = additions, binary = binary }
      -- A writer may replace/change the file while it is being counted.
      -- Publish this observation, but only retain a stable successful read.
      if additions ~= nil and fs.fingerprint(path) == key then retained[entry.path] = cached end
    else
      retained[entry.path] = cached
    end
    entry.additions, entry.binary = cached.additions, cached.binary
    if entry.additions ~= nil then entry.deletions = 0 end
  end
  caches[bufnr] = { root = model.work_tree, files = retained }
end

function M.cleanup(bufnr) caches[bufnr] = nil end

return M

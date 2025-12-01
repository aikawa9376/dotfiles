-- logic/cache.lua
local M = {}

local state = require("lazyagent.logic.state")
local util = require("lazyagent.util")

--- Sanitizes a string to be used as a filename component.
-- Replaces non-alphanumeric characters (except for '-' and '_') with a hyphen.
-- @param s (string) The string to sanitize.
-- @return (string) The sanitized string.
local function sanitize_filename_component(s)
  if not s then return "" end
  s = tostring(s)
  -- Replace path separators and whitespace with hyphens; keep alnum, underscore and dash.
  s = s:gsub("[^%w-_]+", "-")
  return s
end

--- Gets the cache directory, creating it if it doesn't exist.
-- @return (string) The path to the cache directory.
local function get_cache_dir()
  local dir = (state.opts and state.opts.cache and state.opts.cache.dir) or (vim.fn.stdpath("cache") .. "/lazyagent")
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  return dir
end

--- Helper: parse history entries from a cache file (newer-first).
-- Expects a timestamp header line in the format "YYYY-MM-DD HH:MM:SS".
-- Each entry is represented as a table: { ts = string|nil, content = { <lines> } }.
-- @param path (string) The path to the cache file.
-- @return (table) A list of entries (newest-first).
local function parse_history_entries(path)
  if not path or vim.fn.filereadable(path) == 0 then return {} end
  local lines = vim.fn.readfile(path) or {}
  local entries = {}
  local i = 1
  while i <= #lines do
    -- Skip leading blank lines
    while i <= #lines and lines[i]:match("^%s*$") do i = i + 1 end
    if i > #lines then break end

    local ts = nil
    -- Recognize timestamp header line: "YYYY-MM-DD HH:MM:SS"
    if lines[i] and lines[i]:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$") then
      ts = lines[i]
      i = i + 1
      -- Optional blank line following the timestamp header
      if lines[i] == "" then i = i + 1 end
    end

    local content = {}
    while i <= #lines and not (lines[i] and lines[i]:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$")) do
      table.insert(content, lines[i])
      i = i + 1
    end
    -- Trim trailing blank lines from content
    while #content > 0 and content[#content]:match("^%s*$") do table.remove(content) end
    table.insert(entries, { ts = ts, content = content })
  end
  return entries
end

local function entries_to_lines(entries)
  local out = {}
  for _, e in ipairs(entries or {}) do
    local ts = e.ts or os.date("%Y-%m-%d %H:%M:%S")
    -- Simplified header format: single-line timestamp
    table.insert(out, ts)
    -- Keep a separating blank line between header and content for readability
    table.insert(out, "")
    for _, l in ipairs(e.content or {}) do table.insert(out, l) end
    table.insert(out, "")
  end
  return out
end

-- Trim trailing blank lines from a list of lines (returns a new table).
local function trim_trailing_blank(lines)
  local out = {}
  if not lines then return out end
  for _, l in ipairs(lines) do table.insert(out, l) end
  -- remove trailing blank lines
  while #out > 0 and out[#out]:match("^%s*$") do table.remove(out) end
  return out
end

-- Compare two list-of-lines tables for exact equality.
local function lines_equal(a, b)
  a = a or {}
  b = b or {}
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

--- Builds a cache filename based on the buffer's git context.
-- @param bufnr (number|nil) The buffer number (defaults to current).
-- @return (string) The generated cache filename.
local function build_cache_filename(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local bufn = vim.api.nvim_buf_get_name(bufnr) or ""
  local root = util.git_root_for_path(bufn) or vim.fn.getcwd()
  local rootname = vim.fn.fnamemodify(root, ":t") or "root"
  local branch = util.git_branch_for_path(bufn) or "no-branch"
  -- Keep history per branch+project (no date-based splitting); allow max_history to manage size.
  return sanitize_filename_component(branch) .. "-" .. sanitize_filename_component(rootname) .. "-history.log"
end

--- Writes the content of a scratch buffer to a cache file.
-- The newest entry will be written to the top of the cache file so it appears first.
-- @param bufnr (number|nil) The buffer number (defaults to current).
function M.write_scratch_to_cache(bufnr)
  if not (state.opts and state.opts.cache and state.opts.cache.enabled) then
    return
  end
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- Do not write when we are currently applying history to this buffer.
  local ok_flag, applying = pcall(function() return vim.b[bufnr] and vim.b[bufnr].lazyagent_history_apply_in_progress end)
  if ok_flag and applying then
    return
  end

  local dir = get_cache_dir()
  local filename = build_cache_filename(bufnr)
  local path = dir .. "/" .. filename

  -- Read current buffer content and normalize by trimming trailing blank lines
  local content = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) or {}
  -- Do not write empty or whitespace-only buffers
  local has_non_whitespace = false
  for _, l in ipairs(content) do
    if l and l:match("%S") then
      has_non_whitespace = true
      break
    end
  end
  if not has_non_whitespace then
    return
  end

  local trimmed = trim_trailing_blank(content)
  local ts = os.date("%Y-%m-%d %H:%M:%S")
  local new_entry = { ts = ts, content = trimmed }

  -- Read existing entries (newest-first)
  local existing = parse_history_entries(path)

  -- If the newest entry matches exactly, do not write duplicate. Also ensure idx points to latest.
  if existing[1] and lines_equal(existing[1].content or {}, new_entry.content or {}) then
    pcall(function() vim.b[bufnr].lazyagent_history_idx = 1 end)
    return
  end

  -- Prepend and trim to max_history.
  table.insert(existing, 1, new_entry)
  local max_history = (state.opts and state.opts.cache and state.opts.cache.max_history) or 50
  while #existing > max_history do
    table.remove(existing) -- removes last (oldest) entry
  end

  local merged = entries_to_lines(existing)
  local ok = pcall(vim.fn.writefile, merged, path)
  if ok then
    pcall(function() vim.b[bufnr].lazyagent_history_idx = 1 end)
  end
end

--- Lists all cache files, sorted by modification time (newest first).
-- @return (table) A list of cache file entries.
local function list_cache_files()
  local dir = get_cache_dir()
  if not dir or vim.fn.isdirectory(dir) == 0 then
    return {}
  end
  local raw = vim.fn.readdir(dir) or {}
  local entries = {}
  for _, f in ipairs(raw) do
    if f:match("%.log$") then
      local path = dir .. "/" .. f
      local mtime = vim.fn.getftime(path) or 0
      table.insert(entries, { name = f, path = path, mtime = mtime })
    end
  end
  -- Sort by newest first
  table.sort(entries, function(a, b) return (a.mtime or 0) > (b.mtime or 0) end)
  return entries
end

--- Lists all cache Conversation files, sorted by modification time (newest first).
-- @return (table) entries: list of { name, path, mtime }, choices: list of strings suitable for vim.ui.select
function M.list_cache_Conversation()
  local dir = get_cache_dir()
  if not dir or vim.fn.isdirectory(dir) == 0 then
    return {}, {}
  end

  local raw = vim.fn.readdir(dir) or {}
  local raws = {}
  local entries = {}

  for _, f in ipairs(raw) do
    local fname_lower = (f or ""):lower()
    -- Match filenames like "<agent>-conversation-2024-... .log" (case-insensitive)
    if fname_lower:match("%-conversation%-.+%.log$") then
      local path = dir .. "/" .. f
      local mtime = vim.fn.getftime(path) or 0
      table.insert(raws, { name = f, path = path, mtime = mtime })
    end
  end

  table.sort(raws, function(a, b) return (a.mtime or 0) > (b.mtime or 0) end)

  for _, e in ipairs(raws) do
    table.insert(entries, e.name)
  end

  return M.get_cache_dir(), entries
end

--- Opens the agent history in a selection UI.
function M.open_history()
  local entries = list_cache_files()
  if not entries or #entries == 0 then
    vim.notify("LazyAgentHistory: no cache history found in " .. get_cache_dir(), vim.log.levels.INFO)
    return
  end

  local choices = {}
  for _, e in ipairs(entries) do
    table.insert(choices, e.name .. " (" .. os.date("%Y-%m-%d %H:%M:%S", e.mtime or 0) .. ")")
  end

  vim.ui.select(choices, { prompt = "Open lazyagent history:" }, function(choice, idx)
    if not choice or not idx then return end
    local entry = entries[idx]
    if entry and entry.path then
      vim.schedule(function()
        -- Open the selected file into a buffer
        vim.cmd("edit " .. vim.fn.fnameescape(entry.path))
      end)
    end
  end)
end

-- Expose helpers for other modules to locate cache files and prefixes.
M.get_cache_dir = get_cache_dir
M.build_cache_filename = build_cache_filename
M.list_cache_files = list_cache_files

local function get_cache_path(bufnr)
  return get_cache_dir() .. "/" .. build_cache_filename(bufnr)
end
M.get_cache_path = get_cache_path

-- Read the parsed history entries (newest-first) for a buffer's branch/project.
-- @param bufnr (number|nil) Buffer to derive project from (defaults to current).
-- @return (table) list of entries { ts=string|nil, content={...} }
M.read_history_entries = function(bufnr)
  local path = get_cache_path(bufnr)
  return parse_history_entries(path)
end

-- Get a single history entry (by 1-based index) for buffer's cache file.
-- @param bufnr (number|nil) Buffer to derive project from (defaults to current).
-- @param idx (number) 1-based index into the newest-first entries (1 = newest).
-- @return (table|nil) entry or nil if missing.
M.get_history_entry = function(bufnr, idx)
  local entries = M.read_history_entries(bufnr) or {}
  return entries[idx]
end

-- Apply (replace) the buffer contents with a given history entry.
-- Returns true on success, false otherwise.
M.apply_history_entry_to_buf = function(bufnr, idx)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return false end
  local entry = M.get_history_entry(bufnr, idx)
  if not entry then return false end

  -- Suppress autosave while applying history content to avoid duplicating cache entries.
  local prev_flag = nil
  pcall(function() prev_flag = vim.b[bufnr] and vim.b[bufnr].lazyagent_history_apply_in_progress end)
  pcall(function() vim.b[bufnr].lazyagent_history_apply_in_progress = true end)
  local ok = pcall(function() vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, entry.content or {}) end)
  pcall(function() vim.b[bufnr].lazyagent_history_apply_in_progress = prev_flag end)

  if ok then
    pcall(function() vim.b[bufnr].lazyagent_history_idx = idx end)
    return true
  end
  return false
end

local function get_history_list_buf_for_target(target_buf)
  -- If target is a scratch buffer and has an associated source, use the source buffer's
  -- history; otherwise use the target buffer itself.
  if target_buf and target_buf > 0 and vim.api.nvim_buf_is_valid(target_buf) then
    local src = (vim.b[target_buf] and vim.b[target_buf].lazyagent_source_bufnr) or nil
    if src and src > 0 and vim.api.nvim_buf_is_valid(src) then
      return src
    end
  end
  return target_buf
end
M.get_history_list_buf_for_target = get_history_list_buf_for_target

--- Apply a history entry to a target buffer using the history associated with the list buffer
-- (if the target has a source buffer associated the source's history is used).
-- Returns (ok, total_entries)
M.apply_history_entry_to_target_buf = function(target_buf, idx)
  if not target_buf or not vim.api.nvim_buf_is_valid(target_buf) then
    return false, 0
  end
  local list_buf = get_history_list_buf_for_target(target_buf) or target_buf
  local entries = M.read_history_entries(list_buf) or {}
  if not entries or #entries == 0 then
    return false, 0
  end

  idx = idx or 1
  if idx < 1 or idx > #entries then
    return false, #entries
  end

  local entry = M.get_history_entry(list_buf, idx)
  if not entry or not entry.content then
    return false, #entries
  end

  -- Suppress autosave on apply to avoid duplicate cache writes.
  local prev_flag = nil
  pcall(function() prev_flag = vim.b[target_buf] and vim.b[target_buf].lazyagent_history_apply_in_progress end)
  pcall(function() vim.b[target_buf].lazyagent_history_apply_in_progress = true end)
  local ok = pcall(function() vim.api.nvim_buf_set_lines(target_buf, 0, -1, false, entry.content or {}) end)
  pcall(function() vim.b[target_buf].lazyagent_history_apply_in_progress = prev_flag end)

  if ok then
    pcall(function() vim.b[target_buf].lazyagent_history_idx = idx end)
    return true, #entries
  end
  return false, #entries
end

local function build_cache_prefix(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local bufn = vim.api.nvim_buf_get_name(bufnr) or ""
  local root = util.git_root_for_path(bufn) or vim.fn.getcwd()
  local rootname = vim.fn.fnamemodify(root, ":t") or "root"
  local branch = util.git_branch_for_path(bufn) or "no-branch"
  return sanitize_filename_component(branch) .. "-" .. sanitize_filename_component(rootname) .. "-"
end
M.build_cache_prefix = build_cache_prefix

return M

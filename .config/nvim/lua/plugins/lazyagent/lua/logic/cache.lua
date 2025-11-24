-- logic/cache.lua
local M = {}

local state = require("logic.state")
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

--- Builds a cache filename based on the buffer's git context.
-- @param bufnr (number|nil) The buffer number (defaults to current).
-- @return (string) The generated cache filename.
local function build_cache_filename(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local bufn = vim.api.nvim_buf_get_name(bufnr) or ""
  local root = util.git_root_for_path(bufn) or vim.fn.getcwd()
  local rootname = vim.fn.fnamemodify(root, ":t") or "root"
  local branch = util.git_branch_for_path(bufn) or "no-branch"
  local date = os.date("%Y-%m-%d")
  return sanitize_filename_component(branch) .. "-" .. sanitize_filename_component(rootname) .. "-" .. date .. ".log"
end

--- Writes the content of a scratch buffer to a cache file.
-- @param bufnr (number|nil) The buffer number (defaults to current).
function M.write_scratch_to_cache(bufnr)
  if not (state.opts and state.opts.cache and state.opts.cache.enabled) then
    return
  end
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local dir = get_cache_dir()
  local filename = build_cache_filename(bufnr)
  local path = dir .. "/" .. filename

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

  local ts = os.date("%Y-%m-%d %H:%M:%S")
  local header = { string.format("===== scratch saved at %s =====", ts), "" }
  local to_write = {}
  for _, h in ipairs(header) do table.insert(to_write, h) end
  for _, l in ipairs(content) do table.insert(to_write, l) end
  table.insert(to_write, "") -- newline
  pcall(vim.fn.writefile, to_write, path, "a")
end

--- Attaches autocmds to a buffer for automatic cache saving.
-- @param bufnr (number|nil) The buffer number (defaults to current).
function M.attach_cache_autocmds(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  if not (state.opts and state.opts.cache and state.opts.cache.enabled) then return end
  local gid = vim.api.nvim_create_augroup("LazyAgentScratchCache-" .. tostring(bufnr), { clear = true })
  local debounce_ms = (state.opts.cache and state.opts.cache.debounce_ms) or 1000
  local scheduled = false
  local function schedule_write()
    if scheduled then return end
    scheduled = true
    vim.defer_fn(function()
      scheduled = false
      M.write_scratch_to_cache(bufnr)
    end, debounce_ms)
  end

  vim.api.nvim_create_autocmd({ "BufWritePost", "BufLeave", "InsertLeave", "TextChanged" }, {
    group = gid,
    buffer = bufnr,
    callback = function() schedule_write() end,
  })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = gid,
    buffer = bufnr,
    callback = function()
      M.write_scratch_to_cache(bufnr)
      pcall(vim.api.nvim_del_augroup_by_id, gid)
    end,
  })
end
M.attach_cache_to_buf = M.attach_cache_autocmds -- alias for backward compatibility

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

local function build_cache_prefix(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local bufn = vim.api.nvim_buf_get_name(bufnr) or ""
  local root = util.git_root_for_path(bufn) or vim.fn.getcwd()
  local rootname = vim.fn.fnamemodify(root, ":t") or "root"
  local branch = util.git_branch_for_path(bufn) or "no-branch"
  return sanitize_filename_component(branch) .. "-" .. sanitize_filename_component(rootname) .. "-"
end
M.build_cache_prefix = build_cache_prefix

local function get_cache_path(bufnr)
  return get_cache_dir() .. "/" .. build_cache_filename(bufnr)
end
M.get_cache_path = get_cache_path

return M

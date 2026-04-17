local M = {}

local state = require("lazyagent.logic.state")
local uv = vim.uv or vim.loop

local DEFAULT_FLUSH_DEBOUNCE_MS = 150

local cache_loaded = false
local cache_data = {}
local cache_encoded = nil
local dirty = false
local flush_timer = nil

local function stop_flush_timer()
  if flush_timer then
    pcall(function()
      flush_timer:stop()
      flush_timer:close()
    end)
    flush_timer = nil
  end
end

local function get_persistence_file()
  local dir = (state.opts and state.opts.cache and state.opts.cache.dir) or (vim.fn.stdpath("cache") .. "/lazyagent")
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  return dir .. "/sessions.json"
end

local function read_from_disk()
  local path = get_persistence_file()
  if vim.fn.filereadable(path) == 0 then
    cache_loaded = true
    cache_data = {}
    cache_encoded = nil
    return cache_data
  end

  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or not lines or #lines == 0 then
    cache_loaded = true
    cache_data = {}
    cache_encoded = nil
    return cache_data
  end

  local json = table.concat(lines, "")
  local ok_decode, data = pcall(vim.fn.json_decode, json)
  cache_loaded = true
  if not ok_decode or type(data) ~= "table" then
    cache_data = {}
    cache_encoded = nil
    return cache_data
  end

  cache_data = data
  cache_encoded = json
  return cache_data
end

local function ensure_loaded()
  if cache_loaded then
    return cache_data
  end
  return read_from_disk()
end

local function write_to_disk(data)
  local path = get_persistence_file()
  local ok, encoded = pcall(vim.fn.json_encode, data)
  if not ok or not encoded then
    return false
  end

  if encoded == cache_encoded then
    dirty = false
    return true
  end

  local ok_write = pcall(vim.fn.writefile, { encoded }, path)
  if ok_write then
    cache_encoded = encoded
    dirty = false
    return true
  end

  return false
end

local function flush_now()
  stop_flush_timer()
  if not dirty then
    return true
  end
  return write_to_disk(cache_data)
end

local function flush_debounce_ms()
  local value = state.opts
    and state.opts.cache
    and state.opts.cache.persistence_debounce_ms
  if type(value) == "number" and value >= 0 then
    return value
  end
  return DEFAULT_FLUSH_DEBOUNCE_MS
end

local function schedule_flush()
  dirty = true
  local delay = flush_debounce_ms()
  if delay == 0 then
    flush_now()
    return
  end

  stop_flush_timer()
  flush_timer = uv.new_timer()
  flush_timer:start(delay, 0, function()
    vim.schedule(flush_now)
  end)
end

pcall(function()
  local group = vim.api.nvim_create_augroup("LazyAgentPersistence", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = flush_now,
    desc = "Flush lazyagent session persistence",
  })
end)

function M.load()
  return vim.deepcopy(ensure_loaded())
end

function M.save(data)
  cache_loaded = true
  cache_data = type(data) == "table" and vim.deepcopy(data) or {}
  schedule_flush()
end

function M.update_session(agent_name, pane_id, cwd)
  local data = ensure_loaded()
  cwd = cwd or vim.fn.getcwd()
  local key = agent_name .. "::" .. cwd
  data[key] = pane_id
  schedule_flush()
end

function M.remove_session(agent_name, cwd)
  local data = ensure_loaded()
  cwd = cwd or vim.fn.getcwd()
  local key = agent_name .. "::" .. cwd
  if data[key] == nil then
    return
  end
  data[key] = nil
  schedule_flush()
end

function M.get_session(agent_name, cwd)
  local data = ensure_loaded()
  cwd = cwd or vim.fn.getcwd()
  local key = agent_name .. "::" .. cwd
  return data[key]
end

function M.flush()
  return flush_now()
end

return M

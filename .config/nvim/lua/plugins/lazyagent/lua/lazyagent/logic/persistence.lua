local M = {}

local state = require("lazyagent.logic.state")

local function get_persistence_file()
  local dir = (state.opts and state.opts.cache and state.opts.cache.dir) or (vim.fn.stdpath("cache") .. "/lazyagent")
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  return dir .. "/sessions.json"
end

function M.load()
  local path = get_persistence_file()
  if vim.fn.filereadable(path) == 0 then return {} end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or not lines or #lines == 0 then return {} end
  local json = table.concat(lines, "")
  local ok_decode, data = pcall(vim.fn.json_decode, json)
  if not ok_decode or type(data) ~= "table" then return {} end
  return data
end

function M.save(data)
  local path = get_persistence_file()
  local ok, encoded = pcall(vim.fn.json_encode, data)
  if ok and encoded then
    pcall(vim.fn.writefile, { encoded }, path)
  end
end

function M.update_session(agent_name, pane_id, cwd)
  local data = M.load()
  cwd = cwd or vim.fn.getcwd()
  local key = agent_name .. "::" .. cwd
  data[key] = pane_id
  M.save(data)
end

function M.remove_session(agent_name, cwd)
  local data = M.load()
  cwd = cwd or vim.fn.getcwd()
  local key = agent_name .. "::" .. cwd
  data[key] = nil
  M.save(data)
end

function M.get_session(agent_name, cwd)
  local data = M.load()
  cwd = cwd or vim.fn.getcwd()
  local key = agent_name .. "::" .. cwd
  return data[key]
end

return M

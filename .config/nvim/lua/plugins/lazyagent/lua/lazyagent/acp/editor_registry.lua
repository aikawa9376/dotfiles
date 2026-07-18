local M = {}

local state = require("lazyagent.logic.state")
local cache_logic = require("lazyagent.logic.cache")
local util = require("lazyagent.util")

local record
local record_path
local heartbeat_timer
local augroup

local function normalize_path(path)
  path = tostring(path or "")
  if path == "" then return nil end
  return vim.fn.fnamemodify(path, ":p"):gsub("/$", "")
end

local function registry_dir()
  local dir = cache_logic.get_cache_dir() .. "/acp/editors"
  if vim.fn.isdirectory(dir) == 0 then vim.fn.mkdir(dir, "p") end
  pcall((vim.uv or vim.loop).fs_chmod, dir, 448)
  return dir
end

local function read_json(path)
  if vim.fn.filereadable(path) ~= 1 then return nil end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or not lines or #lines == 0 then return nil end
  local decoded, value = pcall(vim.json.decode, table.concat(lines, ""))
  return decoded and type(value) == "table" and value or nil
end

local function write_json(path, value)
  local ok, encoded = pcall(vim.json.encode, value)
  if not ok then return false end
  local written = pcall(vim.fn.writefile, { encoded }, path)
  if written then pcall((vim.uv or vim.loop).fs_chmod, path, 384) end
  return written
end

local function workspace_roots()
  local roots = {}
  local seen = {}
  local function add(path)
    path = normalize_path(path)
    if path and not seen[path] and vim.fn.isdirectory(path) == 1 then
      seen[path] = true
      roots[#roots + 1] = path
    end
  end

  add(util.git_root_for_path(vim.fn.getcwd()) or vim.fn.getcwd())
  for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
    local bufnr = tonumber(info.bufnr)
    local explicit = bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.b[bufnr].lazyagent_workspace_root or nil
    add(explicit)
    if info.name and info.name ~= "" then
      add(util.git_root_for_path(info.name))
    end
  end
  table.sort(roots)
  return roots
end

local function current_source_path()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].buftype ~= "" then return "" end
  return vim.api.nvim_buf_get_name(bufnr)
end

local function refresh_record(focused)
  if not record or not record_path then return false end
  record.roots = workspace_roots()
  record.updated_at = os.time()
  record.source_path = current_source_path()
  if focused then record.focused_at = record.updated_at end
  return write_json(record_path, record)
end

function M.stop()
  if heartbeat_timer then
    pcall(function() heartbeat_timer:stop() end)
    pcall(function() heartbeat_timer:close() end)
    heartbeat_timer = nil
  end
  local server = record and record.server or nil
  if record_path then pcall(vim.fn.delete, record_path) end
  if server then
    pcall(vim.fn.serverstop, server)
    pcall(vim.fn.delete, server)
  end
  record = nil
  record_path = nil
  return true
end

local function has_root(candidate, root)
  root = normalize_path(root)
  for _, candidate_root in ipairs(candidate.roots or {}) do
    if normalize_path(candidate_root) == root then return true end
  end
  return false
end

local function label(candidate)
  local source = tostring(candidate.source_path or "")
  local suffix = source ~= "" and (" · " .. vim.fn.fnamemodify(source, ":~:.")) or ""
  local local_marker = candidate.instance_id == state.editor_instance_id and " · current" or ""
  return string.format("Neovim pid:%s%s%s", tostring(candidate.pid or "?"), local_marker, suffix)
end

function M.setup()
  if record then
    refresh_record(true)
    return true
  end

  local instance_id = tostring(state.editor_instance_id or "")
  if instance_id == "" then return false end
  local key = vim.fn.sha256(instance_id):sub(1, 20)
  local dir = registry_dir()
  local address = dir .. "/" .. key .. ".sock"
  local ok_server, server = pcall(vim.fn.serverstart, address)
  if not ok_server or type(server) ~= "string" or server == "" then
    return false, tostring(server or "failed to start Neovim RPC server")
  end
  pcall((vim.uv or vim.loop).fs_chmod, server, 384)

  record_path = dir .. "/" .. key .. ".json"
  record = {
    instance_id = instance_id,
    pid = vim.fn.getpid(),
    server = server,
    token = vim.fn.sha256(instance_id .. ":" .. tostring((vim.uv or vim.loop).hrtime())),
    roots = {},
    updated_at = os.time(),
    focused_at = os.time(),
  }
  refresh_record(true)

  augroup = vim.api.nvim_create_augroup("LazyAgentACPEditorRegistry", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "DirChanged", "FocusGained", "VimResume" }, {
    group = augroup,
    callback = function() vim.schedule(function() refresh_record(true) end) end,
    desc = "Refresh LazyAgent ACP editor workspace presence",
  })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = augroup,
    callback = function() vim.schedule(function() refresh_record(false) end) end,
    desc = "Refresh LazyAgent ACP editor workspaces after buffer removal",
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    callback = function()
      M.stop()
    end,
    desc = "Remove LazyAgent ACP editor workspace presence",
  })

  heartbeat_timer = (vim.uv or vim.loop).new_timer()
  heartbeat_timer:start(10000, 10000, vim.schedule_wrap(function() refresh_record(false) end))
  return true
end

function M.targets(root)
  root = normalize_path(root)
  if not root then return {} end
  if record then refresh_record(false) end
  local candidates = {}
  local now = os.time()
  for _, name in ipairs(vim.fn.readdir(registry_dir())) do
    if name:match("%.json$") then
      local path = registry_dir() .. "/" .. name
      local candidate = read_json(path)
      if candidate
        and type(candidate.server) == "string"
        and candidate.server ~= ""
        and now - tonumber(candidate.updated_at or 0) <= 30
        and has_root(candidate, root)
      then
        candidate.label = label(candidate)
        candidates[#candidates + 1] = candidate
      elseif candidate and now - tonumber(candidate.updated_at or 0) > 30 then
        pcall(vim.fn.delete, path)
      end
    end
  end
  table.sort(candidates, function(left, right)
    if left.instance_id == state.editor_instance_id then return true end
    if right.instance_id == state.editor_instance_id then return false end
    return tonumber(left.focused_at or 0) > tonumber(right.focused_at or 0)
  end)
  return candidates
end

function M.dispatch(request)
  if type(request) ~= "table" or request.action ~= "create_agent" then
    return { ok = false, error = "unsupported editor request" }
  end
  if not record or request.token ~= record.token then
    return { ok = false, error = "editor request authentication failed" }
  end
  refresh_record(false)
  local root = normalize_path(request.root)
  if not root or not has_root(record, root) then
    return { ok = false, error = "workspace is not open in this Neovim" }
  end
  local provider = tostring(request.provider or "")
  if not vim.tbl_contains(require("lazyagent.logic.agent").available_acp_agents(), provider) then
    return { ok = false, error = "ACP provider is not configured: " .. provider }
  end
  vim.schedule(function()
    require("lazyagent.logic.session").new_acp_thread_in_workspace(provider, root)
  end)
  return { ok = true }
end

function M.request_create_agent(candidate, provider, root)
  if type(candidate) ~= "table" then return false, "invalid Neovim target" end
  local request = {
    action = "create_agent",
    token = candidate.token,
    provider = provider,
    root = normalize_path(root),
  }
  if candidate.instance_id == state.editor_instance_id then
    local response = M.dispatch(request)
    return response.ok == true, response.error
  end

  local ok_connect, channel = pcall(vim.fn.sockconnect, "pipe", candidate.server, { rpc = true })
  if not ok_connect or tonumber(channel or 0) <= 0 then
    return false, "target Neovim is no longer reachable"
  end
  local ok_request, response = pcall(
    vim.rpcrequest,
    channel,
    "nvim_exec_lua",
    "return require('lazyagent.acp.editor_registry').dispatch(...)",
    { request }
  )
  pcall(vim.fn.chanclose, channel)
  if not ok_request or type(response) ~= "table" then
    return false, "target Neovim rejected the request"
  end
  return response.ok == true, response.error
end

return M

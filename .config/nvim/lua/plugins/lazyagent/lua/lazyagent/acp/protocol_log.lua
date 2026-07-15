local M = {}
local Log = {}
Log.__index = Log

local function sensitive_key(key)
  key = tostring(key or ""):lower()
  return key == "env" or key == "headers" or key:match("authorization")
    or key:match("token") or key:match("secret") or key:match("password") or key:match("api[_-]?key")
end

local function sanitize(value, key, seen)
  if sensitive_key(key) then return "<redacted>" end
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return "<cycle>" end
  seen[value] = true
  local out = {}
  for child_key, child in pairs(value) do out[child_key] = sanitize(child, child_key, seen) end
  seen[value] = nil
  return out
end

function M.sanitize(message)
  return sanitize(vim.deepcopy(message or {}), nil, {})
end

function M.new(path)
  return setmetatable({ path = path, queue = {}, scheduled = false }, Log)
end

function Log:flush()
  self.scheduled = false
  if #self.queue == 0 or not self.path or self.path == "" then return true end
  local lines = self.queue
  self.queue = {}
  vim.fn.mkdir(vim.fs.dirname(self.path), "p")
  local ok, err = pcall(vim.fn.writefile, lines, self.path, "a")
  if ok then pcall(vim.uv.fs_chmod, self.path, 384) end
  return ok and true or nil, ok and nil or err
end

function Log:record(direction, message)
  self.queue[#self.queue + 1] = vim.json.encode({
    timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    direction = direction,
    message = M.sanitize(message),
  })
  if not self.scheduled then
    self.scheduled = true
    vim.schedule(function() self:flush() end)
  end
end

function M.read(path)
  if not path or vim.fn.filereadable(path) ~= 1 then return {} end
  local records = {}
  for _, line in ipairs(vim.fn.readfile(path)) do
    local ok, record = pcall(vim.json.decode, line)
    if ok and type(record) == "table" then records[#records + 1] = record end
  end
  return records
end

function M.viewer_lines(path)
  local lines = { "LazyAgent ACP Protocol Log", tostring(path or ""), "" }
  for _, record in ipairs(M.read(path)) do
    local message = record.message or {}
    local summary = message.method or (message.error and "error") or (message.result ~= nil and "response") or "message"
    lines[#lines + 1] = string.format("%s %s %s id=%s", record.timestamp or "", record.direction or "?", summary,
      message.id == nil and "-" or tostring(message.id))
    lines[#lines + 1] = vim.json.encode(message)
  end
  return lines
end

function M.open(path)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "lazyagent://acp/protocol-log")
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, M.viewer_lines(path))
  vim.bo[bufnr].filetype = "jsonl"
  vim.bo[bufnr].modifiable = false
  vim.cmd("botright new")
  vim.api.nvim_win_set_buf(0, bufnr)
  return bufnr
end

return M

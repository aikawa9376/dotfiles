local M = {}

local uv = vim.uv or vim.loop
local TurnJournal = require("lazyagent.acp.turn_journal")
local SCHEMA_VERSION = 1
local STATUS = {
  active = true,
  closed = true,
  archived = true,
  failed = true,
}

local Store = {}
Store.__index = Store

local function now_utc()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function json_encode(value)
  return vim.json and vim.json.encode and vim.json.encode(value) or vim.fn.json_encode(value)
end

local function json_decode(value)
  return vim.json and vim.json.decode and vim.json.decode(value) or vim.fn.json_decode(value)
end

local function uuid_v4()
  local bytes, err = uv.random(16)
  if not bytes then
    return nil, err or "secure random generation failed"
  end
  local values = { bytes:byte(1, 16) }
  values[7] = bit.bor(bit.band(values[7], 0x0f), 0x40)
  values[9] = bit.bor(bit.band(values[9], 0x3f), 0x80)
  return string.format(
    "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
    unpack(values)
  )
end

local function valid_uuid(value)
  if type(value) ~= "string" or #value ~= 36 then
    return false
  end
  local first, second, third, fourth, fifth = value:match(
    "^([0-9a-fA-F]+)%-([0-9a-fA-F]+)%-([0-9a-fA-F]+)%-([0-9a-fA-F]+)%-([0-9a-fA-F]+)$"
  )
  return first ~= nil
    and #first == 8
    and #second == 4
    and #third == 4
    and third:sub(1, 1):lower() == "4"
    and #fourth == 4
    and fourth:sub(1, 1):match("[89aAbB]") ~= nil
    and #fifth == 12
end

local function copy(value)
  return vim.deepcopy(value)
end

local function normalize_directories(value)
  local result = {}
  local seen = {}
  for _, path in ipairs(type(value) == "table" and value or {}) do
    path = tostring(path or "")
    if path ~= "" then
      path = vim.fn.fnamemodify(path, ":p"):gsub("/$", "")
      if not seen[path] then
        seen[path] = true
        result[#result + 1] = path
      end
    end
  end
  return result
end

local function normalize_record(record, opts)
  opts = opts or {}
  if type(record) ~= "table" then
    return nil, "thread record must be a table"
  end
  if not valid_uuid(record.thread_id) then
    return nil, "thread_id must be a UUID v4"
  end
  local provider_id = tostring(record.provider_id or "")
  if provider_id == "" then
    return nil, "provider_id is required"
  end
  local status = tostring(record.status or "active")
  if not STATUS[status] then
    return nil, "invalid thread status: " .. status
  end

  local created_at = tostring(record.created_at or opts.now or now_utc())
  local updated_at = tostring(record.updated_at or created_at)
  local normalized = {
    thread_id = record.thread_id:lower(),
    provider_id = provider_id,
    cwd = vim.fn.fnamemodify(tostring(record.cwd or vim.fn.getcwd()), ":p"):gsub("/$", ""),
    additional_directories = normalize_directories(record.additional_directories),
    title = tostring(record.title or provider_id),
    status = status,
    created_at = created_at,
    updated_at = updated_at,
    transcript_path = tostring(record.transcript_path or ""),
    draft = tostring(record.draft or ""),
    unread = record.unread == true,
    config = type(record.config) == "table" and copy(record.config) or {},
    checkpoint = type(record.checkpoint) == "table" and copy(record.checkpoint) or {},
    change_journal = type(record.change_journal) == "table" and TurnJournal.compact(record.change_journal) or {},
    view_state = type(record.view_state) == "table" and copy(record.view_state) or {},
    metadata = type(record.metadata) == "table" and copy(record.metadata) or {},
  }
  for _, field in ipairs({ "native_session_id", "process_id", "model", "mode", "archived_at" }) do
    if record[field] ~= nil and record[field] ~= "" then
      normalized[field] = record[field]
    end
  end
  if status == "archived" and not normalized.archived_at then
    normalized.archived_at = updated_at
  elseif status ~= "archived" then
    normalized.archived_at = nil
  end
  return normalized
end

local function empty_manifest(timestamp)
  return {
    schema_version = SCHEMA_VERSION,
    updated_at = timestamp or now_utc(),
    threads = {},
  }
end

local function validate_manifest(manifest)
  if type(manifest) ~= "table" then
    return nil, "manifest must be a table"
  end
  if manifest.schema_version ~= SCHEMA_VERSION then
    return nil, "unsupported thread manifest schema: " .. tostring(manifest.schema_version)
  end
  if type(manifest.threads) ~= "table" then
    return nil, "manifest threads must be a table"
  end
  local normalized = empty_manifest(tostring(manifest.updated_at or now_utc()))
  local seen = {}
  for _, record in ipairs(manifest.threads) do
    local item, err = normalize_record(record)
    if not item then
      return nil, err
    end
    if seen[item.thread_id] then
      return nil, "duplicate thread_id: " .. item.thread_id
    end
    seen[item.thread_id] = true
    normalized.threads[#normalized.threads + 1] = item
  end
  return normalized
end

local function thread_index(manifest, thread_id)
  for index, record in ipairs(manifest.threads) do
    if record.thread_id == thread_id then
      return index, record
    end
  end
  return nil, nil
end

function Store:_timestamp()
  return self.clock()
end

function Store:_ensure_dir()
  if vim.fn.isdirectory(self.dir) == 0 then
    local ok, result = pcall(vim.fn.mkdir, self.dir, "p", 448)
    if not ok or result == 0 then
      return nil, ok and ("failed to create thread store: " .. self.dir) or result
    end
  end
  return true
end

function Store:_quarantine(reason)
  local suffix = self:_timestamp():gsub("[^%w]", "")
  local target = self.path .. ".corrupt-" .. suffix
  local ok, err = uv.fs_rename(self.path, target)
  if not ok then
    return nil, err or reason
  end
  return target, nil
end

function Store:_read()
  if vim.fn.filereadable(self.path) == 0 then
    return empty_manifest(self:_timestamp())
  end
  local ok_read, lines = pcall(vim.fn.readfile, self.path)
  if not ok_read then
    return nil, lines
  end
  local ok_decode, decoded = pcall(json_decode, table.concat(lines, "\n"))
  if not ok_decode then
    local quarantined, quarantine_err = self:_quarantine(decoded)
    return empty_manifest(self:_timestamp()), {
      code = "corrupt_manifest",
      message = tostring(decoded),
      quarantined_path = quarantined,
      quarantine_error = quarantine_err,
    }
  end
  if type(decoded) == "table" and decoded.schema_version ~= SCHEMA_VERSION then
    return nil, "unsupported thread manifest schema: " .. tostring(decoded.schema_version)
  end
  local manifest, err = validate_manifest(decoded)
  if not manifest then
    local quarantined, quarantine_err = self:_quarantine(err)
    return empty_manifest(self:_timestamp()), {
      code = "invalid_manifest",
      message = err,
      quarantined_path = quarantined,
      quarantine_error = quarantine_err,
    }
  end
  return manifest
end

function Store:_write(manifest)
  local ok_dir, dir_err = self:_ensure_dir()
  if not ok_dir then
    return nil, dir_err
  end
  manifest.updated_at = self:_timestamp()
  local ok_encode, encoded = pcall(json_encode, manifest)
  if not ok_encode then
    return nil, encoded
  end
  local suffix = tostring(vim.fn.getpid()) .. "." .. tostring(uv.hrtime())
  local temporary = self.path .. ".tmp." .. suffix
  local ok_write, write_err = pcall(vim.fn.writefile, { encoded }, temporary)
  if not ok_write then
    return nil, write_err
  end
  if uv.fs_chmod then
    pcall(uv.fs_chmod, temporary, 384)
  end
  local renamed, rename_err = uv.fs_rename(temporary, self.path)
  if not renamed then
    pcall(vim.fn.delete, temporary)
    return nil, rename_err
  end
  return true
end

function Store:_acquire_lock()
  local started = uv.hrtime()
  while true do
    local fd, err = uv.fs_open(self.lock_path, "wx", 384)
    if fd then
      return fd
    end

    local stat = uv.fs_stat(self.lock_path)
    local modified = stat and stat.mtime and (stat.mtime.sec or stat.mtime) or nil
    if modified and os.time() - tonumber(modified) >= self.stale_lock_seconds then
      pcall(uv.fs_unlink, self.lock_path)
    elseif (uv.hrtime() - started) / 1000000 >= self.lock_timeout_ms then
      return nil, "thread store lock timeout: " .. tostring(err or "manifest is locked")
    else
      vim.wait(10)
    end
  end
end

function Store:_with_lock(callback)
  local ok_dir, dir_err = self:_ensure_dir()
  if not ok_dir then
    return nil, dir_err
  end
  local fd, lock_err = self:_acquire_lock()
  if not fd then
    return nil, lock_err
  end
  local ok, first, second, third = pcall(callback)
  pcall(uv.fs_close, fd)
  pcall(uv.fs_unlink, self.lock_path)
  if not ok then
    return nil, first
  end
  return first, second, third
end

function Store:load()
  local manifest, warning = self:_read()
  if not manifest then
    return nil, warning
  end
  return copy(manifest), warning
end

function Store:list(opts)
  opts = opts or {}
  local manifest, warning = self:_read()
  if not manifest then
    return nil, warning
  end
  local result = {}
  for _, record in ipairs(manifest.threads) do
    if opts.include_archived == true or record.status ~= "archived" then
      result[#result + 1] = copy(record)
    end
  end
  table.sort(result, function(left, right)
    if left.updated_at == right.updated_at then
      return left.thread_id < right.thread_id
    end
    return left.updated_at > right.updated_at
  end)
  return result, warning
end

function Store:get(thread_id)
  local manifest, warning = self:_read()
  if not manifest then
    return nil, warning
  end
  local _, record = thread_index(manifest, tostring(thread_id or ""):lower())
  return record and copy(record) or nil, warning
end

function Store:create(attributes)
  attributes = copy(attributes or {})
  return self:_with_lock(function()
    local manifest, warning = self:_read()
    if not manifest then
      return nil, warning
    end
    local uuid_err
    if not attributes.thread_id then
      attributes.thread_id, uuid_err = self.uuid()
    end
    if not attributes.thread_id then
      return nil, uuid_err
    end
    local timestamp = self:_timestamp()
    attributes.created_at = attributes.created_at or timestamp
    attributes.updated_at = attributes.updated_at or attributes.created_at
    local record, err = normalize_record(attributes, { now = timestamp })
    if not record then
      return nil, err
    end
    if thread_index(manifest, record.thread_id) then
      return nil, "thread already exists: " .. record.thread_id
    end
    manifest.threads[#manifest.threads + 1] = record
    local ok, write_err = self:_write(manifest)
    if not ok then
      return nil, write_err
    end
    return copy(record), warning
  end)
end

function Store:update(thread_id, changes, opts)
  thread_id = tostring(thread_id or ""):lower()
  changes = copy(changes or {})
  opts = opts or {}
  return self:_with_lock(function()
    local manifest, warning = self:_read()
    if not manifest then
      return nil, warning
    end
    local index, current = thread_index(manifest, thread_id)
    if not index then
      return nil, "thread not found: " .. thread_id
    end
    if opts.expected_process_id ~= nil and current.process_id ~= opts.expected_process_id then
      return nil, {
        code = "stale_process",
        expected_process_id = opts.expected_process_id,
        current_process_id = current.process_id,
      }
    end
    changes.thread_id = current.thread_id
    changes.provider_id = current.provider_id
    changes.created_at = current.created_at
    changes.updated_at = self:_timestamp()
    local merged = vim.tbl_deep_extend("force", copy(current), changes)
    for _, field in ipairs({ "native_session_id", "process_id", "model", "mode", "archived_at" }) do
      if changes[field] == vim.NIL then
        merged[field] = nil
      end
    end
    local record, err = normalize_record(merged)
    if not record then
      return nil, err
    end
    manifest.threads[index] = record
    local ok, write_err = self:_write(manifest)
    if not ok then
      return nil, write_err
    end
    return copy(record), warning
  end)
end

function Store:archive(thread_id)
  return self:update(thread_id, { status = "archived", archived_at = self:_timestamp() })
end

function Store:restore(thread_id)
  return self:update(thread_id, { status = "closed", archived_at = vim.NIL })
end

function Store:open(thread_id, changes)
  changes = vim.tbl_deep_extend("force", copy(changes or {}), {
    status = "active",
    archived_at = vim.NIL,
  })
  return self:update(thread_id, changes)
end

function Store:rename(thread_id, title)
  title = tostring(title or "")
  if title == "" then
    return nil, "thread title is required"
  end
  return self:update(thread_id, { title = title })
end

function Store:delete(thread_id)
  thread_id = tostring(thread_id or ""):lower()
  return self:_with_lock(function()
    local manifest, warning = self:_read()
    if not manifest then
      return nil, warning
    end
    local index, record = thread_index(manifest, thread_id)
    if not index then
      return false, "thread not found: " .. thread_id
    end
    table.remove(manifest.threads, index)
    local ok, write_err = self:_write(manifest)
    if not ok then
      return nil, write_err
    end
    return true, copy(record), warning
  end)
end

function M.new(opts)
  opts = opts or {}
  local dir = tostring(opts.dir or (vim.fn.stdpath("cache") .. "/lazyagent/acp/threads"))
  return setmetatable({
    dir = dir,
    path = dir .. "/manifest.json",
    lock_path = dir .. "/manifest.lock",
    clock = opts.clock or now_utc,
    uuid = opts.uuid or uuid_v4,
    lock_timeout_ms = math.max(1, tonumber(opts.lock_timeout_ms) or 1000),
    stale_lock_seconds = math.max(1, tonumber(opts.stale_lock_seconds) or 30),
  }, Store)
end

M.SCHEMA_VERSION = SCHEMA_VERSION
M.valid_uuid = valid_uuid

return M

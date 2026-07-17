local M = {}

local uv = vim.uv or vim.loop
local DEFAULT_MAX_BLOB_BYTES = 4 * 1024 * 1024
local Store = {}
Store.__index = Store

local function effective_max_bytes(store, opts)
  if type(opts) == "table" and opts.max_bytes == false then
    return nil
  end
  if type(opts) == "table" and opts.max_bytes ~= nil then
    return math.max(0, tonumber(opts.max_bytes) or 0)
  end
  return store.max_blob_bytes
end

local function blob_hash(ref)
  local hash = type(ref) == "table" and ref.hash or tostring(ref or "")
  if not hash:match("^[0-9a-f]+$") or #hash ~= 64 then
    return nil, "invalid sha256 blob reference"
  end
  return hash
end

local function write_all(fd, data)
  local offset = 0
  while offset < #data do
    local written, err = uv.fs_write(fd, data:sub(offset + 1), offset)
    if not written or written <= 0 then
      return nil, err or "short blob write"
    end
    offset = offset + written
  end
  return true
end

local function read_file(path, max_bytes)
  local fd, open_err = uv.fs_open(path, "r", 384)
  if not fd then
    return nil, open_err or ("failed to open " .. path)
  end
  local stat, stat_err = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    return nil, stat_err or ("failed to stat " .. path)
  end
  if max_bytes and stat.size > max_bytes then
    uv.fs_close(fd)
    return nil, string.format("blob exceeds %d bytes: %s", max_bytes, path)
  end
  local data, read_err = uv.fs_read(fd, stat.size or 0, 0)
  uv.fs_close(fd)
  if data == nil then
    return nil, read_err or ("failed to read " .. path)
  end
  return data
end

function Store:_path(hash)
  return self.dir .. "/sha256/" .. hash:sub(1, 2) .. "/" .. hash:sub(3)
end

function Store:put(data, opts)
  data = type(data) == "string" and data or tostring(data or "")
  local max_bytes = effective_max_bytes(self, opts)
  if max_bytes and #data > max_bytes then
    return nil, string.format("blob exceeds %d bytes", max_bytes)
  end
  local hash = vim.fn.sha256(data)
  local path = self:_path(hash)
  if uv.fs_stat(path) then
    return { algorithm = "sha256", hash = hash, size = #data }
  end
  local parent = vim.fs.dirname(path)
  local ok_mkdir, mkdir_result = pcall(vim.fn.mkdir, parent, "p", 448)
  if not ok_mkdir or mkdir_result == 0 then
    return nil, ok_mkdir and ("failed to create blob directory: " .. parent) or mkdir_result
  end
  local temporary = path .. ".tmp." .. tostring(vim.fn.getpid()) .. "." .. tostring(uv.hrtime())
  local fd, open_err = uv.fs_open(temporary, "wx", 384)
  if not fd then
    return nil, open_err or "failed to create blob"
  end
  local written, write_err = write_all(fd, data)
  if written and uv.fs_fsync then
    written, write_err = uv.fs_fsync(fd)
  end
  uv.fs_close(fd)
  if not written then
    pcall(uv.fs_unlink, temporary)
    return nil, write_err
  end
  local renamed, rename_err = uv.fs_rename(temporary, path)
  if not renamed then
    pcall(uv.fs_unlink, temporary)
    if not uv.fs_stat(path) then
      return nil, rename_err
    end
  end
  return { algorithm = "sha256", hash = hash, size = #data }
end

function Store:put_file(path)
  local data, err = read_file(path, self.max_blob_bytes)
  if data == nil then
    return nil, err
  end
  local ref, put_err = self:put(data)
  if not ref then
    return nil, put_err
  end
  ref.binary = data:find("\0", 1, true) ~= nil
  return ref
end

function Store:size(ref)
  local hash, hash_err = blob_hash(ref)
  if not hash then
    return nil, hash_err
  end
  local stat, stat_err = uv.fs_stat(self:_path(hash))
  if not stat then
    return nil, stat_err or "blob not found"
  end
  return tonumber(stat.size) or 0
end

function Store:get(ref, opts)
  local hash, hash_err = blob_hash(ref)
  if not hash then
    return nil, hash_err
  end
  local max_bytes = type(opts) == "table" and opts.max_bytes or nil
  if max_bytes ~= nil and max_bytes ~= false then
    max_bytes = math.max(0, tonumber(max_bytes) or 0)
  else
    max_bytes = nil
  end
  return read_file(self:_path(hash), max_bytes)
end

function M.new(opts)
  opts = opts or {}
  local max_blob_bytes = nil
  if opts.max_blob_bytes ~= false then
    max_blob_bytes = math.max(0, tonumber(opts.max_blob_bytes) or DEFAULT_MAX_BLOB_BYTES)
  end
  return setmetatable({
    dir = tostring(opts.dir or (vim.fn.stdpath("cache") .. "/lazyagent/acp/blobs")),
    max_blob_bytes = max_blob_bytes,
  }, Store)
end

M.DEFAULT_MAX_BLOB_BYTES = DEFAULT_MAX_BLOB_BYTES

return M

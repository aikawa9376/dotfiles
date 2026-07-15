local M = {}

local uv = vim.uv or vim.loop
local MIME_TYPES = {
  png = "image/png",
  jpg = "image/jpeg",
  jpeg = "image/jpeg",
  gif = "image/gif",
  webp = "image/webp",
  bmp = "image/bmp",
  wav = "audio/wav",
  mp3 = "audio/mpeg",
  ogg = "audio/ogg",
  flac = "audio/flac",
  m4a = "audio/mp4",
  pdf = "application/pdf",
  zip = "application/zip",
  gz = "application/gzip",
  wasm = "application/wasm",
  sqlite = "application/vnd.sqlite3",
  db = "application/vnd.sqlite3",
  docx = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  xlsx = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  json = "application/json",
  md = "text/markdown",
  txt = "text/plain",
  lua = "text/x-lua",
}
local BINARY_RESOURCE_EXTENSIONS = {
  pdf = true, zip = true, gz = true, wasm = true, sqlite = true, db = true, docx = true, xlsx = true,
}
local MIME_EXTENSIONS = {
  ["image/png"] = "png",
  ["image/jpeg"] = "jpg",
  ["image/gif"] = "gif",
  ["image/webp"] = "webp",
  ["image/bmp"] = "bmp",
  ["audio/wav"] = "wav",
  ["audio/mpeg"] = "mp3",
  ["audio/ogg"] = "ogg",
  ["audio/flac"] = "flac",
  ["audio/mp4"] = "m4a",
  ["application/pdf"] = "pdf",
  ["application/json"] = "json",
  ["text/plain"] = "txt",
}

local function byte_size(base64)
  local value = tostring(base64 or ""):gsub("%s", "")
  local padding = value:match("=+$")
  return math.max(0, math.floor(#value * 3 / 4) - (padding and #padding or 0))
end

local function decode_base64(base64)
  local value = tostring(base64 or ""):gsub("%s", "")
  local padding = value:match("=+$") or ""
  local unpadded = padding ~= "" and value:sub(1, #value - #padding) or value
  if value:find("[^A-Za-z0-9+/=]") or unpadded:find("=", 1, true) or #padding > 2 then
    return nil, "invalid base64 output payload"
  end
  local remainder = #value % 4
  if remainder == 1 then return nil, "invalid base64 output payload" end
  if remainder > 1 and not value:find("=", 1, true) then
    value = value .. string.rep("=", 4 - remainder)
  end
  local ok, data = pcall(vim.base64.decode, value)
  if not ok then return nil, "invalid base64 output payload" end
  return data
end

local function cache_extension(mime_type)
  if MIME_EXTENSIONS[mime_type] then
    return MIME_EXTENSIONS[mime_type]
  end
  local subtype = tostring(mime_type or "application/octet-stream"):match("/([%w.+-]+)$") or "bin"
  subtype = subtype:gsub("^x%-", ""):gsub("[^%w]+", "-")
  return subtype ~= "" and subtype or "bin"
end

local function materialize_base64(base64, mime_type, opts)
  opts = opts or {}
  local max_bytes = tonumber(opts.max_output_bytes) or (20 * 1024 * 1024)
  if byte_size(base64) > max_bytes then
    return nil, string.format("output media exceeds %d byte limit", max_bytes)
  end
  local data, decode_err = decode_base64(base64)
  if not data then return nil, decode_err end
  local dir = opts.cache_dir or (vim.fn.stdpath("cache") .. "/lazyagent/acp/media")
  local mkdir_ok = vim.fn.mkdir(dir, "p")
  if mkdir_ok == 0 and vim.fn.isdirectory(dir) ~= 1 then
    return nil, "failed to create output media cache"
  end
  local path = string.format("%s/%s.%s", dir, vim.fn.sha256(base64), cache_extension(mime_type))
  if vim.fn.filereadable(path) == 1 then
    return path
  end
  local fd, open_err = uv.fs_open(path, "w", 384)
  if not fd then
    return nil, open_err
  end
  local written, write_err = uv.fs_write(fd, data, 0)
  uv.fs_close(fd)
  if not written or written ~= #data then
    pcall(uv.fs_unlink, path)
    return nil, write_err or "incomplete output media write"
  end
  return path
end

function M.materialize(content, opts)
  if type(content) ~= "table" then
    return nil
  end
  if (content.type == "image" or content.type == "audio") and content.data then
    return materialize_base64(content.data, content.mimeType, opts)
  end
  if content.type == "resource" and type(content.resource) == "table" and content.resource.blob then
    return materialize_base64(content.resource.blob, content.resource.mimeType, opts)
  end
  return nil
end

function M.media_kind(path)
  local extension = tostring(path or ""):lower():match("%.([%w]+)$")
  local mime_type = extension and MIME_TYPES[extension] or nil
  local kind = mime_type and mime_type:match("^(%w+)/") or nil
  if kind ~= "image" and kind ~= "audio" then
    return nil
  end
  return kind, mime_type
end

function M.mime_type(path)
  local extension = tostring(path or ""):lower():match("%.([%w]+)$")
  return extension and MIME_TYPES[extension] or nil
end

function M.is_binary_resource(path)
  local extension = tostring(path or ""):lower():match("%.([%w]+)$")
  if extension and BINARY_RESOURCE_EXTENSIONS[extension] then return true end
  local fd = uv.fs_open(path, "r", 384)
  if not fd then return false end
  local sample = uv.fs_read(fd, 4096, 0)
  uv.fs_close(fd)
  return type(sample) == "string" and sample:find("\0", 1, true) ~= nil
end

local function read_binary(path, max_bytes)
  local stat, stat_err = uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil, stat_err or ("media file not found: " .. path)
  end
  if stat.size > max_bytes then
    return nil, string.format("media file exceeds %d byte limit: %s", max_bytes, path)
  end
  local fd, open_err = uv.fs_open(path, "r", 384)
  if not fd then
    return nil, open_err
  end
  local data, read_err = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  return data, read_err
end

function M.from_file(path, capabilities, opts)
  capabilities = capabilities or {}
  opts = opts or {}
  local kind, mime_type = M.media_kind(path)
  if not kind then
    return nil
  end
  if capabilities[kind] ~= true then
    return {
      type = "text",
      text = string.format("[%s omitted: ACP agent does not support %s prompts] %s", kind, kind, path),
    }
  end

  local data, err = read_binary(path, tonumber(opts.max_bytes) or (10 * 1024 * 1024))
  if not data then
    return nil, err
  end
  return {
    type = kind,
    mimeType = mime_type,
    data = vim.base64.encode(data),
    uri = vim.uri_from_fname(path),
  }
end

function M.resource_from_file(path, capabilities, opts)
  capabilities = capabilities or {}
  opts = opts or {}
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil, "resource file not found: " .. tostring(path)
  end
  local mime_type = M.mime_type(path) or "application/octet-stream"
  local link = {
    type = "resource_link",
    uri = vim.uri_from_fname(path),
    name = opts.name or vim.fn.fnamemodify(path, ":t"),
    title = opts.title,
    description = opts.description,
    mimeType = mime_type,
    size = stat.size,
    annotations = opts.annotations and vim.deepcopy(opts.annotations) or nil,
  }
  if capabilities.embedded_context ~= true then return link end
  local data, err = read_binary(path, tonumber(opts.max_bytes) or (10 * 1024 * 1024))
  if not data then return nil, err end
  return {
    type = "resource",
    resource = {
      uri = link.uri,
      mimeType = mime_type,
      blob = vim.base64.encode(data),
    },
    annotations = opts.annotations and vim.deepcopy(opts.annotations) or nil,
  }
end

function M.render(content, opts)
  if type(content) ~= "table" then
    return tostring(content or "")
  end
  if content.type == "text" then
    return content.text or ""
  end
  if content.type == "resource_link" then
    local label = content.title or content.name or content.uri or "resource"
    local detail = label
    if content.uri and content.uri ~= label then detail = detail .. " <" .. content.uri .. ">" end
    if content.mimeType then detail = detail .. " (" .. content.mimeType .. ")" end
    if content.size then detail = detail .. " [" .. tostring(content.size) .. " bytes]" end
    if content.description and content.description ~= "" then detail = detail .. " — " .. content.description end
    return "[resource] " .. detail
  end
  if content.type == "resource" and type(content.resource) == "table" then
    local resource = content.resource
    if resource.text ~= nil then
      return resource.text
    end
    local path, materialize_err = M.materialize(content, opts)
    if path then
      return string.format(
        "[resource blob] %s (%s, %d bytes)",
        path,
        tostring(resource.mimeType or "application/octet-stream"),
        byte_size(resource.blob)
      )
    end
    return string.format(
      "[resource blob] %s (%s, %d bytes%s)",
      tostring(resource.uri or "resource"),
      tostring(resource.mimeType or "application/octet-stream"),
      byte_size(resource.blob),
      materialize_err and ", " .. materialize_err or ""
    )
  end
  if content.type == "image" or content.type == "audio" then
    local path, materialize_err = M.materialize(content, opts)
    local reference = path or content.uri or content.type
    if content.type == "image" and path then
      reference = "@" .. path
    end
    return string.format(
      "[%s] %s (%s, %d bytes%s)",
      content.type,
      tostring(reference),
      tostring(content.mimeType or "unknown"),
      byte_size(content.data),
      materialize_err and ", " .. materialize_err or ""
    )
  end
  return vim.inspect(content)
end

return M

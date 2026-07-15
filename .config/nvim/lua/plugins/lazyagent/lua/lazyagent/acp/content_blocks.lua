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
  local value = tostring(base64 or "")
  local padding = value:match("=+$")
  return math.max(0, math.floor(#value * 3 / 4) - (padding and #padding or 0))
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
  local ok, data = pcall(vim.base64.decode, tostring(base64 or ""))
  if not ok then
    return nil, "invalid base64 output payload"
  end
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
  if not mime_type then
    return nil
  end
  return mime_type:match("^(%w+)/"), mime_type
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

function M.render(content, opts)
  if type(content) ~= "table" then
    return tostring(content or "")
  end
  if content.type == "text" then
    return content.text or ""
  end
  if content.type == "resource_link" then
    local detail = content.uri or content.name or "resource"
    if content.mimeType then detail = detail .. " (" .. content.mimeType .. ")" end
    if content.size then detail = detail .. " [" .. tostring(content.size) .. " bytes]" end
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

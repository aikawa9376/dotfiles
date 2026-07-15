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

local function byte_size(base64)
  local value = tostring(base64 or "")
  local padding = value:match("=+$")
  return math.max(0, math.floor(#value * 3 / 4) - (padding and #padding or 0))
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

function M.render(content)
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
    return string.format(
      "[resource blob] %s (%s, %d bytes)",
      tostring(resource.uri or "resource"),
      tostring(resource.mimeType or "application/octet-stream"),
      byte_size(resource.blob)
    )
  end
  if content.type == "image" or content.type == "audio" then
    return string.format(
      "[%s] %s (%s, %d bytes)",
      content.type,
      tostring(content.uri or content.type),
      tostring(content.mimeType or "unknown"),
      byte_size(content.data)
    )
  end
  return vim.inspect(content)
end

return M

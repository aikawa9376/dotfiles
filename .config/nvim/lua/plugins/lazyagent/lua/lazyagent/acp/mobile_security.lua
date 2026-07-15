local M = {}

local uv = vim.uv or vim.loop

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function constant_equal(left, right)
  left = tostring(left or "")
  right = tostring(right or "")
  local different = bit.bxor(#left, #right)
  local count = math.max(#left, #right)
  for idx = 1, count do
    different = bit.bor(different, bit.bxor(left:byte(idx) or 0, right:byte(idx) or 0))
  end
  return different == 0
end

function M.random_token()
  local bytes, err = uv.random(32)
  if not bytes then
    return nil, err or "secure random generation failed"
  end
  return (bytes:gsub(".", function(char)
    return string.format("%02x", char:byte())
  end))
end

function M.authorized(req, token, query_token)
  local authorization = trim(((req or {}).headers or {}).authorization)
  local bearer = authorization:match("^[Bb]earer%s+(.+)$")
  if bearer and constant_equal(trim(bearer), token) then
    return true
  end
  return query_token ~= nil and constant_equal(query_token, token)
end

function M.origin_allowed(req, allowed_origins)
  local headers = (req or {}).headers or {}
  local origin = trim(headers.origin):lower():gsub("/$", "")
  if origin == "" then
    return true
  end
  local host = trim(headers.host):lower()
  if host ~= "" and origin == ("http://" .. host) then
    return true
  end
  for _, allowed in ipairs(type(allowed_origins) == "table" and allowed_origins or {}) do
    if origin == trim(allowed):lower():gsub("/$", "") then
      return true
    end
  end
  return false
end

function M.body_allowed(content_length, max_body_bytes)
  local length = tonumber(content_length)
  local limit = tonumber(max_body_bytes) or (256 * 1024)
  return length ~= nil and length >= 0 and length <= limit
end

function M.is_loopback(host)
  host = trim(host):lower()
  return host == "" or host == "localhost" or host == "127.0.0.1" or host == "::1"
end

return M

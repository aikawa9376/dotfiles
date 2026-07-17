local M = {}

local uv = vim.uv or vim.loop
local DEFAULT_CHUNK_BYTES = 64 * 1024

local function valid_ref(ref)
  return type(ref) == "table"
    and type(ref.path) == "string"
    and ref.path ~= ""
    and vim.fn.filereadable(ref.path) == 1
end

function M.each_chunk(ref, callback, opts)
  opts = opts or {}
  if not valid_ref(ref) then
    return nil, "text reference is not readable"
  end
  local fd, open_err = uv.fs_open(ref.path, "r", 384)
  if not fd then
    return nil, open_err
  end
  local chunk_bytes = math.max(1024, tonumber(opts.chunk_bytes) or DEFAULT_CHUNK_BYTES)
  local start_line = math.max(1, tonumber(ref.start_line) or 1)
  local end_line = tonumber(ref.end_line)
  if end_line then
    end_line = math.max(start_line, end_line)
  end
  local offset = 0
  local line = 1
  local stopped = false
  local ok, err = pcall(function()
    while not stopped and (not end_line or line <= end_line) do
      local chunk, read_err = uv.fs_read(fd, chunk_bytes, offset)
      if chunk == nil then
        error(read_err or "failed to read text reference")
      end
      if chunk == "" then
        break
      end
      offset = offset + #chunk
      local cursor = 1
      while cursor <= #chunk do
        local newline = chunk:find("\n", cursor, true)
        local stop = newline or #chunk
        if line >= start_line and (not end_line or line <= end_line) then
          local keep_going, callback_err = callback(chunk:sub(cursor, stop))
          if keep_going == false then
            if callback_err then
              error(callback_err)
            end
            stopped = true
            break
          end
        end
        if not newline then
          break
        end
        line = line + 1
        cursor = newline + 1
        if end_line and line > end_line then
          stopped = true
          break
        end
      end
    end
  end)
  uv.fs_close(fd)
  if not ok then
    return nil, err
  end
  return true
end

function M.search(ref, query, opts)
  query = tostring(query or "")
  if query == "" then
    return nil
  end
  local needle = query:lower()
  local tail = ""
  local match_preview = nil
  local tail_bytes = math.max(256, #needle + 64)
  local ok, err = M.each_chunk(ref, function(chunk)
    local window = tail .. chunk
    local start = window:lower():find(needle, 1, true)
    if start then
      local left = math.max(1, start - 55)
      match_preview = window:sub(left, math.min(#window, start + #needle + 95)):gsub("%s+", " ")
      if left > 1 or tail ~= "" then
        match_preview = "..." .. match_preview
      end
      match_preview = match_preview .. "..."
      return false
    end
    tail = window:sub(math.max(1, #window - tail_bytes + 1))
    return true
  end, opts)
  if not ok then
    return nil, err
  end
  return match_preview
end

return M

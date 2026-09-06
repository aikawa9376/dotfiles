local M = {}

local uv = vim.uv or vim.loop
local DEFAULT_CHUNK_BYTES = 64 * 1024
-- A bounded, single-file index serves adjacent search/export references. No
-- descriptors are retained; switching files or changing the file drops it.
local cached_file
local INDEX_STRIDE = 64
local MAX_CHECKPOINTS = 4096

local function file_cache(path, stat, chunk_bytes)
  local signature = table.concat({ path, stat.dev or 0, stat.ino or 0, stat.size,
    stat.mtime.sec, stat.mtime.nsec, stat.ctime.sec, stat.ctime.nsec, chunk_bytes }, ":")
  if not cached_file or cached_file.signature ~= signature then
    cached_file = { signature = signature, checkpoints = { [1] = 0 }, blocks = {} }
  end
  return cached_file
end

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
  local stat = uv.fs_fstat(fd)
  -- Do not retain arbitrarily large caller-selected read blocks.
  local cache = stat and chunk_bytes <= DEFAULT_CHUNK_BYTES and file_cache(ref.path, stat, chunk_bytes) or nil
  local start_line = math.max(1, tonumber(ref.start_line) or 1)
  local end_line = tonumber(ref.end_line)
  if end_line then
    end_line = math.max(start_line, end_line)
  end
  local offset = 0
  local line = 1
  if cache then
    local checkpoint = math.min(MAX_CHECKPOINTS - 1, math.floor((start_line - 1) / INDEX_STRIDE))
    for idx = checkpoint, 0, -1 do
      local candidate = idx * INDEX_STRIDE + 1
      if cache.checkpoints[candidate] then
        line, offset = candidate, cache.checkpoints[candidate]
        break
      end
    end
  end
  local stopped = false
  local ok, err = pcall(function()
    while not stopped and (not end_line or line <= end_line) do
      local chunk, read_err
      local chunk_cursor = 1
      if cache then
        local block_offset = math.floor(offset / chunk_bytes) * chunk_bytes
        for _, block in ipairs(cache.blocks) do
          if block.offset == block_offset then
            chunk = block.text
            break
          end
        end
        if not chunk then
          chunk, read_err = uv.fs_read(fd, chunk_bytes, block_offset)
          if chunk then
            table.insert(cache.blocks, 1, { offset = block_offset, text = chunk })
            cache.blocks[3] = nil
          end
        end
        chunk_cursor = offset - block_offset + 1
      else
        chunk, read_err = uv.fs_read(fd, chunk_bytes, offset)
      end
      if chunk == nil then
        error(read_err or "failed to read text reference")
      end
      if chunk == "" or chunk_cursor > #chunk then
        break
      end
      offset = offset - chunk_cursor + 1 + #chunk
      local cursor = chunk_cursor
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
        if cache and (line - 1) % INDEX_STRIDE == 0 and line <= INDEX_STRIDE * (MAX_CHECKPOINTS - 1) + 1 then
          cache.checkpoints[line] = offset - #chunk + newline
        end
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

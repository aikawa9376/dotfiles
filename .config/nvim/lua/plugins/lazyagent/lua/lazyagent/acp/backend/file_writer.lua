local M = {}

local uv = vim.uv or vim.loop

local function loaded_buffer(path)
  local normalized = vim.fn.fnamemodify(path, ":p")
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" and vim.fn.fnamemodify(name, ":p") == normalized then
        return bufnr
      end
    end
  end
  return nil
end

local function read_bytes(path)
  local fd, open_err = uv.fs_open(path, "r", 384)
  if not fd then
    if uv.fs_stat(path) == nil then
      return nil
    end
    return nil, open_err or ("failed to open " .. path)
  end
  local stat, stat_err = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    return nil, stat_err or ("failed to stat " .. path)
  end
  local data, read_err = uv.fs_read(fd, stat.size or 0, 0)
  uv.fs_close(fd)
  if data == nil then
    return nil, read_err or ("failed to read " .. path)
  end
  return data, nil, stat
end

local function continuation(byte)
  return byte and byte >= 128 and byte <= 191
end

local function valid_utf8(value)
  local idx = 1
  while idx <= #value do
    local first = value:byte(idx)
    if first <= 127 then
      idx = idx + 1
    elseif first >= 194 and first <= 223 and continuation(value:byte(idx + 1)) then
      idx = idx + 2
    elseif first == 224
      and value:byte(idx + 1) and value:byte(idx + 1) >= 160 and value:byte(idx + 1) <= 191
      and continuation(value:byte(idx + 2)) then
      idx = idx + 3
    elseif ((first >= 225 and first <= 236) or (first >= 238 and first <= 239))
      and continuation(value:byte(idx + 1)) and continuation(value:byte(idx + 2)) then
      idx = idx + 3
    elseif first == 237
      and value:byte(idx + 1) and value:byte(idx + 1) >= 128 and value:byte(idx + 1) <= 159
      and continuation(value:byte(idx + 2)) then
      idx = idx + 3
    elseif first == 240
      and value:byte(idx + 1) and value:byte(idx + 1) >= 144 and value:byte(idx + 1) <= 191
      and continuation(value:byte(idx + 2)) and continuation(value:byte(idx + 3)) then
      idx = idx + 4
    elseif first >= 241 and first <= 243
      and continuation(value:byte(idx + 1)) and continuation(value:byte(idx + 2))
      and continuation(value:byte(idx + 3)) then
      idx = idx + 4
    elseif first == 244
      and value:byte(idx + 1) and value:byte(idx + 1) >= 128 and value:byte(idx + 1) <= 143
      and continuation(value:byte(idx + 2)) and continuation(value:byte(idx + 3)) then
      idx = idx + 4
    else
      return false
    end
  end
  return true
end

local function utf8_text(value, label)
  if value:find("%z") then
    return nil, label .. " contains NUL bytes"
  end
  if not valid_utf8(value) then
    return nil, label .. " is not valid UTF-8"
  end
  return value
end

local function newline_style(existing)
  if not existing or existing == "" then
    return "lf"
  end
  local without_crlf = existing:gsub("\r\n", "")
  if without_crlf:find("\r", 1, true) then
    return nil, "existing file uses unsupported CR-only or mixed line endings"
  end
  if existing:find("\r\n", 1, true) then
    if without_crlf:find("\n", 1, true) then
      return nil, "existing file uses mixed LF and CRLF line endings"
    end
    return "crlf"
  end
  return "lf"
end

local function temp_path(path)
  local dir = vim.fs.dirname(path)
  local name = vim.fs.basename(path)
  return vim.fs.joinpath(dir, string.format(".%s.lazyagent-%s-%s.tmp", name, vim.fn.getpid(), uv.hrtime()))
end

local function write_all(fd, data)
  local offset = 0
  while offset < #data do
    local written, err = uv.fs_write(fd, data:sub(offset + 1), offset)
    if not written or written <= 0 then
      return nil, err or "short write"
    end
    offset = offset + written
  end
  return true
end

local function remove_temp(path)
  if path then
    pcall(uv.fs_unlink, path)
  end
end

function M.write(path, content, opts)
  opts = opts or {}
  local bufnr = loaded_buffer(path)
  if bufnr and vim.bo[bufnr].modified then
    return nil, "refusing to overwrite an unsaved buffer: " .. path
  end
  if bufnr then
    local encoding = tostring(vim.bo[bufnr].fileencoding or ""):lower()
    if encoding ~= "" and encoding ~= "utf-8" and encoding ~= "utf8" then
      return nil, "refusing to overwrite a non-UTF-8 buffer (" .. encoding .. "): " .. path
    end
  end

  local existing, read_err, stat = read_bytes(path)
  if read_err then
    return nil, read_err
  end
  if existing then
    local _, encoding_err = utf8_text(existing, "existing file")
    if encoding_err then
      return nil, encoding_err .. ": " .. path
    end
  end

  content = tostring(content or ""):gsub("\r\n", "\n")
  if content:find("\r", 1, true) then
    return nil, "new content contains unsupported CR-only line endings"
  end
  local _, content_err = utf8_text(content, "new content")
  if content_err then
    return nil, content_err
  end

  local style, newline_err = newline_style(existing)
  if not style then
    return nil, newline_err .. ": " .. path
  end
  local output = style == "crlf" and content:gsub("\n", "\r\n") or content
  local tmp = temp_path(path)
  local mode = stat and bit.band(stat.mode or 420, 511) or 420
  local fd, open_err = uv.fs_open(tmp, "wx", mode)
  if not fd then
    return nil, open_err or ("failed to create temporary file for " .. path)
  end

  local ok, write_err = write_all(fd, output)
  if ok and uv.fs_fsync then
    ok, write_err = uv.fs_fsync(fd)
  end
  uv.fs_close(fd)
  if not ok then
    remove_temp(tmp)
    return nil, write_err or ("failed to write temporary file for " .. path)
  end

  if type(opts.before_commit) == "function" then
    opts.before_commit(path, tmp)
  end
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].modified then
    remove_temp(tmp)
    return nil, "buffer changed while ACP write was in progress: " .. path
  end
  local current, current_err = read_bytes(path)
  if current_err then
    remove_temp(tmp)
    return nil, current_err
  end
  if current ~= existing then
    remove_temp(tmp)
    return nil, "file changed while ACP write was in progress: " .. path
  end

  local renamed, rename_err = uv.fs_rename(tmp, path)
  if not renamed then
    remove_temp(tmp)
    return nil, rename_err or ("failed to replace " .. path)
  end
  if stat and uv.fs_chmod then
    pcall(uv.fs_chmod, path, mode)
  end

  return {
    before_text = existing and existing:gsub("\r\n", "\n") or "",
    newline = style,
  }
end

return M

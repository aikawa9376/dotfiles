local M = {}

local uv = vim.uv or vim.loop

local function read_bytes(path)
  local fd, open_err = uv.fs_open(path, "r", 384)
  if not fd then
    if not uv.fs_stat(path) then
      return nil
    end
    return nil, open_err
  end
  local stat, stat_err = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    return nil, stat_err
  end
  local data, read_err = uv.fs_read(fd, stat.size or 0, 0)
  uv.fs_close(fd)
  return data, read_err
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

local function write_atomic(path, data)
  local parent = vim.fs.dirname(path)
  local ok_mkdir, mkdir_result = pcall(vim.fn.mkdir, parent, "p", 448)
  if not ok_mkdir or mkdir_result == 0 then
    return nil, ok_mkdir and ("failed to create directory: " .. parent) or mkdir_result
  end
  local temporary = path .. ".lazyagent-reject." .. tostring(vim.fn.getpid()) .. "." .. tostring(uv.hrtime())
  local fd, open_err = uv.fs_open(temporary, "wx", 420)
  if not fd then
    return nil, open_err
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
    return nil, rename_err
  end
  return true
end

local function absolute_path(root, relative)
  root = vim.fn.fnamemodify(root, ":p"):gsub("/$", "")
  local path = vim.fn.fnamemodify(root .. "/" .. tostring(relative or ""), ":p"):gsub("/$", "")
  if path ~= root and path:sub(1, #root + 1) ~= root .. "/" then
    return nil, "change path escapes workspace: " .. tostring(relative)
  end
  return path
end

function M.new(opts)
  opts = opts or {}
  local apply = {}

  local function blob(ref)
    if not ref then
      return nil
    end
    return opts.read_blob(ref)
  end

  local function preflight(change, root)
    local path, path_err = absolute_path(root, change.path)
    if not path then
      return nil, path_err
    end
    local current, current_err = read_bytes(path)
    if current_err then
      return nil, current_err
    end
    if change.operation == "deleted" then
      if current ~= nil then
        return nil, "file was recreated after the agent turn: " .. path
      end
    else
      local expected, expected_err = blob(change.after_blob)
      if expected == nil then
        return nil, expected_err or ("missing after blob: " .. path)
      end
      if current ~= expected then
        return nil, "file changed after the agent turn: " .. path
      end
    end
    if change.operation == "moved" then
      local previous, previous_err = absolute_path(root, change.previous_path)
      if not previous then
        return nil, previous_err
      end
      if uv.fs_stat(previous) then
        return nil, "move source was recreated after the agent turn: " .. previous
      end
    end
    return { path = path }
  end

  local function reject_preflighted(change, root, prepared)
    local current, current_err = preflight(change, root)
    if not current then
      return nil, current_err
    end
    prepared = current
    local before, before_err = blob(change.before_blob)
    if change.operation ~= "added" and before == nil then
      return nil, before_err or ("missing before blob: " .. prepared.path)
    end
    if change.operation == "added" then
      return uv.fs_unlink(prepared.path)
    elseif change.operation == "modified" or change.operation == "deleted" then
      return write_atomic(prepared.path, before)
    elseif change.operation == "moved" then
      local previous, previous_err = absolute_path(root, change.previous_path)
      if not previous then
        return nil, previous_err
      end
      local written, write_err = write_atomic(previous, before)
      if not written then
        return nil, write_err
      end
      local removed, remove_err = uv.fs_unlink(prepared.path)
      if not removed then
        return nil, remove_err
      end
      return true
    end
    return nil, "unsupported change operation: " .. tostring(change.operation)
  end

  function apply.reject(change, root)
    local prepared, err = preflight(change, root)
    if not prepared then
      return nil, err
    end
    return reject_preflighted(change, root, prepared)
  end

  function apply.reject_all(changes, root)
    local prepared = {}
    for index, change in ipairs(changes or {}) do
      local item, err = preflight(change, root)
      if not item then
        return nil, err
      end
      prepared[index] = item
    end
    for index, change in ipairs(changes or {}) do
      local ok, err = reject_preflighted(change, root, prepared[index])
      if not ok then
        return nil, err
      end
    end
    return true
  end

  return apply
end

return M

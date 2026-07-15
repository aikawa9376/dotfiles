local M = {}

local uv = vim.uv or vim.loop

local function now_utc()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function trim(value)
  return tostring(value or ""):gsub("%s+$", "")
end

local function split_zero(value)
  local result = {}
  for item in tostring(value or ""):gmatch("([^%z]+)") do
    result[#result + 1] = item
  end
  return result
end

local function default_run(argv)
  if vim.system then
    local result = vim.system(argv, { text = false }):wait()
    return {
      code = result.code,
      stdout = result.stdout or "",
      stderr = result.stderr or "",
    }
  end
  local output = vim.fn.system(argv)
  return {
    code = vim.v.shell_error,
    stdout = output or "",
    stderr = vim.v.shell_error == 0 and "" or output or "",
  }
end

local function relative_path(root, path)
  local prefix = root:gsub("/$", "") .. "/"
  return path:sub(1, #prefix) == prefix and path:sub(#prefix + 1) or path
end

local function file_record(root, path, opts)
  local absolute = root:gsub("/$", "") .. "/" .. path
  local stat = opts.stat(absolute)
  if not stat then
    return { path = path, exists = false }
  end
  local modified = stat.mtime
  local record = {
    path = path,
    exists = true,
    type = stat.type,
    size = tonumber(stat.size) or 0,
    mtime = type(modified) == "table" and {
      sec = tonumber(modified.sec) or 0,
      nsec = tonumber(modified.nsec) or 0,
    } or { sec = tonumber(modified) or 0, nsec = 0 },
  }
  if opts.blob_store and stat.type == "file" then
    local blob, blob_err = opts.blob_store:put_file(absolute)
    record.blob = blob
    record.binary = blob and blob.binary == true or false
    record.blob_error = blob_err
  end
  return record
end

local function git_snapshot(cwd, opts)
  local run = opts.run
  local root_result = run({ "git", "-C", cwd, "rev-parse", "--show-toplevel" })
  if root_result.code ~= 0 then
    return nil
  end
  local root = vim.fn.fnamemodify(trim(root_result.stdout), ":p"):gsub("/$", "")
  if root == "" then
    return nil
  end

  local listed = run({ "git", "-C", root, "ls-files", "--cached", "--others", "--exclude-standard", "-z" })
  if listed.code ~= 0 then
    return nil, trim(listed.stderr) ~= "" and trim(listed.stderr) or "git ls-files failed"
  end
  local paths = split_zero(listed.stdout)
  table.sort(paths)
  local files = {}
  for _, path in ipairs(paths) do
    files[#files + 1] = file_record(root, path, opts)
  end

  local status_result = run({ "git", "-C", root, "status", "--porcelain=v1", "-z", "--untracked-files=all" })
  if status_result.code ~= 0 then
    return nil, trim(status_result.stderr) ~= "" and trim(status_result.stderr) or "git status failed"
  end
  local records = split_zero(status_result.stdout)
  local dirty = {}
  local untracked = {}
  local index = 1
  while index <= #records do
    local record = records[index]
    local status = record:sub(1, 2)
    local path = record:sub(4)
    local item = {
      path = path,
      index_status = status:sub(1, 1),
      worktree_status = status:sub(2, 2),
    }
    if status:find("[RC]") then
      index = index + 1
      item.original_path = records[index]
    end
    dirty[#dirty + 1] = item
    if status == "??" then
      untracked[#untracked + 1] = path
    end
    index = index + 1
  end

  local head_result = run({ "git", "-C", root, "rev-parse", "HEAD" })
  return {
    root = root,
    vcs = {
      kind = "git",
      head = head_result.code == 0 and trim(head_result.stdout) or nil,
    },
    files = files,
    dirty = dirty,
    untracked = untracked,
    truncated = false,
  }
end

local function filesystem_snapshot(cwd, opts)
  local root = vim.fn.fnamemodify(cwd, ":p"):gsub("/$", "")
  local files = {}
  local pending = { root }
  local truncated = false
  while #pending > 0 do
    local directory = table.remove(pending)
    local handle = uv.fs_scandir(directory)
    if handle then
      while true do
        local name, kind = uv.fs_scandir_next(handle)
        if not name then
          break
        end
        local absolute = directory .. "/" .. name
        if kind == "directory" and name ~= ".git" then
          pending[#pending + 1] = absolute
        elseif kind ~= "directory" then
          files[#files + 1] = file_record(root, relative_path(root, absolute), opts)
          if #files >= opts.max_files then
            truncated = true
            pending = {}
            break
          end
        end
      end
    end
  end
  table.sort(files, function(left, right)
    return left.path < right.path
  end)
  return {
    root = root,
    vcs = { kind = "none" },
    files = files,
    dirty = {},
    untracked = {},
    truncated = truncated,
  }
end

function M.capture(cwd, opts)
  opts = opts or {}
  opts.run = opts.run or default_run
  opts.stat = opts.stat or uv.fs_stat
  opts.max_files = math.max(1, tonumber(opts.max_files) or 20000)
  cwd = vim.fn.fnamemodify(tostring(cwd or vim.fn.getcwd()), ":p"):gsub("/$", "")

  local snapshot, err = git_snapshot(cwd, opts)
  if not snapshot then
    snapshot = filesystem_snapshot(cwd, opts)
    snapshot.git_error = err
  end
  snapshot.captured_at = (opts.clock or now_utc)()
  snapshot.schema_version = 1
  return snapshot
end

local function file_index(snapshot)
  local result = {}
  for _, file in ipairs((snapshot and snapshot.files) or {}) do
    result[file.path] = file
  end
  return result
end

local function same_file_state(left, right)
  if left.blob and right.blob then
    return left.blob.hash == right.blob.hash
  end
  return left.exists == right.exists
    and left.type == right.type
    and left.size == right.size
    and vim.deep_equal(left.mtime, right.mtime)
end

local function rename_key(item)
  return table.concat({
    tostring(item.path or ""),
    tostring(item.original_path or ""),
    tostring(item.index_status or ""),
    tostring(item.worktree_status or ""),
  }, "\0")
end

local function change_record(path, operation, left, right)
  return {
    path = path,
    operation = operation,
    before_size = left and left.size or nil,
    after_size = right and right.size or nil,
    before_blob = left and left.blob or nil,
    after_blob = right and right.blob or nil,
    binary = (left and left.binary == true) or (right and right.binary == true) or false,
  }
end

function M.diff(before, after)
  local previous = file_index(before)
  local current = file_index(after)
  local baseline_renames = {}
  for _, item in ipairs((before and before.dirty) or {}) do
    if (item.index_status == "R" or item.worktree_status == "R") and item.original_path then
      baseline_renames[rename_key(item)] = true
    end
  end
  local consumed = {}
  local changes = {}
  for _, item in ipairs((after and after.dirty) or {}) do
    if (item.index_status == "R" or item.worktree_status == "R")
      and item.original_path
      and not baseline_renames[rename_key(item)]
    then
      local moved = change_record(item.path, "moved", previous[item.original_path], current[item.path])
      moved.previous_path = item.original_path
      changes[#changes + 1] = moved
      consumed[item.path] = true
      consumed[item.original_path] = true
    end
  end

  local paths = {}
  for path in pairs(previous) do
    paths[path] = true
  end
  for path in pairs(current) do
    paths[path] = true
  end

  for path in pairs(paths) do
    if not consumed[path] then
      local left = previous[path]
      local right = current[path]
      local left_exists = left and left.exists ~= false
      local right_exists = right and right.exists ~= false
      local operation = nil
      if not left_exists and right_exists then
        operation = "added"
      elseif left_exists and not right_exists then
        operation = "deleted"
      elseif left_exists and right_exists and not same_file_state(left, right) then
        operation = "modified"
      end
      if operation then
        changes[#changes + 1] = change_record(path, operation, left, right)
      end
    end
  end
  table.sort(changes, function(left, right)
    return left.path < right.path
  end)
  return changes
end

return M

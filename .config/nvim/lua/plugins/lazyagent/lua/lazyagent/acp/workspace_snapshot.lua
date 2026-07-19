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
    local should_store = true
    if opts.only_dirty_blobs then
      should_store = opts.dirty_set and opts.dirty_set[path] or false
    end
    if should_store then
      local blob, blob_err = opts.blob_store:put_file(absolute)
      record.blob = blob
      record.binary = blob and blob.binary == true or false
      record.blob_error = blob_err
    end
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

  local status_result = run({ "git", "-C", root, "status", "--porcelain=v1", "-z", "--untracked-files=all" })
  if status_result.code ~= 0 then
    return nil, trim(status_result.stderr) ~= "" and trim(status_result.stderr) or "git status failed"
  end
  local records = split_zero(status_result.stdout)
  local dirty = {}
  local untracked = {}
  local dirty_set = {}
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
    dirty_set[path] = true
    if item.original_path then
      dirty_set[item.original_path] = true
    end
    if status == "??" then
      untracked[#untracked + 1] = path
    end
    index = index + 1
  end

  local listed = run({ "git", "-C", root, "ls-files", "--cached", "--others", "--exclude-standard", "-z" })
  if listed.code ~= 0 then
    return nil, trim(listed.stderr) ~= "" and trim(listed.stderr) or "git ls-files failed"
  end
  local paths = split_zero(listed.stdout)
  table.sort(paths)

  local file_opts = opts
  if opts.only_dirty_blobs then
    file_opts = vim.tbl_extend("force", opts, { dirty_set = dirty_set })
  end

  local files = {}
  for _, path in ipairs(paths) do
    files[#files + 1] = file_record(root, path, file_opts)
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

local function blob_too_large(store, size)
  local max_bytes = store and store.max_blob_bytes or nil
  return max_bytes ~= nil and tonumber(size) and tonumber(size) > max_bytes
end

function M.git_blob(snapshot, path, opts)
  opts = opts or {}
  local store = opts.blob_store
  if not store or type(snapshot) ~= "table" or type(snapshot.vcs) ~= "table"
    or snapshot.vcs.kind ~= "git" or not snapshot.root or not path
  then
    return nil, "git blob source is unavailable"
  end
  local run_cmd = opts.run or default_run
  local ref_name = (snapshot.vcs.head and snapshot.vcs.head ~= "") and snapshot.vcs.head or "HEAD"
  local object_name = ref_name .. ":" .. path
  if store.max_blob_bytes ~= nil then
    local size_result = run_cmd({ "git", "-C", snapshot.root, "cat-file", "-s", object_name })
    local object_size = size_result.code == 0 and tonumber((trim(size_result.stdout))) or nil
    if blob_too_large(store, object_size) then
      return nil, string.format("blob exceeds %d bytes", store.max_blob_bytes)
    end
  end
  local show_result = run_cmd({ "git", "-C", snapshot.root, "show", object_name })
  if show_result.code ~= 0 then
    return nil, trim(show_result.stderr) ~= "" and trim(show_result.stderr) or ("git blob not found: " .. object_name)
  end
  local data = show_result.stdout or ""
  local ref, put_err = store:put(data)
  if not ref then return nil, put_err end
  ref.binary = data:find("\0", 1, true) ~= nil
  return ref
end

local function apply_realtime_blob(record, realtime, side)
  if not record or record.blob or type(realtime) ~= "table" then return end
  local ref = side == "before" and realtime.before_blob or realtime.after_blob
  if ref then
    record.blob = vim.deepcopy(ref)
    record.binary = ref.binary == true
  end
end

local function apply_git_blob(record, snapshot, path, opts)
  if not record or record.blob or not opts.blob_store then return end
  local ref, err = M.git_blob(snapshot, path, opts)
  if ref then
    record.blob = ref
    record.binary = ref.binary == true
  else
    record.blob_error = record.blob_error or err
  end
end

function M.diff(before, after, opts)
  opts = opts or {}
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
      local left = previous[item.original_path]
      local right = current[item.path]
      apply_realtime_blob(left, (opts.realtime_blobs or {})[item.original_path], "before")
      apply_realtime_blob(right, (opts.realtime_blobs or {})[item.path], "after")
      apply_git_blob(left, before, item.original_path, opts)
      apply_git_blob(right, after, item.path, opts)
      local moved = change_record(item.path, "moved", left, right)
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
      local realtime = (opts.realtime_blobs or {})[path]
      apply_realtime_blob(left, realtime, "before")
      apply_realtime_blob(right, realtime, "after")
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
        if operation == "modified" or operation == "deleted" then
          apply_git_blob(left, before, path, opts)
        end
        if operation == "modified" or operation == "added" then
          apply_git_blob(right, after, path, opts)
        end
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

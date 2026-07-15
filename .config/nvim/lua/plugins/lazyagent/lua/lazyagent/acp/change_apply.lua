local M = {}

local uv = vim.uv or vim.loop

function M.inverse_changes(changes)
  local result = {}
  for _, change in ipairs(changes or {}) do
    local inverse = vim.deepcopy(change)
    inverse.decision = nil
    inverse.decided_at = nil
    inverse.apply_mode = nil
    inverse.hunks = nil
    inverse.review_blob = nil
    if change.operation == "modified" then
      inverse.before_blob = change.after_blob
      inverse.after_blob = change.before_blob
      inverse.before_size = change.after_size
      inverse.after_size = change.before_size
    elseif change.operation == "added" then
      inverse.operation = "deleted"
      inverse.before_blob = change.after_blob
      inverse.after_blob = nil
      inverse.before_size = change.after_size
      inverse.after_size = nil
    elseif change.operation == "deleted" then
      inverse.operation = "added"
      inverse.before_blob = nil
      inverse.after_blob = change.before_blob
      inverse.before_size = nil
      inverse.after_size = change.before_size
    elseif change.operation == "moved" then
      inverse.path = change.previous_path
      inverse.previous_path = change.path
      inverse.before_blob = change.after_blob
      inverse.after_blob = change.before_blob
      inverse.before_size = change.after_size
      inverse.after_size = change.before_size
    end
    result[#result + 1] = inverse
  end
  return result
end

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
  local existing = uv.fs_stat(path)
  local mode = existing and bit.band(existing.mode or 420, 511) or 420
  local fd, open_err = uv.fs_open(temporary, "wx", mode)
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
  if uv.fs_chmod then
    pcall(uv.fs_chmod, path, mode)
  end
  return true
end

local function write_temporary(path, data)
  local fd, open_err = uv.fs_open(path, "wx", 384)
  if not fd then
    return nil, open_err
  end
  local written, write_err = write_all(fd, data)
  uv.fs_close(fd)
  if not written then
    pcall(uv.fs_unlink, path)
    return nil, write_err
  end
  return true
end

local function three_way_merge(current, base, desired)
  if not vim.system or vim.fn.executable("git") ~= 1 then
    return nil, "git merge-file is unavailable"
  end
  local prefix = vim.fn.tempname() .. "-lazyagent-merge"
  local current_path = prefix .. "-current"
  local base_path = prefix .. "-base"
  local desired_path = prefix .. "-desired"
  local paths = { current_path, base_path, desired_path }
  for index, item in ipairs({ current, base, desired }) do
    local ok, err = write_temporary(paths[index], item)
    if not ok then
      for _, path in ipairs(paths) do
        pcall(uv.fs_unlink, path)
      end
      return nil, err
    end
  end
  local result = vim.system({
    "git",
    "merge-file",
    "-p",
    "-L",
    "current user state",
    "-L",
    "agent after",
    "-L",
    "LazyAgent before",
    current_path,
    base_path,
    desired_path,
  }, { text = false }):wait()
  for _, path in ipairs(paths) do
    pcall(uv.fs_unlink, path)
  end
  if result.code == 0 then
    return result.stdout or ""
  end
  if result.code == 1 then
    return nil, "three-way conflict; file left unchanged"
  end
  return nil, tostring(result.stderr or "git merge-file failed")
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

  local function text_blobs(change)
    if change.binary == true then
      return nil, nil, "binary changes do not support hunk decisions"
    end
    if change.operation ~= "modified" and change.operation ~= "moved" then
      return nil, nil, "hunk decisions require a modified or moved text file"
    end
    local before, before_err = blob(change.before_blob)
    local after, after_err = blob(change.after_blob)
    if before == nil or after == nil then
      return nil, nil, before_err or after_err or "missing text blob"
    end
    return before, after
  end

  local function diff_hunks(before, after)
    local indices = vim.diff(before, after, { result_type = "indices", algorithm = "histogram" })
    local hunks = {}
    for index, item in ipairs(indices or {}) do
      hunks[index] = {
        index = index,
        before_start = item[1],
        before_count = item[2],
        after_start = item[3],
        after_count = item[4],
      }
    end
    return hunks
  end

  local function text_lines(text)
    if text == "" then
      return {}
    end
    return vim.split(text, "\n", { plain = true })
  end

  local function apply_rejected_hunks(before, after, hunks, rejected)
    local before_lines = text_lines(before)
    local result = text_lines(after)
    local selected = {}
    for index in pairs(rejected) do
      if hunks[index] then
        selected[#selected + 1] = hunks[index]
      end
    end
    table.sort(selected, function(left, right)
      local left_position = left.after_count == 0 and left.after_start + 1 or left.after_start
      local right_position = right.after_count == 0 and right.after_start + 1 or right.after_start
      return left_position > right_position
    end)
    for _, hunk in ipairs(selected) do
      local prefix_count = hunk.after_count == 0 and hunk.after_start or (hunk.after_start - 1)
      local replacement = {}
      for offset = 0, hunk.before_count - 1 do
        replacement[#replacement + 1] = before_lines[hunk.before_start + offset]
      end
      local updated = {}
      for index = 1, prefix_count do
        updated[#updated + 1] = result[index]
      end
      vim.list_extend(updated, replacement)
      for index = prefix_count + hunk.after_count + 1, #result do
        updated[#updated + 1] = result[index]
      end
      result = updated
    end
    return table.concat(result, "\n")
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
    local prepared = { path = path, mode = "exact" }
    local desired = change.before_blob and blob(change.before_blob) or nil
    if change.operation == "added" and current == nil then
      prepared.already = true
      prepared.mode = "already"
      return prepared
    elseif change.operation == "deleted" and current ~= nil and desired ~= nil and current == desired then
      prepared.already = true
      prepared.mode = "already"
      return prepared
    elseif change.operation == "modified" and current ~= nil and desired ~= nil and current == desired then
      prepared.already = true
      prepared.mode = "already"
      return prepared
    elseif change.operation == "moved" and current == nil and desired ~= nil then
      local previous, previous_err = absolute_path(root, change.previous_path)
      if not previous then
        return nil, previous_err
      end
      local previous_data, previous_read_err = read_bytes(previous)
      if previous_read_err then
        return nil, previous_read_err
      end
      if previous_data == desired then
        prepared.already = true
        prepared.mode = "already"
        return prepared
      end
    end
    if change.operation == "deleted" then
      if current ~= nil then
        return nil, "file was recreated after the agent turn: " .. path
      end
    else
      local expected, expected_err = blob(change.review_blob or change.after_blob)
      if expected == nil then
        return nil, expected_err or ("missing after blob: " .. path)
      end
      if current ~= expected then
        if change.binary == true or (change.operation ~= "modified" and change.operation ~= "moved") then
          return nil, "file changed after the agent turn: " .. path
        end
        local desired, desired_err = blob(change.before_blob)
        if desired == nil then
          return nil, desired_err or ("missing before blob: " .. path)
        end
        local merged, merge_err = three_way_merge(current or "", expected, desired)
        if merged == nil then
          return nil, merge_err
        end
        prepared.restore_data = merged
        prepared.mode = "three_way"
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
    return prepared
  end

  local function reject_preflighted(change, root, prepared)
    local current, current_err = preflight(change, root)
    if not current then
      return nil, current_err
    end
    prepared = current
    if prepared.already then
      return { mode = prepared.mode }
    end
    local before, before_err = blob(change.before_blob)
    if change.operation ~= "added" and before == nil then
      return nil, before_err or ("missing before blob: " .. prepared.path)
    end
    if change.operation == "added" then
      return uv.fs_unlink(prepared.path)
    elseif change.operation == "modified" or change.operation == "deleted" then
      local written, write_err = write_atomic(prepared.path, prepared.restore_data or before)
      return written and { mode = prepared.mode } or nil, write_err
    elseif change.operation == "moved" then
      local previous, previous_err = absolute_path(root, change.previous_path)
      if not previous then
        return nil, previous_err
      end
      local written, write_err = write_atomic(previous, prepared.restore_data or before)
      if not written then
        return nil, write_err
      end
      local removed, remove_err = uv.fs_unlink(prepared.path)
      if not removed then
        return nil, remove_err
      end
      return { mode = prepared.mode }
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
    local results = {}
    for index, change in ipairs(changes or {}) do
      local result, err = reject_preflighted(change, root, prepared[index])
      if not result then
        return nil, err
      end
      results[index] = type(result) == "table" and result or { mode = prepared[index].mode }
    end
    return results
  end

  function apply.hunks(change)
    local before, after, err = text_blobs(change)
    if not before then
      return nil, err
    end
    return diff_hunks(before, after)
  end

  function apply.reject_hunks(change, root, indices)
    local before, after, text_err = text_blobs(change)
    if not before then
      return nil, text_err
    end
    local hunks = diff_hunks(before, after)
    local rejected = {}
    for _, hunk in ipairs(change.hunks or {}) do
      if hunk.decision == "rejected" then
        rejected[hunk.index] = true
      end
    end
    for _, index in ipairs(indices or {}) do
      if not hunks[index] then
        return nil, "hunk not found: " .. tostring(index)
      end
      rejected[index] = true
    end

    local prepared, preflight_err = preflight(change, root)
    if not prepared then
      return nil, preflight_err
    end
    local desired = apply_rejected_hunks(before, after, hunks, rejected)
    local ref, put_err = opts.put_blob(desired)
    if not ref then
      return nil, put_err
    end
    local written, write_err = write_atomic(prepared.path, desired)
    if not written then
      return nil, write_err
    end
    return ref, hunks
  end

  return apply
end

return M

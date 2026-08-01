local M = {}

local function run(root, args)
  local argv = { "git", "-C", root }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = false }):wait()
  if result.code ~= 0 then
    return nil, vim.trim(tostring(result.stderr or "git command failed"))
  end
  return result.stdout or ""
end

local function trim(value)
  return tostring(value or ""):gsub("%s+$", "")
end

local function zero_tokens(value)
  local result = {}
  for token in tostring(value or ""):gmatch("([^%z]+)") do result[#result + 1] = token end
  return result
end

local function read_file(path)
  local uv = vim.uv or vim.loop
  local fd = uv.fs_open(path, "r", 0)
  if not fd then return nil end
  local stat = uv.fs_fstat(fd)
  local data = stat and uv.fs_read(fd, stat.size, 0) or nil
  uv.fs_close(fd)
  return data
end

local function put(services, data)
  if data == nil then return nil end
  local ref, err = services.put_blob(data)
  if not ref then return nil, err end
  ref.binary = data:find("\0", 1, true) ~= nil
  return ref
end

local function selected_paths(view)
  local ok, api = pcall(require, "diffview.api")
  if not ok or not api.selections then return nil end
  local paths = api.selections.get_paths(view)
  if #paths == 0 then return nil end
  local set = {}
  for _, path in ipairs(paths) do set[path] = true end
  return set
end

local function filter_changes(changes, paths)
  if not paths then return changes end
  local result = {}
  for _, change in ipairs(changes or {}) do
    if paths[change.path] or (change.previous_path and paths[change.previous_path]) then
      result[#result + 1] = change
    end
  end
  return result
end

local function commit_snapshot(root, range, paths, services, source)
  local GitReview = require("lazyagent.acp.git_review")
  local review, err = GitReview.create(range, {
    cwd = root,
    blob_store = { put = function(_, data) return services.put_blob(data) end },
  })
  if not review then return nil, err end
  return {
    root = review.root,
    range = review.range,
    mode = review.mode,
    base = review.base,
    head = review.head,
    changes = filter_changes(review.changes, paths),
    source = source,
  }
end

local function worktree_snapshot(root, base_rev, paths, services, source)
  local base, base_err = run(root, { "rev-parse", "--verify", (base_rev or "HEAD") .. "^{commit}" })
  if not base then return nil, base_err end
  base = trim(base)
  local names, names_err = run(root, { "diff", "--name-status", "-z", "--find-renames", base, "--" })
  if not names then return nil, names_err end
  local tokens, changes, seen, index = zero_tokens(names), {}, {}, 1
  while index <= #tokens do
    local status = tokens[index]
    local code = status:sub(1, 1)
    local old_path, path
    if code == "R" or code == "C" then
      old_path, path = tokens[index + 1], tokens[index + 2]
      index = index + 3
    else
      path, old_path = tokens[index + 1], tokens[index + 1]
      index = index + 2
    end
    if path and (not paths or paths[path] or paths[old_path]) then
      local operation = code == "A" and "added" or code == "D" and "deleted" or code == "R" and "moved" or "modified"
      local before_data = operation ~= "added" and run(root, { "show", base .. ":" .. old_path }) or nil
      local after_data = operation ~= "deleted" and read_file(vim.fs.joinpath(root, path)) or nil
      local before = put(services, before_data)
      local after = put(services, after_data)
      changes[#changes + 1] = {
        operation = operation,
        path = path,
        previous_path = operation == "moved" and old_path or nil,
        before_blob = before,
        after_blob = after,
        binary = (before and before.binary == true) or (after and after.binary == true) or false,
      }
      seen[path] = true
    end
  end
  local untracked = run(root, { "ls-files", "--others", "--exclude-standard", "-z" }) or ""
  for _, path in ipairs(zero_tokens(untracked)) do
    if not seen[path] and (not paths or paths[path]) then
      local after = put(services, read_file(vim.fs.joinpath(root, path)))
      changes[#changes + 1] = {
        operation = "added", path = path, after_blob = after,
        binary = after and after.binary == true or false,
      }
    end
  end
  table.sort(changes, function(a, b) return a.path < b.path end)
  source.base = base
  return {
    root = root,
    range = (base_rev or "HEAD") .. "..WORKTREE",
    mode = "worktree",
    base = base,
    head = nil,
    changes = changes,
    source = source,
  }
end

function M.capture(view, services)
  if type(view) ~= "table" or not view.adapter or not view.adapter.ctx then return nil end
  local root = tostring(view.adapter.ctx.toplevel or ""):gsub("/$", "")
  if root == "" then return nil end
  local paths = selected_paths(view)

  local history_item = view.panel and view.panel.cur_item
  local history_entry = history_item and history_item[1]
  if history_entry and history_entry.commit and history_entry.commit.hash then
    local hash = history_entry.commit.hash
    if view.panel.single_file and history_item[2] then paths = { [history_item[2].path] = true } else paths = nil end
    return commit_snapshot(root, hash, paths, services, {
      kind = "file_history", frontend = "diffview", mutable = false,
      commit = hash, paths = paths and vim.tbl_keys(paths) or nil, tabpage = view.tabpage,
      instance = vim.g.diffview_extension_instance,
    })
  end

  local left_commit = view.left and view.left.commit
  local right_commit = view.right and view.right.commit
  if left_commit and right_commit then
    return commit_snapshot(root, left_commit .. ".." .. right_commit, paths, services, {
      kind = "diffview", frontend = "diffview", mutable = false,
      left = left_commit, right = right_commit, paths = paths and vim.tbl_keys(paths) or nil, tabpage = view.tabpage,
      instance = vim.g.diffview_extension_instance,
    })
  end

  local base = left_commit or "HEAD"
  return worktree_snapshot(root, base, paths, services, {
    kind = "diffview", frontend = "diffview", mutable = true,
    paths = paths and vim.tbl_keys(paths) or nil, tabpage = view.tabpage,
    instance = vim.g.diffview_extension_instance,
  })
end

function M.refresh(review, services)
  local source = vim.deepcopy(review and review.source or {})
  if source.mutable ~= true then return nil, "review comparison is immutable" end
  local paths
  if type(source.paths) == "table" and #source.paths > 0 then
    paths = {}
    for _, path in ipairs(source.paths) do paths[path] = true end
  end
  return worktree_snapshot(review.root, source.base or review.base or "HEAD", paths, services, source)
end

M._worktree_snapshot = worktree_snapshot
M._filter_changes = filter_changes

return M

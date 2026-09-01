local M = {}

local newer_by_root = {}

local function current_view()
  local ok, lib = pcall(require, "diffview.lib")
  return ok and lib.get_current_view() or nil
end

local function commit_view()
  local view = current_view()
  local commit = view and view.right and view.right.commit
  local root = view and view.adapter and view.adapter.ctx and view.adapter.ctx.toplevel
  if type(commit) ~= "string" or commit == "" or type(root) ~= "string" or root == "" then
    return view
  end
  return view, commit, root
end

local function git_lines(root, args, callback)
  local command = { "git", "-C", root }
  vim.list_extend(command, args)
  vim.system(command, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, vim.trim(result.stderr or ""))
        return
      end
      callback(vim.split(vim.trim(result.stdout or ""), "\n", { trimempty = true }))
    end)
  end)
end

local function remember_path(root, commits)
  newer_by_root[root] = newer_by_root[root] or {}
  for index = 2, #commits do
    newer_by_root[root][commits[index]] = commits[index - 1]
  end
end

local function reopen(view, commit, expected_commit)
  local lib = require("diffview.lib")
  local active = lib.tabpage_to_view(view.tabpage)
  if active ~= view or not active.right or active.right.commit ~= expected_commit then
    return
  end

  local args = { "-C" .. view.adapter.ctx.toplevel, commit .. "^!" }
  if view.cur_entry and view.cur_entry.path then
    args[#args + 1] = "--selected-file=" .. view.cur_entry.path
  end
  if view.path_args and #view.path_args > 0 then
    args[#args + 1] = "--"
    vim.list_extend(args, view.path_args)
  end

  view:close()
  vim.schedule(function()
    vim.api.nvim_cmd({ cmd = "DiffviewOpen", args = args }, {})
  end)
end

local function file_history_action(direction)
  local action = direction > 0 and "select_next_commit" or "select_prev_commit"
  require("diffview.actions")[action]()
end

local function older()
  local view, commit, root = commit_view()
  if not commit then
    file_history_action(1)
    return
  end

  local count = math.max(vim.v.count1, 1)
  git_lines(root, { "rev-list", "--first-parent", "--max-count=" .. (count + 1), commit }, function(commits, err)
    if not commits then
      vim.notify("Could not find an older commit: " .. err, vim.log.levels.ERROR)
    elseif #commits < 2 then
      vim.notify("Already at the oldest commit", vim.log.levels.INFO)
    else
      remember_path(root, commits)
      reopen(view, commits[math.min(count + 1, #commits)], commit)
    end
  end)
end

local function cached_newer(root, commit, count)
  local links = newer_by_root[root] or {}
  local target = commit
  for _ = 1, count do
    target = links[target]
    if not target then return nil end
  end
  return target
end

local function newer()
  local view, commit, root = commit_view()
  if not commit then
    file_history_action(-1)
    return
  end

  local count = math.max(vim.v.count1, 1)
  local cached = cached_newer(root, commit, count)
  if cached then
    reopen(view, cached, commit)
    return
  end

  git_lines(root, { "rev-list", "--first-parent", "--reverse", commit .. "..HEAD" }, function(commits, err)
    if not commits then
      vim.notify("Could not find a newer commit: " .. err, vim.log.levels.ERROR)
    elseif #commits == 0 then
      vim.notify("No newer commit found on the first-parent path to HEAD", vim.log.levels.INFO)
    else
      local path = { commit }
      vim.list_extend(path, commits)
      for index = #path, 2, -1 do
        newer_by_root[root] = newer_by_root[root] or {}
        newer_by_root[root][path[index - 1]] = path[index]
      end
      reopen(view, commits[math.min(count, #commits)], commit)
    end
  end)
end

M.older = older
M.newer = newer
M._newer_by_root = newer_by_root

return M

local M = {}

local function default_run(argv, timeout)
  local ok, result = pcall(function() return vim.system(argv, { text = true }):wait(timeout or 10000) end)
  if not ok then return nil, tostring(result) end
  if result.code ~= 0 then
    local message = vim.trim(result.stderr or "")
    return nil, message ~= "" and message or ("command exited " .. tostring(result.code))
  end
  return result.stdout or ""
end

local function absolute(path)
  return vim.fn.fnamemodify(path, ":p"):gsub("/$", "")
end

function M.create(opts)
  opts = opts or {}
  local root = absolute(opts.root or vim.fn.getcwd())
  local path = absolute(opts.path or "")
  local branch = tostring(opts.branch or "")
  if path == "" or branch == "" then return nil, "worktree path and branch are required" end
  local run = opts.run or default_run
  local top, top_err = run({ "git", "-C", root, "rev-parse", "--show-toplevel" }, 3000)
  if not top then return nil, top_err end
  root = absolute(vim.trim(top))
  local args = { "git", "-C", root, "worktree", "add" }
  if opts.existing_branch == true then
    vim.list_extend(args, { path, branch })
  else
    vim.list_extend(args, { "-b", branch, path, opts.base or "HEAD" })
  end
  local _, create_err = run(args, opts.timeout_ms or 30000)
  if create_err then return nil, create_err end
  return {
    original_root = root,
    worktree_path = path,
    worktree_branch = branch,
    worktree_state = "active",
    worktree_created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }
end

function M.restore(thread)
  local metadata = type(thread) == "table" and thread.metadata or nil
  local path = metadata and metadata.worktree_path or nil
  if not path or path == "" then return nil, "thread has no managed worktree" end
  if vim.fn.isdirectory(path) ~= 1 then return nil, "managed worktree is missing: " .. path end
  return path
end

function M.cleanup(thread, opts)
  opts = opts or {}
  if type(thread) ~= "table" then return nil, "thread is required" end
  if thread.process_id ~= nil then return nil, "close the thread before cleaning its worktree" end
  local metadata = thread.metadata or {}
  local root, path = metadata.original_root, metadata.worktree_path
  if not root or not path then return nil, "thread has no managed worktree" end
  local run = opts.run or default_run
  local status, status_err = run({ "git", "-C", path, "status", "--porcelain" }, 5000)
  if not status then return nil, status_err end
  if vim.trim(status) ~= "" and opts.force ~= true then return nil, "managed worktree has uncommitted changes" end
  local args = { "git", "-C", root, "worktree", "remove" }
  if opts.force == true then args[#args + 1] = "--force" end
  args[#args + 1] = path
  local _, remove_err = run(args, opts.timeout_ms or 30000)
  if remove_err then return nil, remove_err end
  local updated = vim.deepcopy(metadata)
  updated.worktree_state = "cleaned"
  updated.worktree_cleaned_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  return updated
end

return M

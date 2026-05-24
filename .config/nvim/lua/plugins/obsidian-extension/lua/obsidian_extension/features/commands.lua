local M = {}

local vault_path = vim.fn.expand("~/workspace/obsidian")

local function trim(text)
  return (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function is_vault_path(path)
  return path == vault_path or path:sub(1, #vault_path + 1) == vault_path .. "/"
end

local function notify_git_error(prefix, result)
  local detail = ""
  if result then
    detail = trim(result.stderr ~= "" and result.stderr or result.stdout or "")
  end
  if detail ~= "" then
    vim.notify(prefix .. ": " .. detail, vim.log.levels.ERROR)
    return
  end
  vim.notify(prefix, vim.log.levels.ERROR)
end

local function git_result_text(result)
  if not result then
    return ""
  end
  return trim(result.stderr ~= "" and result.stderr or result.stdout or "")
end

local function run_git(args, on_done)
  vim.system(args, { cwd = vault_path, text = true }, function(result)
    vim.schedule(function()
      on_done(result)
    end)
  end)
end

local function run_system(args, cwd)
  return vim.system(args, { cwd = cwd, text = true }):wait()
end

local function normalize_note_segment(text, fallback)
  local normalized = trim(text)
    :gsub("[/\\]", "-")
    :gsub("[^%w%._-]", "-")
    :gsub("%-+", "-")
    :gsub("^[-_.]+", "")
    :gsub("[-_.]+$", "")
  if normalized == "" then
    return fallback
  end
  return normalized
end

local function current_context_dir()
  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname ~= "" then
    local stat = vim.uv.fs_stat(bufname)
    if stat then
      if stat.type == "directory" then
        return bufname
      end
      return vim.fs.dirname(bufname)
    end

    local bufdir = vim.fs.dirname(bufname)
    if bufdir and vim.uv.fs_stat(bufdir) then
      return bufdir
    end
  end

  return vim.fn.getcwd()
end

local function current_git_context()
  local start_dir = current_context_dir()
  local repo_result = run_system({ "git", "rev-parse", "--show-toplevel" }, start_dir)
  if repo_result.code ~= 0 then
    return nil, repo_result
  end

  local repo_root = trim(repo_result.stdout or "")
  local repo_name = vim.fs.basename(repo_root)
  local repo_slug = normalize_note_segment(repo_name, "project")

  local branch_result = run_system({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, repo_root)
  if branch_result.code ~= 0 then
    return nil, branch_result
  end

  local branch_name = trim(branch_result.stdout or "")
  if branch_name == "" then
    branch_name = "HEAD"
  end

  local branch_segments = vim.split(branch_name, "/", { trimempty = true })
  if vim.tbl_isempty(branch_segments) then
    branch_segments = { "HEAD" }
  end

  local note_segments = {}
  for index, segment in ipairs(branch_segments) do
    note_segments[index] = normalize_note_segment(segment, ("branch-%d"):format(index))
  end

  return {
    repo_root = repo_root,
    repo_name = repo_name,
    repo_slug = repo_slug,
    branch_name = branch_name,
    branch_note_segments = note_segments,
  }
end

local function branch_note_spec(context)
  local relative_dir = ("notes/projects/%s"):format(context.repo_slug)
  if #context.branch_note_segments > 1 then
    relative_dir = relative_dir .. "/"
      .. table.concat(context.branch_note_segments, "/", 1, #context.branch_note_segments - 1)
  end

  return {
    title = ("%s / %s"):format(context.repo_name, context.branch_name),
    id = context.branch_note_segments[#context.branch_note_segments],
    dir = relative_dir,
    tags = { "project-note", "branch-note" },
  }
end

local function repo_note_spec(context)
  return {
    title = context.repo_name,
    id = "index",
    dir = ("notes/projects/%s"):format(context.repo_slug),
    tags = { "project-note", "repo-note" },
  }
end

local function open_or_create_note(spec)
  local client = require("obsidian").get_client()
  local note_path = client:new_note_path({
    id = spec.id,
    dir = client.dir / spec.dir,
    title = spec.title,
  })

  if note_path:exists() then
    client:open_note(note_path, { sync = true })
    return
  end

  local note = client:create_note({
    title = spec.title,
    id = spec.id,
    dir = spec.dir,
    tags = spec.tags,
    no_write = true,
  })
  client:open_note(note, { sync = true })
  client:write_note_to_buffer(note)
end

local function write_vault_buffers()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified and vim.bo[bufnr].buftype == "" then
      local path = vim.api.nvim_buf_get_name(bufnr)
      if path ~= "" and is_vault_path(path) then
        local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
          vim.cmd("silent write")
        end)
        if not ok then
          vim.notify(("Failed to save Obsidian note before git push: %s"):format(tostring(err)), vim.log.levels.ERROR)
          return false
        end
      end
    end
  end
  return true
end

local function notify_git_success(message)
  vim.notify("Obsidian pushed: " .. message, vim.log.levels.INFO)
end

local function push_with_upstream(message, remote_name)
  run_git({ "git", "push", "-u", remote_name, "HEAD" }, function(push_result)
    if push_result.code ~= 0 then
      notify_git_error("Committed Obsidian changes but failed to push with upstream setup", push_result)
      return
    end
    notify_git_success(message)
  end)
end

local function push_with_remote_fallback(message)
  run_git({ "git", "remote" }, function(remote_result)
    if remote_result.code ~= 0 then
      notify_git_error("Committed Obsidian changes but failed to inspect git remotes", remote_result)
      return
    end

    local remotes = vim.split(trim(remote_result.stdout or ""), "\n", { trimempty = true })
    if #remotes == 0 then
      vim.notify("Committed Obsidian changes, but no git remote is configured for push", vim.log.levels.WARN)
      return
    end

    local remote_name = vim.tbl_contains(remotes, "origin") and "origin" or remotes[1]
    push_with_upstream(message, remote_name)
  end)
end

local function push_changes(message)
  run_git({ "git", "push" }, function(push_result)
    if push_result.code == 0 then
      notify_git_success(message)
      return
    end

    local push_text = git_result_text(push_result)
    if not push_text:match("no upstream branch")
      and not push_text:match("No configured push destination")
    then
      notify_git_error("Committed Obsidian changes but failed to push", push_result)
      return
    end

    push_with_remote_fallback(message)
  end)
end

local function commit_changes(message)
  run_git({ "git", "commit", "-m", message }, function(commit_result)
    if commit_result.code ~= 0 then
      notify_git_error("Failed to commit Obsidian changes", commit_result)
      return
    end

    push_changes(message)
  end)
end

local function ensure_staged_changes(message)
  run_git({ "git", "diff", "--cached", "--quiet" }, function(diff_result)
    if diff_result.code == 0 then
      vim.notify("Obsidian vault has no staged changes", vim.log.levels.INFO)
      return
    end
    if diff_result.code ~= 1 then
      notify_git_error("Failed to inspect staged Obsidian changes", diff_result)
      return
    end

    commit_changes(message)
  end)
end

local function stage_changes(message)
  run_git({ "git", "add", "-A" }, function(add_result)
    if add_result.code ~= 0 then
      notify_git_error("Failed to stage Obsidian changes", add_result)
      return
    end

    ensure_staged_changes(message)
  end)
end

local function ensure_git_repo(message)
  run_git({ "git", "rev-parse", "--show-toplevel" }, function(repo_check)
    if repo_check.code ~= 0 then
      notify_git_error("Obsidian vault is not a git repository", repo_check)
      return
    end

    stage_changes(message)
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("ObsidianGit", function(cmd_opts)
    if not write_vault_buffers() then
      return
    end

    local message = os.date("%Y-%m-%d %H:%M:%S") .. "**obsidian"
    local extra = trim(cmd_opts.args)
    if extra ~= "" then
      message = message .. " " .. extra
    end

    ensure_git_repo(message)
  end, {
    nargs = "*",
    desc = "Commit and push the Obsidian vault",
  })

  vim.api.nvim_create_user_command("ObsidianBranchNote", function()
    local context, err = current_git_context()
    if not context then
      notify_git_error("Current buffer is not inside a git repository", err)
      return
    end

    open_or_create_note(branch_note_spec(context))
  end, {
    desc = "Open or create a branch-scoped project note",
  })

  vim.api.nvim_create_user_command("ObsidianRepoNote", function()
    local context, err = current_git_context()
    if not context then
      notify_git_error("Current buffer is not inside a git repository", err)
      return
    end

    open_or_create_note(repo_note_spec(context))
  end, {
    desc = "Open or create a repo-scoped project note",
  })
end

return M

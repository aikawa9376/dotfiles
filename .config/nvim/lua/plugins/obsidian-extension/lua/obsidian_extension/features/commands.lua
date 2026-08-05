local M = {}
local context = require("obsidian_extension.context")

local function trim(text)
  return (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
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
  vim.system(args, { cwd = context.vault_path(), text = true }, function(result)
    vim.schedule(function()
      on_done(result)
    end)
  end)
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
    metadata = {
      type = "project",
      project = context.repo_slug,
      branch = context.branch_name,
    },
    metadata_defaults = {
      source = "manual",
      status = "seed",
    },
  }
end

local function repo_note_spec(context)
  return {
    title = context.repo_name,
    id = "index",
    dir = ("notes/projects/%s"):format(context.repo_slug),
    tags = { "project-note", "repo-note" },
    metadata = {
      type = "project",
      project = context.repo_slug,
    },
    metadata_defaults = {
      source = "manual",
      status = "evergreen",
    },
  }
end

local function apply_note_metadata(note, spec)
  for key, value in pairs(spec.metadata or {}) do
    note:add_field(key, value)
  end
  for key, value in pairs(spec.metadata_defaults or {}) do
    if note:get_field(key) == nil then
      note:add_field(key, value)
    end
  end
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
    local bufnr = vim.api.nvim_get_current_buf()
    local note = client:current_note(bufnr)
    if note then
      apply_note_metadata(note, spec)
      client:update_frontmatter(note, bufnr)
    end
    return
  end

  local note = client:create_note({
    title = spec.title,
    id = spec.id,
    dir = spec.dir,
    tags = spec.tags,
    no_write = true,
  })
  apply_note_metadata(note, spec)
  client:open_note(note, { sync = true })
  client:write_note_to_buffer(note)
end

local function write_vault_buffers()
  local vault_path = context.vault_path()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified and vim.bo[bufnr].buftype == "" then
      local path = vim.api.nvim_buf_get_name(bufnr)
      if path ~= "" and context.is_vault_path(path, vault_path) then
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
    local git_context, err = context.git()
    if not git_context then
      notify_git_error("Current buffer is not inside a git repository", err)
      return
    end

    open_or_create_note(branch_note_spec(git_context))
  end, {
    desc = "Open or create a branch-scoped project note",
  })

  vim.api.nvim_create_user_command("ObsidianRepoNote", function()
    local git_context, err = context.git()
    if not git_context then
      notify_git_error("Current buffer is not inside a git repository", err)
      return
    end

    open_or_create_note(repo_note_spec(git_context))
  end, {
    desc = "Open or create a repo-scoped project note",
  })
end

return M

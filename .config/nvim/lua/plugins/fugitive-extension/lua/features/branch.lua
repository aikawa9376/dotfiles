local M = {}
local help = require("features.help")

_G.fugitive_branch_completion = function(arg_lead, cmd_line, cursor_pos)
  local branches = vim.fn.systemlist("git branch -a --format='%(refname:short)'")
  if vim.v.shell_error ~= 0 then return {} end
  local matches = {}
  for _, b in ipairs(branches) do
    if b:match(arg_lead) then
      table.insert(matches, b)
    end
  end
  return matches
end

local function get_ahead_behind(branch, upstream, cmd_prefix)
  if not upstream or upstream == '' then
    return 0, 0
  end

  cmd_prefix = cmd_prefix or 'git '
  local result = vim.fn.system(string.format('%srev-list --left-right --count %s...%s 2>/dev/null', cmd_prefix, branch, upstream))
  if vim.v.shell_error ~= 0 then
    return 0, 0
  end

  local ahead, behind = result:match('(%d+)%s+(%d+)')
  return tonumber(ahead) or 0, tonumber(behind) or 0
end

local function get_branch_list()
  local cmd_prefix = "git "
  -- Use buffer context for git command to handle submodules and worktrees correctly
  local current_file = vim.api.nvim_buf_get_name(0)
  if current_file:match("^fugitive%-branch://") then
    local path = current_file:sub(#"fugitive-branch://" + 1)
    cmd_prefix = string.format("git -C %s ", vim.fn.shellescape(path))
  elseif current_file ~= "" and not current_file:match("^fugitive://") then
    local current_dir = vim.fn.fnamemodify(current_file, ":p:h")
    cmd_prefix = string.format("git -C %s ", vim.fn.shellescape(current_dir))
  else
    local git_dir = vim.fn.FugitiveGitDir()
    if git_dir ~= "" then
      local work_tree = vim.fn.systemlist(string.format("git --git-dir=%s rev-parse --show-toplevel 2>/dev/null", vim.fn.shellescape(git_dir)))[1]
      if work_tree and work_tree ~= "" then
         cmd_prefix = string.format("git -C %s ", vim.fn.shellescape(work_tree))
      end
    end
  end

  local local_branches = vim.fn.systemlist(cmd_prefix .. "for-each-ref --sort=-committerdate --format='%(HEAD)|%(refname:short)|%(upstream:short)|%(committerdate:relative)|%(authorname)|%(contents:subject)' refs/heads/")
  local remote_branches = vim.fn.systemlist(cmd_prefix .. "for-each-ref --sort=-committerdate --format='%(HEAD)|%(refname:short)|%(upstream:short)|%(committerdate:relative)|%(authorname)|%(contents:subject)' refs/remotes/")

  if vim.v.shell_error ~= 0 then
    return {}
  end
  
  -- Combine local branches first, then remote branches
  local raw_branches = {}
  for _, line in ipairs(local_branches) do
    table.insert(raw_branches, line)
  end
  for _, line in ipairs(remote_branches) do
    -- Skip "origin" alone (origin/HEAD symref)
    local branch = line:match('^[* ]?|([^|]+)')
    if branch and branch ~= 'origin' then
      table.insert(raw_branches, line)
    end
  end
  
  -- First pass: collect all data
  local branches = {}
  local max_branch_len = 0
  local max_push_len = 0
  local max_subject_len = 0
  local max_date_len = 0
  local max_author_len = 0

  for _, line in ipairs(raw_branches) do
    local head, branch, upstream, date, author, subject = line:match('^([* ]?)|(.-)|(.-)|(.-)|(.-)|(.*)')
    if branch then
      local ahead, behind = 0, 0
      -- Only calculate ahead/behind for local branches
      if not branch:match('^origin/') then
         -- Pass cmd_prefix to use correct git context for rev-list
         ahead, behind = get_ahead_behind(branch, upstream, cmd_prefix)
      end

      local push_info = ''
      if behind > 0 then
        push_info = push_info .. string.format('↓%d', behind)
      end
      if ahead > 0 then
        push_info = push_info .. string.format('↑%d', ahead)
      end

      local upstream_str = upstream ~= '' and string.format('[%s]', upstream) or ''

      -- Shorten relative date
      date = date:gsub(',.*', '') -- Keep only the first part
      date = date:gsub(' ago', '')
      date = date:gsub(' years?', 'y')
      date = date:gsub(' months?', 'mo')
      date = date:gsub(' weeks?', 'w')
      date = date:gsub(' days?', 'd')
      date = date:gsub(' hours?', 'h')
      date = date:gsub(' minutes?', 'm')
      date = date:gsub(' seconds?', 's')

      table.insert(branches, {
        head = head == '*' and '* ' or '  ',
        branch = branch,
        push_info = push_info,
        subject = subject,
        upstream_str = upstream_str,
        date = date,
        author = author,
      })

      max_branch_len = math.max(max_branch_len, vim.fn.strdisplaywidth(branch))
      max_push_len = math.max(max_push_len, vim.fn.strdisplaywidth(push_info))
      max_subject_len = math.max(max_subject_len, vim.fn.strdisplaywidth(subject))
      max_date_len = math.max(max_date_len, vim.fn.strdisplaywidth(date))
      max_author_len = math.max(max_author_len, vim.fn.strdisplaywidth(author))
    end
  end

  -- Second pass: format with calculated widths
  -- Cap widths to avoid string.format limits (max 99)
  max_branch_len = math.min(max_branch_len, 50)
  max_push_len = math.min(max_push_len, 20)
  max_subject_len = 40  -- Fixed width for subject
  max_date_len = math.min(max_date_len, 6)
  max_author_len = math.min(max_author_len, 15)

  -- Helper function to pad string based on display width and truncate if necessary
  local function pad_right(str, width)
    local display_width = vim.fn.strdisplaywidth(str)
    
    if display_width > width then
      -- Truncate string to fit width
      local truncated = ''
      local current_width = 0
      
      -- If width is very small, we might just return empty or partial
      if width <= 3 then
         local chars = vim.fn.split(str, '\\zs')
         for _, char in ipairs(chars) do
            local w = vim.fn.strdisplaywidth(char)
            if current_width + w > width then break end
            truncated = truncated .. char
            current_width = current_width + w
         end
         return truncated .. string.rep(' ', width - current_width)
      end

      -- Reserve space for '...'
      local target_width = width - 3
      local chars = vim.fn.split(str, '\\zs')
      
      for _, char in ipairs(chars) do
        local char_width = vim.fn.strdisplaywidth(char)
        if current_width + char_width > target_width then
          break
        end
        truncated = truncated .. char
        current_width = current_width + char_width
      end
      return truncated .. '...' .. string.rep(' ', width - (current_width + 3))
    elseif display_width == width then
      return str
    else
      return str .. string.rep(' ', width - display_width)
    end
  end

  local formatted = {}
  for _, b in ipairs(branches) do
    -- Combine branch name with push info
    local branch_block = b.branch
    if b.push_info ~= '' then
      branch_block = branch_block .. ' ' .. b.push_info
    end
    
    local subject = b.subject
    local author = b.author

    local line = b.head .. pad_right(branch_block, max_branch_len) .. '  ' .. pad_right(b.date, max_date_len) .. '  ' .. pad_right(b.author, max_author_len) .. '  ' .. pad_right(subject, max_subject_len)
    -- Add upstream if exists, otherwise trim trailing spaces
    if b.upstream_str ~= '' then
      line = line .. '  ' .. b.upstream_str
    else
      line = line:gsub('%s+$', '')
    end
    table.insert(formatted, line)
  end

  return formatted
end

local function get_branch_name_from_line(line)
  line = line or vim.api.nvim_get_current_line()
  -- Extract branch name (after * or spaces, before first double space)
  local branch = line:match('^[* ]%s*(%S+)')
  return branch
end

local function refresh_branch_list(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.api.nvim_set_option_value('modifiable', true, { buf = bufnr })

  local branch_output = get_branch_list()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, branch_output)

  vim.api.nvim_set_option_value('modifiable', false, { buf = bufnr })
end


local function delete_branches(bufnr, branches)
  if #branches == 0 then
    vim.notify("No branches to delete", vim.log.levels.WARN)
    return
  end

  local branch_list = table.concat(branches, ", ")
  local confirm = vim.fn.confirm(
    string.format("Delete %d branch(es)?\n%s", #branches, branch_list),
    "&Yes\n&No",
    2
  )

  if confirm ~= 1 then
    return
  end

  local deleted = {}
  local failed = {}

  for _, branch in ipairs(branches) do
    -- Skip current branch (with *)
    if branch:match('^%*') then
      table.insert(failed, branch .. " (current branch)")
    else
      -- Try to delete branch
      local result = vim.fn.system(string.format('git branch -d %s 2>&1', branch))
      if vim.v.shell_error ~= 0 then
        -- If normal delete fails, ask for force delete
        if result:match("not fully merged") then
          local force_confirm = vim.fn.confirm(
            string.format("Branch '%s' is not fully merged. Force delete?", branch),
            "&Yes\n&No",
            2
          )
          if force_confirm == 1 then
            result = vim.fn.system(string.format('git branch -D %s 2>&1', branch))
            if vim.v.shell_error == 0 then
              table.insert(deleted, branch)
            else
              table.insert(failed, branch .. " (" .. result:gsub("\n", "") .. ")")
            end
          else
            table.insert(failed, branch .. " (cancelled)")
          end
        else
          table.insert(failed, branch .. " (" .. result:gsub("\n", "") .. ")")
        end
      else
        table.insert(deleted, branch)
      end
    end
  end

  -- Show results
  if #deleted > 0 then
    -- vim.notify(string.format("Deleted: %s", table.concat(deleted, ", ")), vim.log.levels.INFO)
  end
  if #failed > 0 then
    vim.notify(string.format("Failed: %s", table.concat(failed, ", ")), vim.log.levels.WARN)
  end

  -- Refresh the list
  vim.defer_fn(function()
    refresh_branch_list(bufnr)
  end, 100)
end

local function checkout_branch(bufnr)
  local branch = get_branch_name_from_line()
  if not branch then
    vim.notify("No branch found on this line", vim.log.levels.WARN)
    return
  end

  -- Remove remotes/ prefix if present
  local checkout_name = branch:gsub('^origin/', '')

  local commands = require('features.commands')
  local git_dir = vim.fn.FugitiveGitDir()
  local work_tree = vim.fn.trim(vim.fn.system('git --git-dir=' .. vim.fn.shellescape(git_dir) .. ' rev-parse --show-toplevel'))

  local stashed = commands.apply_auto_stash(work_tree)
  if stashed == nil then return end

  vim.cmd('Git checkout ' .. checkout_name)

  if stashed then
    commands.pop_auto_stash(work_tree)
  end

  -- Refresh the branch list after checkout
  vim.defer_fn(function()
    refresh_branch_list(bufnr)
  end, 200)
end

local function rename_branch(bufnr)
  local old_name = get_branch_name_from_line()
  if not old_name then
    vim.notify("No branch found on this line", vim.log.levels.WARN)
    return
  end

  -- Can't rename remote branches directly.
  if old_name:match('^origin/') then
    vim.notify("Cannot rename remote branches directly.", vim.log.levels.WARN)
    return
  end

  local new_name = vim.fn.input('Rename ' .. old_name .. ' to: ', old_name)
  vim.cmd('redraw') -- Clear the prompt.

  if new_name == nil or new_name == '' or new_name == old_name then
    -- vim.notify("Rename cancelled.", vim.log.levels.INFO)
    return
  end

  local cmd = string.format("git branch -m %s %s", vim.fn.shellescape(old_name), vim.fn.shellescape(new_name))
  local result = vim.fn.system(cmd)

  if vim.v.shell_error ~= 0 then
    vim.notify("Failed to rename branch: " .. vim.fn.trim(result), vim.log.levels.ERROR)
  else
    -- vim.notify(string.format("Renamed branch %s to %s", old_name, new_name), vim.log.levels.INFO)
    vim.defer_fn(function()
      refresh_branch_list(bufnr)
    end, 100)
  end
end

local function duplicate_branch(bufnr)
  local old_name = get_branch_name_from_line()
  if not old_name then
    vim.notify("No branch found on this line", vim.log.levels.WARN)
    return
  end

  -- Default: remove origin/ from remote branches for the default new name
  local default_new_name = old_name:gsub('^origin/', '') .. '-copy'
  local new_name = vim.fn.input('Duplicate ' .. old_name .. ' to: ', default_new_name)
  vim.cmd('redraw') -- Clear the prompt.

  if new_name == nil or new_name == '' or new_name == old_name then
    -- vim.notify("Duplicate cancelled.", vim.log.levels.INFO)
    return
  end

  -- Do not allow creating a new branch name that begins with the remote prefix
  if new_name:match('^origin/') then
    vim.notify("Please specify a local branch name (no remote prefixes).", vim.log.levels.WARN)
    return
  end

  -- If a local branch with the target name exists, ask to overwrite
  vim.fn.system(string.format('git rev-parse --verify --quiet refs/heads/%s 2>/dev/null', vim.fn.shellescape(new_name)))
  if vim.v.shell_error == 0 then
    local overwrite = vim.fn.confirm(
      string.format("Local branch '%s' already exists. Overwrite?", new_name),
      "&Yes\n&No",
      2
    )
    if overwrite ~= 1 then
      -- vim.notify("Duplicate cancelled.", vim.log.levels.INFO)
      return
    end
    local del_result = vim.fn.system(string.format('git branch -D %s 2>&1', vim.fn.shellescape(new_name)))
    if vim.v.shell_error ~= 0 then
      vim.notify("Failed to delete existing branch: " .. vim.fn.trim(del_result), vim.log.levels.ERROR)
      return
    end
  end

  -- Create a new local branch pointing to the same commit as `old_name`.
  -- `old_name` may be local (e.g., "main") or remote (e.g., "origin/main")
  local cmd = string.format('git branch %s %s 2>&1', vim.fn.shellescape(new_name), vim.fn.shellescape(old_name))
  local result = vim.fn.system(cmd)

  if vim.v.shell_error ~= 0 then
    vim.notify("Failed to duplicate branch: " .. vim.fn.trim(result), vim.log.levels.ERROR)
  else
    -- vim.notify(string.format("Duplicated branch %s to %s", old_name, new_name), vim.log.levels.INFO)
    vim.defer_fn(function()
      refresh_branch_list(bufnr)
    end, 100)
  end
end

local function create_worktree()
  local branch = get_branch_name_from_line()
  if not branch then
    vim.notify("No branch found on this line", vim.log.levels.WARN)
    return
  end

  local worktree_name = branch:gsub('^origin/', '')
  local worktree_path = vim.fn.input('Worktree path for ' .. branch .. ': ', '../' .. worktree_name)
  vim.cmd('redraw') -- Clear the prompt.

  if worktree_path == nil or worktree_path == '' then
    -- vim.notify("Worktree creation cancelled.", vim.log.levels.INFO)
    return
  end

  local cmd = string.format("git worktree add %s %s", vim.fn.shellescape(worktree_path), vim.fn.shellescape(branch))
  local result = vim.fn.system(cmd)

  if vim.v.shell_error ~= 0 then
    vim.notify("Failed to create worktree: " .. vim.fn.trim(result), vim.log.levels.ERROR)
  else
    -- vim.notify(string.format("Created worktree for '%s' at %s", branch, worktree_path), vim.log.levels.INFO)
  end
end

local function fetch_all(bufnr)
  -- vim.notify("Fetching...", vim.log.levels.INFO)
  vim.fn.jobstart("git fetch --all --prune", {
    on_exit = function(_, exit_code)
      if exit_code == 0 then
        -- vim.notify("Fetch complete", vim.log.levels.INFO)
        vim.schedule(function()
          refresh_branch_list(bufnr)
        end)
      else
        vim.notify("Fetch failed", vim.log.levels.ERROR)
      end
    end
  })
end

local function handle_pull_error(work_tree, message, args, on_success)
  if message:match("Not possible to fast%-forward") or message:match("diverged") or message:match("Need to specify how to reconcile") then
    local choice = vim.fn.confirm("Pull failed: Diverged branches.\nHow do you want to proceed?", "&Rebase\n&Merge (Commit)\n&Abort", 3)
    if choice == 1 then -- Rebase
      local cmd = "git -C " .. vim.fn.shellescape(work_tree) .. " pull --rebase" .. args
      local out = vim.fn.system(cmd)
      if vim.v.shell_error == 0 then
        vim.notify("Pull --rebase successful.", vim.log.levels.INFO)
        if on_success then on_success() end
        return true
      else
        return false, "Pull --rebase failed:\n" .. out
      end
    elseif choice == 2 then -- Merge
      local cmd = "git -C " .. vim.fn.shellescape(work_tree) .. " pull --no-ff" .. args
      local out = vim.fn.system(cmd)
      if vim.v.shell_error == 0 then
        vim.notify("Pull --no-ff successful.", vim.log.levels.INFO)
        if on_success then on_success() end
        return true
      else
        return false, "Pull --no-ff failed:\n" .. out
      end
    end
    return true -- Handled (aborted or attempted)
  end
  return false -- Not handled
end

local function pull_branch(bufnr)
  local branch = get_branch_name_from_line()
  if not branch then
    vim.notify("No branch found on this line", vim.log.levels.WARN)
    return
  end

  -- Check if branch is current
  local current_branch = vim.fn.trim(vim.fn.system("git branch --show-current"))
  if branch ~= current_branch then
    vim.notify("Cannot pull: " .. branch .. " is not checked out.", vim.log.levels.WARN)
    return
  end

  -- Check upstream
  vim.fn.system("git rev-parse --abbrev-ref " .. vim.fn.shellescape(branch) .. "@{u}")
  local has_upstream = (vim.v.shell_error == 0)

  local args = ""
  if not has_upstream then
    local upstream = vim.fn.input('Pull from (e.g. origin main): ')
    vim.cmd('redraw')
    if upstream and upstream ~= '' then
       args = " " .. upstream
    else
       return
    end
  end

  local commands = require('features.commands')
  local git_dir = vim.fn.FugitiveGitDir()
  local work_tree = vim.fn.trim(vim.fn.system('git --git-dir=' .. vim.fn.shellescape(git_dir) .. ' rev-parse --show-toplevel'))

  local stashed = commands.apply_auto_stash(work_tree)
  if stashed == nil then return end

  -- vim.notify("Pulling...", vim.log.levels.INFO)
  local output_lines = {}
  vim.fn.jobstart("git -C " .. vim.fn.shellescape(work_tree) .. " pull" .. args, {
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line and line ~= "" then
            table.insert(output_lines, line)
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line and line ~= "" then
            table.insert(output_lines, line)
          end
        end
      end
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        if stashed then commands.pop_auto_stash(work_tree) end
        local message = table.concat(output_lines, "\n")
        if exit_code == 0 then
          refresh_branch_list(bufnr)
        else
          local handled, err_msg = handle_pull_error(work_tree, message, args, function()
             refresh_branch_list(bufnr)
          end)
          if handled then
             if err_msg then
                vim.notify(err_msg, vim.log.levels.ERROR)
             end
          else
             vim.notify("Pull failed\n" .. message, vim.log.levels.ERROR)
          end
        end
      end)
    end
  })
end

local function pull_branch_under_cursor(bufnr)
  local branch = get_branch_name_from_line()
  if not branch then
    vim.notify("No branch found on this line", vim.log.levels.WARN)
    return
  end

  local current_branch = vim.fn.trim(vim.fn.system("git branch --show-current"))

  if branch == current_branch then
    pull_branch(bufnr)
    return
  end

  -- Check upstream
  vim.fn.system("git rev-parse --abbrev-ref " .. vim.fn.shellescape(branch) .. "@{u}")
  local has_upstream = (vim.v.shell_error == 0)

  local args = ""
  if not has_upstream then
    local upstream = vim.fn.input('Pull ' .. branch .. ' from (e.g. origin main): ')
    vim.cmd('redraw')
    if upstream and upstream ~= '' then
       args = " " .. upstream
    else
       return
    end
  end

  local commands = require('features.commands')
  local git_dir = vim.fn.FugitiveGitDir()
  local work_tree = vim.fn.trim(vim.fn.system('git --git-dir=' .. vim.fn.shellescape(git_dir) .. ' rev-parse --show-toplevel'))

  local stashed = commands.apply_auto_stash(work_tree)
  if stashed == nil then return end

  -- Checkout target branch
  local out = vim.fn.system("git checkout " .. vim.fn.shellescape(branch) .. " 2>&1")
  if vim.v.shell_error ~= 0 then
    vim.notify("Failed to checkout " .. branch .. ": " .. out, vim.log.levels.ERROR)
    if stashed then commands.pop_auto_stash(work_tree) end
    return
  end

  -- vim.notify("Pulling " .. branch .. "...", vim.log.levels.INFO)
  local output_lines = {}
  vim.fn.jobstart("git -C " .. vim.fn.shellescape(work_tree) .. " pull" .. args, {
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line and line ~= "" then
            table.insert(output_lines, line)
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line and line ~= "" then
            table.insert(output_lines, line)
          end
        end
      end
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        local message = table.concat(output_lines, "\n")
        local pull_success = (exit_code == 0)

        -- Checkout back to original branch
        local co_out = vim.fn.system("git checkout " .. vim.fn.shellescape(current_branch) .. " 2>&1")
        if vim.v.shell_error ~= 0 then
           vim.notify("Pull " .. (pull_success and "succeeded" or "failed") .. " but could not switch back to " .. current_branch .. "\n" .. co_out .. "\n\nPull output:\n" .. message, vim.log.levels.ERROR)
           -- Do not pop stash if we are on the wrong branch
           return
        end

        if stashed then commands.pop_auto_stash(work_tree) end

        if pull_success then
          refresh_branch_list(bufnr)
        else
          local handled, err_msg = handle_pull_error(work_tree, message, args, function()
             refresh_branch_list(bufnr)
          end)
          if handled then
             if err_msg then
                vim.notify(err_msg, vim.log.levels.ERROR)
             end
          else
             vim.notify("Pull failed for " .. branch .. "\n" .. message, vim.log.levels.ERROR)
          end
        end
      end)
    end
  })
end

local function get_default_origin_head()
  local default_branch = "origin/main"
  local handle = io.popen("git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null")
  if handle then
    local result = handle:read("*a")
    handle:close()
    if result and result ~= "" then
      default_branch = result:gsub("refs/remotes/", ""):gsub("\n", "")
    end
  end
  return default_branch
end

local function diff_against_default(bufnr)
  local branch = get_branch_name_from_line()
  if not branch then
    vim.notify("No branch found on this line", vim.log.levels.WARN)
    return
  end

  local default_branch = get_default_origin_head()

  -- Notify and fetch
  vim.notify("Fetching origin...", vim.log.levels.INFO)

  -- Use jobstart for async fetch
  vim.fn.jobstart("git fetch origin", {
    on_exit = function(_, exit_code)
      if exit_code ~= 0 then
        vim.notify("Fetch failed", vim.log.levels.ERROR)
        return
      end

      -- Open Diffview in a scheduled callback to ensure we are in the right context
      vim.schedule(function()
        -- Compare default_branch...branch (3 dots for merge base diff - GitHub PR style)
        -- The user said "origin and github equivalent diff", so origin/main...branch
        local diff_cmd = "DiffviewOpen " .. default_branch .. "..." .. branch
        vim.cmd(diff_cmd)
        vim.notify("Opened diff: " .. default_branch .. "..." .. branch, vim.log.levels.INFO)
      end)
    end
  })
end

local function rebase_with_stash_fetch(bufnr, default_target)
  local commands = require('features.commands')
  local git_dir = vim.fn.FugitiveGitDir()
  local work_tree = vim.fn.trim(vim.fn.system('git --git-dir=' .. vim.fn.shellescape(git_dir) .. ' rev-parse --show-toplevel'))

  local target_default = default_target or get_default_origin_head()
  local target = vim.fn.input('Rebase on: ', target_default, 'customlist,v:lua.fugitive_branch_completion')
  vim.cmd('redraw')
  if target == '' then return end

  -- Auto stash
  local stashed = commands.apply_auto_stash(work_tree)
  if stashed == nil then return end

  local cmd = string.format("git fetch && git rebase %s", vim.fn.shellescape(target))

  vim.notify("Running: " .. cmd, vim.log.levels.INFO)

  local output_lines = {}
  vim.fn.jobstart(cmd, {
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then table.insert(output_lines, line) end
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then table.insert(output_lines, line) end
        end
      end
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        local message = table.concat(output_lines, "\n")
        if exit_code == 0 then
          if stashed then
             local pop_ok = commands.pop_auto_stash(work_tree)
             if not pop_ok then
                vim.notify("Rebase successful, but stash pop failed.", vim.log.levels.WARN)
             else
                vim.notify("Rebase successful.", vim.log.levels.INFO)
             end
          else
             vim.notify("Rebase successful.", vim.log.levels.INFO)
          end
          refresh_branch_list(bufnr)
        else
          vim.notify("Rebase failed.\n" .. message, vim.log.levels.ERROR)
          if stashed then
            vim.notify("Note: Changes were stashed. Resolve rebase conflicts, then run 'git stash pop'.", vim.log.levels.WARN)
          end
        end
      end)
    end
  })
end

local function merge_with_input(bufnr, default_target)
  local target_default = default_target or get_default_origin_head()
  local target = vim.fn.input('Merge: ', target_default, 'customlist,v:lua.fugitive_branch_completion')
  vim.cmd('redraw')
  if target == '' then return end

  vim.cmd('Git merge ' .. target)

  vim.defer_fn(function()
    refresh_branch_list(bufnr)
  end, 500)
end

local function open_branch_list()
  local branch_output = get_branch_list()
  if vim.v.shell_error ~= 0 then
    vim.notify("Not a git repository or an error occurred.", vim.log.levels.ERROR)
    return
  end

  if #branch_output == 0 then
    vim.notify("No branches found.", vim.log.levels.INFO)
    return
  end

  local git_dir = vim.fn.FugitiveGitDir()
  if git_dir == "" then
    git_dir = vim.fn.getcwd() -- Fallback if not in git repo, though get_branch_list check above should prevent this
  end
  vim.cmd('botright split fugitive-branch://' .. git_dir)
  local bufnr = vim.api.nvim_get_current_buf()

  -- Set modifiable before setting lines
  vim.api.nvim_set_option_value('modifiable', true, { buf = bufnr })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, branch_output)

  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = bufnr })
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = bufnr })
  vim.api.nvim_set_option_value('swapfile', false, { buf = bufnr })
  vim.wo[vim.api.nvim_get_current_win()].wrap = false
  vim.bo[bufnr].filetype = 'fugitivebranch'
  vim.bo[bufnr].modifiable = false
end

local function show_branch_help()
  help.show('Branch buffer keys', {
    'g?          show this help',
    '<CR>        Gedit branch',
    'coo         checkout branch',
    'R           refresh list',
    'cP          cherry-pick register (+)',
    '<Leader>gp  git push',
    'O           open PR (Octo)',
    'bw          rename branch',
    'cod         duplicate branch',
    'cot         create worktree',
    'X (n/V)     delete branch(es)',
    'f           fetch --all --prune',
    'p           pull current branch',
    'P           pull branch under cursor',
    'D           diff against origin/default (PR view)',
    'm<Space>    merge branch (input)',
    'r<Space>    stash -> fetch -> rebase (input)',
    '<C-Space>   toggle Flog graph',
  })
end

function M.setup(group)
  vim.api.nvim_create_user_command('Gbranch', open_branch_list, {
    bang = false,
    desc = "Open git branch list",
  })

  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'fugitive',
    callback = function(ev)
      vim.keymap.set('n', 'B', function()
        vim.cmd('Gbranch')
      end, { buffer = ev.buf, silent = true, desc = "Open git branch list" })
    end
  })

  -- fugitive://スキームと同様に、fugitive-branch://スキームもファイルとして扱わないように設定する
  -- これによりセッション復元時などのE212エラー（ディレクトリへの書き込み試行）を防ぐ
  vim.api.nvim_create_autocmd({ 'BufReadCmd', 'BufNewFile' }, {
    group = group,
    pattern = 'fugitive-branch://*',
    callback = function(ev)
      local bufnr = ev.buf
      vim.api.nvim_set_option_value('buftype', 'nofile', { buf = bufnr })
      vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = bufnr })
      vim.api.nvim_set_option_value('swapfile', false, { buf = bufnr })
      vim.bo[bufnr].filetype = 'fugitivebranch'
      refresh_branch_list(bufnr)
    end,
  })

  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'fugitivebranch',
    callback = function(ev)
      local bufnr = ev.buf

      vim.keymap.set('n', 'g?', function()
        show_branch_help()
      end, { buffer = bufnr, silent = true, desc = "Help" })

      -- Add checkout keymap
      vim.keymap.set('n', 'coo', function()
        checkout_branch(bufnr)
      end, { buffer = bufnr, silent = true, desc = "Checkout branch" })

      vim.keymap.set('n', '<CR>', function()
        local branch = get_branch_name_from_line()
        if not branch then
          vim.notify("No branch found on this line", vim.log.levels.WARN)
          return
        end
        vim.cmd('Gedit ' .. branch)
      end, { buffer = bufnr, silent = true, desc = "Gedit branch" })

      vim.keymap.set('n', 'R', function()
        refresh_branch_list(bufnr)
      end, { buffer = bufnr, silent = true, desc = "Refresh branch list" })

      -- Add cherrypick keymap
      vim.keymap.set('n', 'cP', function()
        -- flog copy register uses +
        local commands = require('features.commands')
        commands.git_cherry_pick({
          reg = '+',
          on_complete = function()
            refresh_branch_list(bufnr)
          end
        })
      end, { buffer = bufnr, silent = true, desc = "cherrypick branch" })

      -- Add git push keymap
      vim.keymap.set('n', '<Leader>gp', function()
        local commands = require('features.commands')
        commands.git_push({
          on_complete = function()
            refresh_branch_list(bufnr)
          end
        })
      end, { buffer = bufnr, silent = true, desc = "git push" })

      -- Add Octo pr show keymap
      vim.keymap.set('n', 'O', function()
        local branch = get_branch_name_from_line()
        if branch then
          branch = branch:gsub('^origin/', '')
        end
        if branch then
          vim.cmd('OctoPrFromBranch '.. branch)
        end
      end, { buffer = bufnr, silent = true, desc = "Open PR for branch" })

      -- bw: Rename branch
      vim.keymap.set('n', 'bw', function()
        rename_branch(bufnr)
      end, { buffer = bufnr, silent = true, desc = "Rename branch" })

      -- bd: Duplicate branch (prompt for a new name and create local branch from selected one)
      vim.keymap.set('n', 'cod', function()
        duplicate_branch(bufnr)
      end, { buffer = bufnr, silent = true, desc = "Duplicate branch" })

      -- cot: Create worktree from branch
      vim.keymap.set('n', 'cot', function()
        create_worktree()
      end, { buffer = bufnr, silent = true, desc = "Create worktree from branch" })

      -- X: Delete branch(es)
      vim.keymap.set('n', 'X', function()
        local branch = get_branch_name_from_line()
        if branch then
          delete_branches(bufnr, {branch})
        end
      end, { buffer = bufnr, silent = true, desc = "Delete branch" })

      -- f: Fetch
      vim.keymap.set('n', 'f', function()
        fetch_all(bufnr)
      end, { buffer = bufnr, silent = true, desc = "Fetch all" })

      -- p: Pull
      vim.keymap.set('n', 'p', function()
        pull_branch(bufnr)
      end, { buffer = bufnr, silent = true, desc = "Pull branch" })

      -- P: Pull branch under cursor
      vim.keymap.set('n', 'P', function()
        pull_branch_under_cursor(bufnr)
      end, { buffer = bufnr, silent = true, desc = "Pull branch under cursor" })

      -- D: Diff against default branch
      vim.keymap.set('n', 'D', function()
        diff_against_default(bufnr)
      end, { buffer = bufnr, silent = true, desc = "Diff against default branch" })

      -- r<Space>: Stash, Fetch, Rebase
      vim.keymap.set('n', 'r<Space>', function()
        local branch = get_branch_name_from_line()
        if not branch then branch = nil end
        rebase_with_stash_fetch(bufnr, branch)
      end, { buffer = bufnr, silent = true, desc = "Stash, Fetch, Rebase" })

      -- m<Space>: Merge
      vim.keymap.set('n', 'm<Space>', function()
        local branch = get_branch_name_from_line()
        if not branch then branch = nil end
        merge_with_input(bufnr, branch)
      end, { buffer = bufnr, silent = true, desc = "Merge branch" })

      vim.keymap.set('v', 'X', function()
        local start_line = vim.fn.line('v')
        local end_line = vim.fn.line('.')
        if start_line > end_line then
          start_line, end_line = end_line, start_line
        end

        local branches = {}
        for i = start_line, end_line do
          local line = vim.fn.getline(i)
          local branch = get_branch_name_from_line(line)
          if branch then
            table.insert(branches, branch)
          end
        end

        delete_branches(bufnr, branches)
      end, { buffer = bufnr, silent = true, desc = "Delete branches" })

      -- L: Open log for branch under cursor
      vim.keymap.set('n', 'L', function()
        local branch = get_branch_name_from_line()
        if not branch then
          vim.notify("No branch found on this line", vim.log.levels.WARN)
          return
        end
        vim.cmd("FugitiveLog " .. branch)
      end, { buffer = bufnr, silent = true, desc = "Open log for branch" })

      -- <C-Space>: Flog window toggle for current branch
      vim.keymap.set('n', '<C-Space>', function()
        local branch = get_branch_name_from_line()
        if not branch then
          vim.notify("No branch found on this line", vim.log.levels.WARN)
          return
        end

        if vim.g.flog_win and vim.api.nvim_win_is_valid(vim.g.flog_win) then
          vim.api.nvim_win_close(vim.g.flog_win, false)
          vim.g.flog_win = nil
          vim.g.flog_bufnr = nil
          vim.g.flog_branch_bufnr = nil
        else
          local current_win = vim.api.nvim_get_current_win()
          vim.cmd(string.format("Flogsplit -open-cmd=vertical\\ rightbelow\\ 60vsplit -rev=%s", branch))
          vim.g.flog_bufnr = vim.api.nvim_get_current_buf()
          vim.g.flog_win = vim.api.nvim_get_current_win()
          vim.g.flog_branch_bufnr = bufnr

          local utils = require("fugitive_utils")
          utils.setup_flog_window(vim.g.flog_win, vim.g.flog_bufnr)
          vim.api.nvim_set_current_win(current_win)
        end
      end, { buffer = bufnr, nowait = true, silent = true, desc = 'Toggle Flog graph for branch' })

      -- Update Flog on cursor move if Flog window is open
      vim.api.nvim_create_autocmd('CursorMoved', {
        buffer = bufnr,
        callback = function()
          if vim.g.flog_win and vim.api.nvim_win_is_valid(vim.g.flog_win) and vim.g.flog_branch_bufnr == bufnr then
            local branch = get_branch_name_from_line()
            if branch then
              local current_win = vim.api.nvim_get_current_win()

              -- Close old Flog window
              vim.api.nvim_win_close(vim.g.flog_win, false)

              -- Open new Flog with new branch
              vim.cmd(string.format("Flogsplit -open-cmd=vertical\\ rightbelow\\ 60vsplit -rev=%s", branch))
              vim.g.flog_bufnr = vim.api.nvim_get_current_buf()
              vim.g.flog_win = vim.api.nvim_get_current_win()

              local utils = require("fugitive_utils")
              utils.setup_flog_window(vim.g.flog_win, vim.g.flog_bufnr)
              vim.api.nvim_set_current_win(current_win)
            end
          end
        end,
      })

      vim.api.nvim_create_autocmd('BufUnload', {
        buffer = bufnr,
        callback = function(args)
          if vim.g.flog_branch_bufnr and vim.g.flog_branch_bufnr == args.buf then
            if vim.g.flog_win and vim.api.nvim_win_is_valid(vim.g.flog_win) then
              vim.api.nvim_win_close(vim.g.flog_win, true)
              vim.g.flog_win = nil
              vim.g.flog_bufnr = nil
              vim.g.flog_branch_bufnr = nil
            end
          end
        end,
      })

      -- Set buffer options
      vim.opt_local.number = false
      vim.opt_local.relativenumber = false
      vim.opt_local.signcolumn = 'no'

      -- Setup syntax highlighting for branch names
      vim.cmd([[
        syntax clear
        syntax match FugitiveBranchName /^\s*\*\?\s*\zs\S\+/
        syntax match FugitiveBranchCurrent /^\s*\*\s*\zs\S\+/
        highlight default link FugitiveBranchName Directory
        highlight default link FugitiveBranchCurrent String
      ]])

      -- Load fugitive's default mappings
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
          vim.cmd('runtime! ftplugin/git.vim ftplugin/git_*.vim after/ftplugin/git.vim')
        end
      end, 10)

      -- Auto-refresh on specific events (FugitiveChanged)
      vim.api.nvim_create_autocmd('User', {
        pattern = 'FugitiveChanged',
        -- Listen globally, but only update this buffer if it is visible
        callback = function()
          if vim.api.nvim_buf_is_valid(bufnr) and vim.fn.bufwinnr(bufnr) ~= -1 then
             refresh_branch_list(bufnr)
          end
        end,
      })
    end,
  })
end

return M

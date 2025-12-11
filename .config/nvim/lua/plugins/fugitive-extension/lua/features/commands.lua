local M = {}

local float_win = nil
local float_buf = nil

-- Worktree cleanliness helper
local function apply_auto_stash(work_tree)
  -- Check if worktree is dirty
  local status = vim.fn.systemlist("git -C " .. vim.fn.shellescape(work_tree) .. " status --porcelain")
  if vim.v.shell_error ~= 0 then
    vim.notify("git status failed; skipping auto-stash", vim.log.levels.WARN)
    return false
  end
  if #status == 0 then
    return false
  end

  local msg = "fugitive-ext auto-stash"
  vim.fn.system("git -C " .. vim.fn.shellescape(work_tree) .. " stash push -u -k -m " .. vim.fn.shellescape(msg))
  if vim.v.shell_error ~= 0 then
    vim.notify("auto-stash failed; aborting command", vim.log.levels.ERROR)
    return nil
  end
  vim.notify("Auto-stashed dirty worktree", vim.log.levels.INFO)
  return true
end

local function pop_auto_stash(work_tree)
  vim.fn.system("git -C " .. vim.fn.shellescape(work_tree) .. " stash pop --index --quiet")
  if vim.v.shell_error ~= 0 then
    vim.notify("Auto-stash pop failed; please pop manually", vim.log.levels.ERROR)
  else
    vim.notify("Auto-stash popped", vim.log.levels.INFO)
  end
end

function M.close_commit_info_float()
  if float_win and vim.api.nvim_win_is_valid(float_win) then
    vim.api.nvim_win_close(float_win, true)
    float_win = nil
    float_buf = nil
  end
end

function M.show_commit_info_float(commit, toggle, create_if_missing)
  local create = create_if_missing == nil and true or create_if_missing
  -- If no commit provided, do nothing
  if not commit or commit == '' then
    return
  end
  if float_win and vim.api.nvim_win_is_valid(float_win) then
    if toggle then
      M.close_commit_info_float()
      return
    end
  else
    if not create then
      return
    end
    float_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[float_buf].modifiable = false
    vim.bo[float_buf].filetype = 'git'

    local width = math.min(80, vim.o.columns - 4)
    local height = math.min(30, vim.o.lines - 4)
    local col = vim.o.columns - width - 4
    local row = 2

    float_win = vim.api.nvim_open_win(float_buf, false, {
      relative = 'editor',
      width = width,
      height = height,
      col = col,
      row = row,
      style = 'minimal',
      border = 'single',
      title = ' Commit Info ',
      title_pos = 'center',
    })

    vim.api.nvim_set_option_value('wrap', false, { win = float_win })
    vim.api.nvim_set_option_value('cursorline', false, { win = float_win })
  end

  -- Use git show with custom format to get pre-formatted date
  local command = "git show -s --date=format:'%Y-%m-%d %H:%M' --format='tree %T%nparent %P%nauthor %an <%ae> %ad%ncommitter %cn <%ce> %ad%n%n%B' " .. vim.fn.shellescape(commit)
  local commit_info = vim.fn.systemlist(command)

  if vim.v.shell_error == 0 then
    -- Trim trailing empty lines from the output
    while #commit_info > 0 and commit_info[#commit_info] == '' do
      table.remove(commit_info)
    end

    vim.bo[float_buf].modifiable = true
    vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, commit_info)
    vim.bo[float_buf].modifiable = false

    local line_count = #commit_info
    local win_height = math.min(line_count, vim.o.lines - 4)
    vim.api.nvim_win_set_height(float_win, win_height)
  end

  vim.api.nvim_set_option_value('wrap', false, { win = float_win })
  vim.api.nvim_set_option_value('cursorline', false, { win = float_win })
end

function M.setup()
  vim.api.nvim_create_user_command('GeditHeadAtFile', function()
    local filepath = vim.fn.expand('%:.')
    if filepath == '' then
      print('No file in current buffer')
      return
    end

    local handle = io.popen('git ls-files --full-name ' .. vim.fn.shellescape(filepath) .. ' 2>/dev/null')
    if not handle then
      return
    end
    local git_filepath = handle:read('*a'):gsub('\n', '')
    handle:close()

    if git_filepath == '' then
      print('File not tracked by git: ' .. filepath)
      return
    end

    local commit_handle = io.popen('git log --format=%H -n 1 -- ' .. vim.fn.shellescape(git_filepath) .. ' 2>/dev/null')
    if not commit_handle then
      return
    end
    local latest_commit = commit_handle:read('*a'):gsub('\n', '')
    commit_handle:close()

    if latest_commit == '' then
      print('No commits found for: ' .. git_filepath)
      return
    end

    vim.schedule(function()
      local fugitive_path = vim.fn.FugitiveFind(latest_commit)
      local existing_buf = vim.fn.bufnr(fugitive_path)
      local is_listed = existing_buf ~= -1 and vim.fn.getbufvar(existing_buf, '&buflisted') == 1 or false

      if existing_buf ~= -1 and is_listed then
        vim.cmd('tabedit #' .. existing_buf)
      else
        vim.cmd('tabedit')
        local noname_buf = vim.api.nvim_get_current_buf()
        vim.cmd('Gedit ' .. latest_commit)
        if vim.api.nvim_buf_is_valid(noname_buf) and vim.api.nvim_get_current_buf() ~= noname_buf then
          vim.api.nvim_buf_delete(noname_buf, { force = true })
        end
      end

      vim.schedule(function()
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        for i, line in ipairs(lines) do
          if line:match('^diff %-%-git [ab]/' .. vim.pesc(git_filepath) .. ' ') then
            vim.api.nvim_win_set_cursor(0, { i, 0 })
            vim.cmd('normal! zO')
            break
          end
        end
      end)
    end)
  end, {})

  local function git_push(opts)
    opts = opts or {}
    local on_complete = opts.on_complete

    -- fugitiveバッファのgitディレクトリを取得
    local git_dir = vim.fn.FugitiveGitDir()
    if git_dir == '' then
      vim.notify("Not in a git repository", vim.log.levels.ERROR)
      return
    end

    local work_tree_cmd = 'git --git-dir=' .. vim.fn.shellescape(git_dir) .. ' rev-parse --show-toplevel'
    local work_tree = vim.fn.trim(vim.fn.system(work_tree_cmd))

    if vim.v.shell_error ~= 0 then
      vim.notify("Could not determine work tree from git dir: " .. git_dir, vim.log.levels.ERROR)
      return
    end

    vim.notify("Pushing...", vim.log.levels.INFO)
    local output_lines = {}
    vim.fn.jobstart("git -C " .. vim.fn.shellescape(work_tree) .. " push --force-with-lease", {
      on_exit = function(_, exit_code)
        vim.schedule(function()
          local message = table.concat(output_lines, "\n")
          if exit_code == 0 then
            vim.notify("Push successful\n" .. message, vim.log.levels.INFO)
          else
            vim.notify("Push failed\n" .. message, vim.log.levels.ERROR)
          end
          if on_complete then
            on_complete(exit_code)
          end
        end)
        vim.fn['fugitive#ReloadStatus']()
      end,
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
    })
  end

  vim.api.nvim_create_user_command("GitPush", function()
    git_push({})
  end, {})

  local function git_cherry_pick(opts)
    local reg_char = opts.reg or ''
    local on_complete = opts.on_complete
    local reg_name = reg_char == '' and '""' or '"' .. reg_char .. '"'

    local hashes_str = vim.fn.getreg(reg_char)

    if hashes_str == nil or hashes_str == '' then
      vim.notify('Register ' .. reg_name .. ' is empty.', vim.log.levels.WARN)
      return
    end

    -- Sanitize hashes string: replace newlines with spaces and trim whitespace.
    local hashes_list = vim.split(vim.fn.trim(hashes_str), '[\r\n]+')
    -- Reverse the order for correct cherry-pick sequence
    local reversed_hashes = {}
    for i = #hashes_list, 1, -1 do
      table.insert(reversed_hashes, hashes_list[i])
    end
    hashes_str = vim.fn.trim(table.concat(reversed_hashes, ' '))

    if hashes_str == '' then
      vim.notify('Register ' .. reg_name .. ' contains only whitespace.', vim.log.levels.WARN)
      return
    end

    -- fugitiveバッファのgitディレクトリを取得
    local git_dir = vim.fn.FugitiveGitDir()
    if git_dir == '' then
      vim.notify("Not in a git repository", vim.log.levels.ERROR)
      return
    end

    local work_tree_cmd = 'git --git-dir=' .. vim.fn.shellescape(git_dir) .. ' rev-parse --show-toplevel'
    local work_tree = vim.fn.trim(vim.fn.system(work_tree_cmd))

    if vim.v.shell_error ~= 0 then
      vim.notify("Could not determine work tree from git dir: " .. git_dir, vim.log.levels.ERROR)
      return
    end

    vim.notify("Cherry-picking: " .. hashes_str, vim.log.levels.INFO)

    local stashed = apply_auto_stash(work_tree)
    if stashed == nil then return end

    local output_lines = {}
    local cmd = "git -C " .. vim.fn.shellescape(work_tree) .. " cherry-pick " .. hashes_str
    vim.fn.jobstart(cmd, {
      on_exit = function(_, exit_code)
        vim.schedule(function()
          if stashed then pop_auto_stash(work_tree) end
          local message = table.concat(output_lines, "\n")
          if exit_code == 0 then
            vim.notify("Cherry-pick successful\n" .. message, vim.log.levels.INFO)
          else
            vim.notify("Cherry-pick failed\n" .. message, vim.log.levels.ERROR)
          end
          if on_complete then
            on_complete(exit_code)
          end
        end)
        vim.fn['fugitive#ReloadStatus']()
      end,
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
    })
  end

  vim.api.nvim_create_user_command("GCherryPick", function(cmd_opts)
    git_cherry_pick({ reg = cmd_opts.reg })
  end, { register = true })

  function M.fixup_commit(commit_hash, on_complete)
    if not commit_hash or commit_hash == '' then
      vim.notify('No commit hash provided', vim.log.levels.ERROR)
      return
    end

    local git_dir = vim.fn.FugitiveGitDir()
    if git_dir == '' then
      vim.notify('Not in a git repository', vim.log.levels.ERROR)
      return
    end

    local work_tree_cmd = 'git --git-dir=' .. vim.fn.shellescape(git_dir) .. ' rev-parse --show-toplevel'
    local work_tree = vim.fn.trim(vim.fn.system(work_tree_cmd))

    if vim.v.shell_error ~= 0 then
      vim.notify("Could not determine work tree from git dir: " .. git_dir, vim.log.levels.ERROR)
      return
    end

    local stashed = apply_auto_stash(work_tree)
    if stashed == nil then return end

    -- Get the parent commit hash
    local parent_commit_hash_cmd = 'git -C ' .. vim.fn.shellescape(work_tree) .. ' rev-parse ' .. commit_hash .. '^'
    local parent_commit_hash = vim.fn.trim(vim.fn.system(parent_commit_hash_cmd))
    if vim.v.shell_error ~= 0 then
      if stashed then pop_auto_stash(work_tree) end
      vim.notify('Failed to get parent commit for ' .. commit_hash, vim.log.levels.ERROR)
      return
    end

    -- Create a temporary script file
    local tmpfile = vim.fn.tempname()
    local short_commit_hash = commit_hash:sub(1, 7)
    local script_content = string.format('#!/bin/sh\nsed -i \'s/^pick %s/fixup %s/\' "$1"\n', short_commit_hash, short_commit_hash)

    local f = io.open(tmpfile, 'w')
    if not f then
      vim.notify('Failed to create temp script', vim.log.levels.ERROR)
      return
    end

    f:write(script_content)
    f:close()
    vim.fn.system('chmod +x ' .. vim.fn.shellescape(tmpfile))

    -- Run rebase with GIT_SEQUENCE_EDITOR
    local rebase_cmd = 'GIT_SEQUENCE_EDITOR=' .. vim.fn.shellescape(tmpfile) .. ' git -C ' .. vim.fn.shellescape(work_tree) .. ' rebase -i ' .. vim.fn.shellescape(parent_commit_hash .. '^')
    local result = vim.fn.system(rebase_cmd)
    vim.fn.delete(tmpfile)

    if stashed then pop_auto_stash(work_tree) end

    if vim.v.shell_error ~= 0 then
      vim.notify('Rebase failed: ' .. result, vim.log.levels.ERROR)
    else
      vim.notify('Fixup completed: ' .. short_commit_hash .. ' -> ' .. parent_commit_hash:sub(1, 7))
      -- Reload status if the fugitive buffer is open
      vim.fn['fugitive#ReloadStatus']()
      if on_complete then
        vim.schedule(on_complete)
      end
    end
  end

  function M.reload_log()
    local cursor_pos = vim.api.nvim_win_get_cursor(0)
    if vim.fn.exists('*fugitive#Reload') == 1 then
      vim.fn['fugitive#Reload']()
    else
      vim.cmd('edit')
    end
    pcall(vim.api.nvim_win_set_cursor, 0, cursor_pos)
  end

  function M.move_commit(current_commit, target_commit, direction, on_complete)
    if not current_commit or current_commit == '' or not target_commit or target_commit == '' then
      vim.notify('Invalid commits', vim.log.levels.WARN)
      return
    end

    local current_branch = vim.fn.system('git rev-parse --abbrev-ref HEAD'):gsub('\n', '')
    if current_branch == 'HEAD' then
      vim.notify('Cannot move commits in detached HEAD state', vim.log.levels.ERROR)
      return
    end

    -- Determine the base commit for rebase (parent of the older commit)
    local base_commit
    local is_ancestor = vim.fn.system(string.format('git merge-base --is-ancestor %s %s', current_commit, target_commit))
    if vim.v.shell_error == 0 then
      base_commit = current_commit .. '^'
    else
      base_commit = target_commit .. '^'
    end

    local git_dir = vim.fn.FugitiveGitDir()
    if git_dir == '' then
      vim.notify('Not in a git repository', vim.log.levels.ERROR)
      return
    end

    local work_tree_cmd = 'git --git-dir=' .. vim.fn.shellescape(git_dir) .. ' rev-parse --show-toplevel'
    local work_tree = vim.fn.trim(vim.fn.system(work_tree_cmd))

    local stashed = apply_auto_stash(work_tree)
    if stashed == nil then return end

    -- Create awk script - simplest approach
    local tmpfile = vim.fn.tempname()
    local script = string.format([[
#!/bin/bash
awk '
/^pick %s/ { line1=NR; save1=$0; next }
/^pick %s/ { line2=NR; save2=$0; next }
{ lines[NR]=$0 }
END {
  for (i=1; i<=NR+2; i++) {
    if (i==line1) print save2
    else if (i==line2) print save1
    else if (lines[i]) print lines[i]
  }
}
' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
]], current_commit:sub(1,7), target_commit:sub(1,7))

    local debug_script = string.format([[
#!/bin/bash
echo "[DEBUG] Original todo:" > /tmp/rebase-debug.log
cat "$1" >> /tmp/rebase-debug.log
%s
echo "[DEBUG] Modified todo:" >> /tmp/rebase-debug.log
cat "$1" >> /tmp/rebase-debug.log
]], script)

    local f = io.open(tmpfile, 'w')
    f:write(debug_script)
    f:close()
    vim.fn.system('chmod +x ' .. vim.fn.shellescape(tmpfile))

    local cmd = string.format('GIT_SEQUENCE_EDITOR=%s git rebase -i %s', vim.fn.shellescape(tmpfile), base_commit)
    local output = vim.fn.system(cmd)
    vim.fn.delete(tmpfile)

    if stashed then pop_auto_stash(work_tree) end

    if vim.v.shell_error ~= 0 then
      vim.notify('Failed to swap commits:\n' .. output, vim.log.levels.ERROR)
    else
      vim.notify('Successfully swapped commits', vim.log.levels.INFO)
      if on_complete then
        vim.schedule(on_complete)
      else
        M.reload_log()
      end
    end
  end

  function M.drop_commits(commits)
    if not commits or #commits == 0 then return end

    local git_dir = vim.fn.FugitiveGitDir()
    if git_dir == '' then
      vim.notify('Not in a git repository', vim.log.levels.ERROR)
      return
    end

    local work_tree_cmd = 'git --git-dir=' .. vim.fn.shellescape(git_dir) .. ' rev-parse --show-toplevel'
    local work_tree = vim.fn.trim(vim.fn.system(work_tree_cmd))

    local stashed = apply_auto_stash(work_tree)
    if stashed == nil then return end

    -- Sort commits to find the oldest one (last in chronological order)
    local commits_args = table.concat(commits, " ")
    local sort_cmd = 'git -C ' .. vim.fn.shellescape(work_tree) .. ' rev-list --no-walk --date-order ' .. commits_args
    local sorted_commits = vim.fn.systemlist(sort_cmd)

    if vim.v.shell_error ~= 0 or #sorted_commits == 0 then
        if stashed then pop_auto_stash(work_tree) end
        vim.notify('Failed to process commits', vim.log.levels.ERROR)
        return
    end

    -- The last one in rev-list output (date-order) is the oldest
    local oldest_commit = sorted_commits[#sorted_commits]

    -- Construct sed command to delete lines
    local sed_expr = ""
    for _, commit in ipairs(commits) do
        local short = commit:sub(1, 7)
        sed_expr = sed_expr .. " -e '/^pick " .. short .. "/d'"
    end

    local tmpfile = vim.fn.tempname()
    local f = io.open(tmpfile, 'w')
    f:write('#!/bin/sh\n')
    f:write('sed -i' .. sed_expr .. ' "$1"\n')
    f:close()
    vim.fn.system('chmod +x ' .. vim.fn.shellescape(tmpfile))

    local rebase_cmd = 'GIT_SEQUENCE_EDITOR=' .. vim.fn.shellescape(tmpfile) .. ' git -C ' .. vim.fn.shellescape(work_tree) .. ' rebase -i ' .. vim.fn.shellescape(oldest_commit .. '^')
    local result = vim.fn.system(rebase_cmd)
    vim.fn.delete(tmpfile)

    if stashed then pop_auto_stash(work_tree) end

    if vim.v.shell_error ~= 0 then
      vim.notify('Drop failed: ' .. result, vim.log.levels.ERROR)
    else
      vim.notify('Dropped ' .. #commits .. ' commit(s)')
      M.reload_log()
    end
  end

  -- Export functions for use in other modules
  M.git_push = git_push
  M.git_cherry_pick = git_cherry_pick
end

return M

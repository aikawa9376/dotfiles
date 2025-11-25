local M = {}

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

    local output_lines = {}
    local cmd = "git -C " .. vim.fn.shellescape(work_tree) .. " cherry-pick " .. hashes_str
    vim.fn.jobstart(cmd, {
      on_exit = function(_, exit_code)
        vim.schedule(function()
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

  function M.fixup_commit(commit_hash)
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

    -- Get the parent commit hash
    local parent_commit_hash_cmd = 'git -C ' .. vim.fn.shellescape(work_tree) .. ' rev-parse ' .. commit_hash .. '^'
    local parent_commit_hash = vim.fn.trim(vim.fn.system(parent_commit_hash_cmd))
    if vim.v.shell_error ~= 0 then
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

    if vim.v.shell_error ~= 0 then
      vim.notify('Rebase failed: ' .. result, vim.log.levels.ERROR)
    else
      vim.notify('Fixup completed: ' .. short_commit_hash .. ' -> ' .. parent_commit_hash:sub(1, 7))
      -- Reload status if the fugitive buffer is open
      vim.fn['fugitive#ReloadStatus']()
    end
  end

  -- Export functions for use in other modules
  M.git_push = git_push
  M.git_cherry_pick = git_cherry_pick
end

return M

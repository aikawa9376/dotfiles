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

  local function git_push()
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

  vim.api.nvim_create_user_command("GitPush", git_push, {})
end

return M

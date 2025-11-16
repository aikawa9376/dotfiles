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
end

return M

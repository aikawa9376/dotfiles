local M = {}

---@param path string|nil
---@return string|nil
function M.normalize_path(path)
  if not path or path == "" then
    return nil
  end
  return vim.fn.fnamemodify(path, ':p'):gsub('/+$', '')
end

---@param bufnr integer|nil
---@return boolean
function M.is_valid_buf(bufnr)
  return bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr)
end

---@param win integer|nil
---@return boolean
function M.is_valid_win(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

---@param opts? {bufnr?: integer, git_dir?: string, notify?: boolean, not_git_message?: string, error_message?: string}
---@return string|nil
function M.get_work_tree(opts)
  opts = opts or {}
  local git_dir = opts.git_dir
  if not git_dir then
    git_dir = opts.bufnr and vim.fn.FugitiveGitDir(opts.bufnr) or vim.fn.FugitiveGitDir()
  end

  if not git_dir or git_dir == '' then
    if opts.notify then
      vim.notify(opts.not_git_message or "Not in a git repository", vim.log.levels.ERROR)
    end
    return nil
  end

  local work_tree = vim.fn.trim(
    vim.fn.system('git --git-dir=' .. vim.fn.shellescape(git_dir) .. ' rev-parse --show-toplevel')
  )
  if vim.v.shell_error ~= 0 or work_tree == '' then
    if opts.notify then
      vim.notify(opts.error_message or ("Could not determine work tree from git dir: " .. git_dir), vim.log.levels.ERROR)
    end
    return nil
  end

  return M.normalize_path(work_tree)
end

---@param work_tree string|nil
---@return string[]
function M.get_stash_list(work_tree)
  local cmd = 'git stash list'
  if work_tree and work_tree ~= '' then
    cmd = 'git -C ' .. vim.fn.shellescape(work_tree) .. ' stash list'
  end
  local stash_output = vim.fn.systemlist(cmd)
  return vim.v.shell_error == 0 and stash_output or {}
end

---@param work_tree string
---@param opts? {message?: string, keep_index?: boolean, notify_stashed?: boolean}
---@return boolean|nil
function M.auto_stash(work_tree, opts)
  opts = opts or {}
  if not work_tree or work_tree == '' then
    vim.notify("Not in a git repository", vim.log.levels.ERROR)
    return nil
  end

  local status = vim.fn.systemlist("git -C " .. vim.fn.shellescape(work_tree) .. " status --porcelain")
  if vim.v.shell_error ~= 0 then
    vim.notify("git status failed; skipping auto-stash", vim.log.levels.WARN)
    return false
  end
  if #status == 0 then
    return false
  end

  local msg = opts.message or "fugitive-ext auto-stash"
  local keep_index = opts.keep_index and " -k" or ""
  vim.fn.system(
    "git -C "
      .. vim.fn.shellescape(work_tree)
      .. " stash push -u"
      .. keep_index
      .. " -m "
      .. vim.fn.shellescape(msg)
  )
  if vim.v.shell_error ~= 0 then
    vim.notify("auto-stash failed; aborting", vim.log.levels.ERROR)
    return nil
  end

  if opts.notify_stashed then
    vim.notify("Auto-stashed dirty worktree", vim.log.levels.INFO)
  end
  return true
end

---@param work_tree string
---@param opts? {notify_popped?: boolean, reload_status?: boolean}
---@return boolean
function M.pop_auto_stash(work_tree, opts)
  opts = opts or {}
  vim.fn.system("git -C " .. vim.fn.shellescape(work_tree) .. " stash pop --index --quiet")
  if vim.v.shell_error ~= 0 then
    vim.notify("Auto-stash pop failed; please pop manually", vim.log.levels.ERROR)
    return false
  end

  if opts.notify_popped then
    vim.notify("Auto-stash popped", vim.log.levels.INFO)
  end
  if opts.reload_status then
    pcall(vim.fn['fugitive#ReloadStatus'])
  end
  return true
end

---Temporarily make a buffer modifiable while `fn` runs, restoring previous flags.
---@param bufnr integer
---@param fn fun()
---@param retries? integer
---@return boolean
function M.with_buf_modifiable(bufnr, fn, retries)
  retries = retries or 0
  if not M.is_valid_buf(bufnr) then
    return false
  end

  local prev_modifiable = vim.api.nvim_get_option_value('modifiable', { buf = bufnr })
  local prev_readonly = vim.api.nvim_get_option_value('readonly', { buf = bufnr })

  local function attempt(remaining)
    if not M.is_valid_buf(bufnr) then
      return false
    end

    pcall(vim.api.nvim_set_option_value, 'modifiable', true, { buf = bufnr })
    pcall(vim.api.nvim_set_option_value, 'readonly', false, { buf = bufnr })

    local ok, err = pcall(fn)

    pcall(vim.api.nvim_set_option_value, 'modifiable', prev_modifiable, { buf = bufnr })
    pcall(vim.api.nvim_set_option_value, 'readonly', prev_readonly, { buf = bufnr })

    if ok then
      return true
    end
    if remaining > 0 then
      vim.defer_fn(function()
        attempt(remaining - 1)
      end, 50)
      return false
    else
      vim.schedule(function()
        vim.notify('Failed to update buffer: ' .. tostring(err), vim.log.levels.WARN)
      end)
      return false
    end
  end

  return attempt(retries)
end

---@return string|nil
function M.get_filepath_at_cursor(bufnr)
  local current_line = vim.api.nvim_win_get_cursor(0)[1]
  for lnum = current_line, 1, -1 do
    local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
    if line then
      -- For fugitive status buffer
      local status_match = line:match('^[MADRCU?!][MADRCU?!]? (.+)$')
      if status_match then
        -- Handle rename "R old -> new"
        local old, new = status_match:match('^(.+) %-> (.+)$')
        if new then
          return new
        end
        return status_match
      end
      -- For git commit buffer
      local commit_match = line:match('^diff %-%-git [ab]/(.+) [ab]/')
      if commit_match then
        return commit_match
      end
      -- For rename in diff output
      local rename_to = line:match('^rename to (.+)$')
      if rename_to then
        return rename_to
      end
    end
  end
end

---@return string|nil
function M.get_commit(bufnr)
  if not M.is_valid_buf(bufnr) then
    return nil
  end
  local result = vim.fn.FugitiveParse(vim.api.nvim_buf_get_name(bufnr))
  return result and result[1] or nil
end

---@param win integer window id
---@param bufnr integer buffer number
function M.setup_flog_window(win, bufnr)
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].cursorline = false
  vim.wo[win].winhighlight = 'NormalNC:Normal'

  -- qでFlogウィンドウを閉じる
  vim.keymap.set('n', 'q', function()
    if M.is_valid_win(vim.g.flog_win) then
      vim.api.nvim_win_close(vim.g.flog_win, true) -- Flogウィンドウを閉じる
      vim.g.flog_win = nil -- グローバル変数をクリア
      vim.g.flog_bufnr = nil -- グローバル変数をクリア
    end
  end, { buffer = bufnr, nowait = true, silent = true })
end

---@param flog_bufnr integer
---@param flog_win integer
---@param commit_sha string
function M.highlight_flog_commit(flog_bufnr, flog_win, commit_sha)
  if not (M.is_valid_win(flog_win) and M.is_valid_buf(flog_bufnr)) then
    return
  end
  if not commit_sha or commit_sha == "" then
    return
  end

  local ns_id = vim.api.nvim_create_namespace('FlogHighlight')
  vim.api.nvim_buf_clear_namespace(flog_bufnr, ns_id, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(flog_bufnr, 0, -1, false)
  for idx, line in ipairs(lines) do
    if line:match(commit_sha:sub(1, 7)) then
      vim.api.nvim_buf_set_extmark(flog_bufnr, ns_id, idx - 1, 0, {
        end_col = #line,
        hl_group = 'Search',
        hl_mode = 'combine',
      })
      vim.api.nvim_win_call(flog_win, function()
        vim.api.nvim_win_set_cursor(flog_win, { idx, 0 })
        vim.cmd('normal! zt5k')
      end)
      break
    end
  end
end


local devicons_ok, devicons = pcall(require, 'nvim-web-devicons')

---@param filename string
---@return string, string
function M.get_devicon(filename)
  if not devicons_ok then
    return " ", "Normal"
  end
  local file_icon, hl = devicons.get_icon(filename, vim.fn.fnamemodify(filename, ":e"), { default = true })
  if file_icon then
    return file_icon, hl or "Normal"
  end
  return " ", "Normal"
end

return M

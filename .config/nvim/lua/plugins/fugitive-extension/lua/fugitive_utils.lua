local M = {}

---@param path string|nil
---@return string|nil
function M.normalize_path(path)
  if not path or path == "" then
    return nil
  end
  return (vim.fn.fnamemodify(path, ':p'):gsub('/+$', ''))
end

---@param work_tree string|nil
---@param path string|nil
---@return string|nil
function M.worktree_relative_abs_path(work_tree, path)
  work_tree = M.normalize_path(work_tree)
  if not work_tree or not path or path == '' then
    return nil
  end

  local abs = vim.fn.fnamemodify(work_tree .. '/' .. path, ':p'):gsub('/+$', '')
  if abs == work_tree or abs:sub(1, #work_tree + 1) ~= work_tree .. '/' then
    return nil
  end
  return abs
end

---@param path string|nil
---@return boolean
local function is_absolute_path(path)
  return type(path) == 'string' and (path:sub(1, 1) == '/' or path:match('^%a:[/\\]') ~= nil)
end

---@param base string
---@param path string
---@return string|nil
local function resolve_path(base, path)
  if is_absolute_path(path) then
    return M.normalize_path(path)
  end
  return M.normalize_path(base .. '/' .. path)
end

---@param git_dir string|nil
---@return boolean
local function looks_like_git_dir(git_dir)
  return type(git_dir) == 'string'
    and vim.fn.filereadable(git_dir .. '/HEAD') == 1
    and (
      vim.fn.filereadable(git_dir .. '/config') == 1
      or vim.fn.filereadable(git_dir .. '/commondir') == 1
    )
end

---@param git_dir string
---@return string|nil
local function work_tree_from_gitdir_file(git_dir)
  local gitdir_file = git_dir .. '/gitdir'
  if vim.fn.filereadable(gitdir_file) ~= 1 then
    return nil
  end

  local lines = vim.fn.readfile(gitdir_file, '', 1)
  local git_file = lines and lines[1] or nil
  if not git_file or git_file == '' then
    return nil
  end

  if not is_absolute_path(git_file) then
    git_file = git_dir .. '/' .. git_file
  end
  return M.normalize_path(vim.fn.fnamemodify(git_file, ':h'))
end

---@param git_dir string|nil
---@return string|nil
local function get_work_tree_from_git_dir(git_dir)
  git_dir = M.normalize_path(git_dir)
  if not git_dir then
    return nil
  end

  if vim.fn.fnamemodify(git_dir, ':t') == '.git' then
    local parent_git_dir = M.normalize_path(vim.fn.fnamemodify(git_dir, ':h'))
    if looks_like_git_dir(parent_git_dir) then
      local work_tree = get_work_tree_from_git_dir(parent_git_dir)
      if work_tree then
        return work_tree
      end
    end
    return parent_git_dir
  end

  local configured_work_tree = vim.fn.trim(
    vim.fn.system('git --git-dir=' .. vim.fn.shellescape(git_dir) .. ' config --path --get core.worktree')
  )
  if vim.v.shell_error == 0 and configured_work_tree ~= '' then
    return resolve_path(git_dir, configured_work_tree)
  end

  return work_tree_from_gitdir_file(git_dir)
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

---@param bufnr integer|nil
---@return boolean
function M.is_buf_visible(bufnr)
  if not M.is_valid_buf(bufnr) then
    return false
  end
  ---@cast bufnr integer
  return #vim.fn.win_findbuf(bufnr) > 0
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

  local work_tree = get_work_tree_from_git_dir(git_dir)
  local shell_error = 0
  if not work_tree then
    work_tree = vim.fn.trim(
      vim.fn.system('git --git-dir=' .. vim.fn.shellescape(git_dir) .. ' rev-parse --show-toplevel')
    )
    shell_error = vim.v.shell_error
  end
  if shell_error ~= 0 or not work_tree or work_tree == '' then
    if opts.notify then
      vim.notify(
        opts.error_message or ("Could not determine work tree from git dir: " .. git_dir),
        vim.log.levels.ERROR
      )
    end
    return nil
  end

  return M.normalize_path(work_tree)
end

---@param bufnr integer
---@param work_tree string|nil
---@return string|nil
function M.set_buf_work_tree(bufnr, work_tree)
  if not M.is_valid_buf(bufnr) then
    return nil
  end

  local normalized = M.normalize_path(work_tree)
  if normalized then
    vim.b[bufnr].fugitive_work_tree = normalized
  end
  return normalized
end

---@param bufnr integer
---@param opts? {work_tree?: string}
---@return string|nil
function M.get_buf_work_tree(bufnr, opts)
  if not M.is_valid_buf(bufnr) then
    return nil
  end

  local work_tree = M.normalize_path(vim.b[bufnr].fugitive_work_tree)
  if work_tree then
    return work_tree
  end

  work_tree = opts and opts.work_tree or M.get_work_tree({ bufnr = bufnr })
  return M.set_buf_work_tree(bufnr, work_tree)
end

---@param opts? {bufnr?: integer, work_tree?: string, git_dir?: string, reason?: string}
function M.fire_fugitive_changed(opts)
  opts = opts or {}

  local work_tree = opts.work_tree
  if not work_tree and opts.bufnr then
    work_tree = M.get_buf_work_tree(opts.bufnr)
  end
  if not work_tree and opts.git_dir then
    work_tree = M.get_work_tree({ git_dir = opts.git_dir })
  end
  if not work_tree then
    work_tree = M.get_work_tree()
  end

  work_tree = M.normalize_path(work_tree)
  vim.schedule(function()
    vim.api.nvim_exec_autocmds('User', {
      pattern = 'FugitiveChanged',
      data = {
        work_tree = work_tree,
        reason = opts.reason,
      },
    })
  end)
end

---@param group integer
---@param bufnr integer
---@param refresh fun(bufnr: integer, ev?: table)
---@param opts? {work_tree?: string, refresh_on_enter?: boolean, visible_only?: boolean}
function M.setup_repo_refresh(group, bufnr, refresh, opts)
  opts = opts or {}
  local initial_work_tree = opts.work_tree or M.get_buf_work_tree(bufnr)
  M.set_buf_work_tree(bufnr, initial_work_tree)

  local function matches_repo(ev)
    if not M.is_valid_buf(bufnr) then
      return false
    end

    if opts.visible_only and not M.is_buf_visible(bufnr) then
      return false
    end

    local changed_work_tree = ev and ev.data and ev.data.work_tree or nil
    if not changed_work_tree then
      return true
    end

    local buffer_work_tree = M.get_buf_work_tree(bufnr)
    return not buffer_work_tree or M.normalize_path(changed_work_tree) == buffer_work_tree
  end

  local function maybe_refresh(ev)
    if matches_repo(ev) then
      refresh(bufnr, ev)
    end
  end

  if opts.refresh_on_enter ~= false then
    vim.api.nvim_create_autocmd('BufEnter', {
      group = group,
      buffer = bufnr,
      callback = function()
        maybe_refresh()
      end,
    })
  end

  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'FugitiveChanged',
    callback = maybe_refresh,
  })
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
        local renamed_to = status_match:match('^.+ %-> (.+)$')
        if renamed_to then
          return renamed_to
        end
        return status_match
      end
      -- For git commit buffer
      local old_path, new_path = line:match('^diff %-%-git a/(.+) b/(.+)$')
      if old_path then
        return new_path or old_path
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

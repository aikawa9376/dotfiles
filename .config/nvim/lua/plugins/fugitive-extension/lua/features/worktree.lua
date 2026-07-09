local M = {}
local help = require("features.help")
local utils = require("fugitive_utils")

-- 内部キャッシュ（最軽量化のため）
local _cache = {
  entries = nil,
  entries_root = nil,
  entries_mtime = 0,
  detected_root = nil,
  detected_key = nil,
  detected_mtime = 0,
}
local CACHE_TTL = 5 -- 秒

local function current_buffer_work_tree()
  local ok, bufnr = pcall(vim.api.nvim_get_current_buf)
  if not ok or not utils.is_valid_buf(bufnr) then return nil end
  return utils.normalize_path(vim.b[bufnr].fugitive_work_tree)
end

local function current_git_context_key()
  local ok, git_dir = pcall(vim.fn.FugitiveGitDir)
  if ok and git_dir and git_dir ~= '' then
    return 'git:' .. (utils.normalize_path(git_dir) or git_dir)
  end

  local ok_cwd, cwd = pcall(vim.fn.getcwd)
  return 'cwd:' .. (ok_cwd and (utils.normalize_path(cwd) or cwd) or '')
end

-- ワークツリーのルート取得（キャッシュ付き）
local function get_work_tree(work_tree)
  if work_tree and work_tree ~= '' then
    return utils.normalize_path(work_tree)
  end

  local buffer_root = current_buffer_work_tree()
  if buffer_root then
    return buffer_root
  end

  local now = os.time()
  local context_key = current_git_context_key()
  if _cache.detected_root
      and _cache.detected_key == context_key
      and (now - _cache.detected_mtime) < CACHE_TTL then
    return _cache.detected_root
  end

  local detected_root = utils.get_work_tree()
  if not detected_root then return nil end

  _cache.detected_root = detected_root
  _cache.detected_key = context_key
  _cache.detected_mtime = now
  return _cache.detected_root
end

local function path_is_git_dir(path)
  return path
    and vim.fn.filereadable(path .. '/HEAD') == 1
    and (
      vim.fn.filereadable(path .. '/config') == 1
      or vim.fn.filereadable(path .. '/commondir') == 1
      or vim.fn.filereadable(path .. '/gitdir') == 1
    )
end

local function normalize_worktree_entry(entry)
  if not entry or not entry.path then return entry end

  entry.path = utils.normalize_path(entry.path)
  if not path_is_git_dir(entry.path) then
    return entry
  end

  -- Submodule primaries can be reported as .git/modules/...; show the real worktree.
  local actual_work_tree = utils.get_work_tree({ git_dir = entry.path })
  if actual_work_tree then
    entry.git_dir_path = entry.path
    entry.path = actual_work_tree
  end
  return entry
end

-- ワークツリー一覧の取得（キャッシュ付き）
local function get_worktrees(force, work_tree)
  local root = get_work_tree(work_tree)
  if not root then return {} end
  local now = os.time()
  if not force
      and _cache.entries
      and _cache.entries_root == root
      and (now - _cache.entries_mtime) < CACHE_TTL then
    return _cache.entries
  end

  local ok, entries = pcall(function()
    local output = vim.fn.systemlist('git -C ' .. vim.fn.shellescape(root) .. ' worktree list --porcelain')
    if vim.v.shell_error ~= 0 then return {} end

    local res, current = {}, nil
    for _, line in ipairs(output) do
      if line:match('^worktree ') then
        if current then table.insert(res, normalize_worktree_entry(current)) end
        current = { path = line:sub(10) }
      elseif current then
        local key, val = line:match('^(%S+)%s+(.*)$')
        if key == 'HEAD' then current.head = val
        elseif key == 'branch' then current.branch = val:gsub('^refs/heads/', '') end
      end
    end
    if current then table.insert(res, normalize_worktree_entry(current)) end
    return res
  end)

  if ok then
    _cache.entries_root = root
    _cache.entries = entries
    _cache.entries_mtime = now
    return entries
  end
  return {}
end

function M.clear_cache()
  _cache.entries = nil
  _cache.entries_root = nil
  _cache.entries_mtime = 0
  _cache.detected_root = nil
  _cache.detected_key = nil
  _cache.detected_mtime = 0
end

-- 表示形式の統一: [marker][path]  [branch]  [head] [sync_icon]
local function format_line(wt, current_root, main_head, is_main)
  local is_current = (wt.path == current_root)
  -- 仕様変更: 同期されている（親と同じハッシュ）場合にアイコンを表示
  local is_synced = (not is_main and main_head and wt.head == main_head)

  local marker = is_current and '* ' or '  '
  local path = vim.fn.fnamemodify(wt.path, ':~')
  local branch = wt.branch or '(detached)'
  local head = (wt.head or ''):sub(1, 7)
  local sync_icon = is_synced and ' 󰚰' or ''

  return string.format('%s%s  %s  %s%s', marker, path, branch, head, sync_icon)
end

local function apply_highlights(bufnr)
  if not utils.is_valid_buf(bufnr) then return end
  local entries = vim.b[bufnr].worktree_entries
  if not entries then return end

  local ns = vim.api.nvim_create_namespace('fugitiveworktree_highlight')
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local current_root = utils.get_buf_work_tree(bufnr) or get_work_tree()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  for idx, line in ipairs(lines) do
    local entry = entries[idx]
    if entry then
      local path = vim.fn.fnamemodify(entry.path, ':~')
      local branch = entry.branch or '(detached)'
      local head = (entry.head or ''):sub(1, 7)

      -- 1. パス
      local s_path, e_path = line:find(path, 1, true)
      if s_path then
        local hl = (entry.path == current_root) and 'DiagnosticOk' or 'Directory'
        vim.api.nvim_buf_set_extmark(bufnr, ns, idx - 1, s_path - 1, { end_col = e_path, hl_group = hl })
      end

      -- 2. ブランチ
      local s_branch, e_branch = line:find(branch, (e_path or 1), true)
      if s_branch then
        vim.api.nvim_buf_set_extmark(bufnr, ns, idx - 1, s_branch - 1, { end_col = e_branch, hl_group = 'Type' })
      end

      -- 3. ハッシュ
      local s_head, e_head = line:find(head, (e_branch or 1), true)
      if s_head then
        vim.api.nvim_buf_set_extmark(bufnr, ns, idx - 1, s_head - 1, { end_col = e_head, hl_group = 'Comment' })
      end

      -- 4. 同期アイコン (一番右) - 同期済みなので緑系でハイライト
      local icon_str = '󰚰'
      local icon_pos, icon_end = line:find(icon_str, (e_head or 1), true)
      if icon_pos then
        vim.api.nvim_buf_set_extmark(bufnr, ns, idx - 1, icon_pos - 1, { end_col = icon_end, hl_group = 'DiagnosticOk' })
      end
    end
  end
end

local function refresh_all_worktree_buffers()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if utils.is_valid_buf(bufnr) and vim.bo[bufnr].filetype == 'fugitiveworktree' then
      M.refresh_worktree_list(bufnr)
    end
  end
end

function M.refresh_worktree_list(bufnr)
  local current_root = utils.get_buf_work_tree(bufnr) or get_work_tree()
  local entries = get_worktrees(true, current_root)
  if type(entries) ~= 'table' then
    entries = {}
  end
  local primary = entries[1]
  local main_head = primary and primary.head or nil

  local lines = {}
  for i, wt in ipairs(entries) do
    table.insert(lines, format_line(wt, current_root, main_head, i == 1))
  end

  utils.with_buf_modifiable(bufnr, function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  end)
  vim.bo[bufnr].modifiable = false
  vim.b[bufnr].worktree_entries = entries
  apply_highlights(bufnr)
end

local function open_worktree_list()
  local current_root = get_work_tree()
  local entries = get_worktrees(true, current_root)
  if #entries == 0 then return end

  vim.cmd('botright split fugitive-worktree://')
  local bufnr = vim.api.nvim_get_current_buf()
  utils.set_buf_work_tree(bufnr, current_root)

  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = bufnr })
  vim.api.nvim_set_option_value('buflisted', false, { buf = bufnr })
  vim.api.nvim_set_option_value('bufhidden', 'hide', { buf = bufnr })
  vim.api.nvim_set_option_value('swapfile', false, { buf = bufnr })
  vim.bo[bufnr].filetype = 'fugitiveworktree'

  M.refresh_worktree_list(bufnr)
end

local function entry_at_cursor(bufnr)
  local entries = vim.b[bufnr].worktree_entries
  local idx = vim.fn.line('.')
  return entries and entries[idx] or nil
end

local function perform_sync(primary_path, target_head)
  if not primary_path or not target_head then return end

  if vim.fn.system('git -C ' .. vim.fn.shellescape(primary_path) .. ' status --porcelain') ~= '' then
    vim.fn.system('git -C ' .. vim.fn.shellescape(primary_path) .. ' stash push -u -m "Auto-stash before sync"')
    vim.notify("Primary worktree: changes stashed.", vim.log.levels.INFO)
  end

  vim.fn.system('git -C ' .. vim.fn.shellescape(primary_path) .. ' checkout --detach ' .. vim.fn.shellescape(target_head))
  vim.notify("Primary synced to: " .. target_head:sub(1,7))

  M.clear_cache()
  refresh_all_worktree_buffers()
  utils.fire_fugitive_changed({ work_tree = primary_path })
end

function M.sync_current_worktree_to_primary()
  local current_root = get_work_tree()
  local entries = get_worktrees(false, current_root)
  if type(entries) ~= 'table' then
    entries = {}
  end
  if #entries < 2 then return end
  local primary = entries[1]
  if not primary then
    return
  end
  local current = nil
  for _, wt in ipairs(entries) do
    if wt.path == current_root then current = wt; break end
  end

  if current and current.path ~= primary.path then
    perform_sync(primary.path, current.head)
  end
end

-- Lualine 用の最軽量ステータス
function M.lualine_sync_status()
  local current_root = get_work_tree()
  if not current_root then return '' end

  local now = os.time()
  if not (_cache.entries
      and _cache.entries_root == current_root
      and (now - _cache.entries_mtime) < CACHE_TTL) then
    get_worktrees(false, current_root)
  end

  local entries = _cache.entries
  if _cache.entries_root ~= current_root or not entries or #entries < 2 then return '' end

  local primary = entries[1]
  for i, wt in ipairs(entries) do
    if wt.path == current_root then
      -- 仕様変更: 同期されていればアイコンを表示
      if i ~= 1 and wt.head == primary.head then
        return '󰚰'
      end
      break
    end
  end
  return ''
end

function M.worktree_needs_sync(path)
  local target = path and utils.normalize_path(path) or get_work_tree()
  local entries = get_worktrees(false, target)
  if type(entries) ~= 'table' then
    entries = {}
  end
  if #entries < 2 then return false end
  local primary = entries[1]
  if not primary then
    return false
  end
  for i, wt in ipairs(entries) do
    if wt.path == target then
      if i == 1 then return false end
      return wt.head ~= primary.head, { primary_head = primary.head, worktree_head = wt.head }
    end
  end
  return false
end

function M.open_worktree_path(path)
  if not path or path == "" then return end
  local abs_path = utils.normalize_path(path)
  local resession = require("resession")

  local function get_session_name()
    local p = vim.fn.getcwd():gsub('/+$', '')
    local branch = vim.trim(vim.fn.system("git branch --show-current"))
    return (vim.v.shell_error == 0 and branch ~= "") and (p .. '-' .. branch) or p
  end

  pcall(resession.save, get_session_name(), { dir = "dirsession", notify = false })
  vim.cmd('silent! %bwipeout!')
  vim.cmd('cd ' .. vim.fn.fnameescape(abs_path))

  vim.defer_fn(function()
    pcall(resession.load, get_session_name(), { dir = "dirsession", notify = false })
    local listed = vim.fn.getbufinfo({buflisted = 1})
    local has_file = false
    for _, b in ipairs(listed) do
      if b.name ~= "" and vim.api.nvim_get_option_value('buftype', { buf = b.bufnr }) == "" then
        has_file = true; break
      end
    end
    if not has_file then vim.cmd('intro') end
  end, 50)
end

function M.remove_worktree_path(path, force)
  if not path or path == "" then return end
  local abs_path = utils.normalize_path(path)
  if not abs_path then return false end
  local entries = get_worktrees(false, abs_path)
  if type(entries) ~= 'table' then return false end
  if #entries == 0 then return end
  local primary = entries[1]
  if not primary then return false end
  local repo = vim.fn.shellescape(primary.path)

  if abs_path == primary.path then
    vim.notify("Cannot remove the primary worktree", vim.log.levels.WARN); return false
  end

  if vim.fn.confirm("Remove worktree?\n" .. abs_path, "&Yes\n&No", 2) ~= 1 then return false end

  local cmd = string.format(
    'git -C %s worktree remove %s %s',
    repo,
    force and '--force' or '',
    vim.fn.shellescape(abs_path)
  )
  local output = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    if not force and output:match('%-%-force') and vim.fn.confirm("Force remove?", "&Yes\n&No", 2) == 1 then
      return M.remove_worktree_path(path, true)
    end
    vim.notify("Failed: " .. vim.fn.trim(output), vim.log.levels.ERROR); return false
  end
  M.clear_cache()
  utils.fire_fugitive_changed({ work_tree = primary.path })
  return true
end

local function add_worktree(bufnr)
  local entries = get_worktrees(false, utils.get_buf_work_tree(bufnr))
  if type(entries) ~= 'table' then
    entries = {}
  end
  if #entries == 0 then return end
  local primary = entries[1]
  local project_name = vim.fn.fnamemodify(primary.path, ':t')
  local worktree_base = vim.fn.expand('~/.worktree/' .. project_name)
  local repo = vim.fn.shellescape(primary.path)

  vim.ui.input({ prompt = 'Worktree name: ' }, function(name)
    if not name or name == '' then return end
    local path, branch = worktree_base .. '/' .. name, name
    local path_arg = vim.fn.shellescape(path)
    local branch_arg = vim.fn.shellescape(branch)
    local branch_ref_arg = vim.fn.shellescape('refs/heads/' .. branch)

    vim.fn.system('git -C ' .. repo .. ' rev-parse --verify --quiet ' .. branch_ref_arg)
    local exists = (vim.v.shell_error == 0)

    local cmd = exists
      and string.format('git -C %s worktree add %s %s', repo, path_arg, branch_arg)
      or  string.format('git -C %s worktree add -b %s %s HEAD', repo, branch_arg, path_arg)

    local output = vim.fn.system(cmd)
    if vim.v.shell_error == 0 then
      vim.notify(string.format("Added worktree '%s'", branch))
      M.clear_cache()
      utils.fire_fugitive_changed({ bufnr = bufnr, work_tree = primary.path })
    else
      vim.notify("Failed: " .. vim.fn.trim(output), vim.log.levels.ERROR)
    end
  end)
end

function M.get_summary(work_tree)
  local current_root = get_work_tree(work_tree)
  local entries = get_worktrees(false, current_root)
  if type(entries) ~= 'table' then
    entries = {}
  end
  if #entries <= 1 then return nil end
  local primary = entries[1]
  local main_head = primary and primary.head or nil

  local lines = { 'Worktrees (' .. #entries .. ')' }
  for i, wt in ipairs(entries) do
    local path = vim.fn.fnamemodify(wt.path, ':~')
    local branch = wt.branch or '(detached)'
    local head = (wt.head or ''):sub(1, 7)

    -- 同期アイコンの判定（親と同じハッシュなら表示）
    local is_main = (i == 1)
    local is_synced = (not is_main and main_head and wt.head == main_head)
    local sync_icon = is_synced and ' 󰚰' or ''

    -- ステータス画面用は左詰め + 右側に同期アイコン
    table.insert(lines, string.format('%s  %s  %s%s', path, branch, head, sync_icon))
  end
  return lines
end

function M.setup(group)
  vim.api.nvim_create_user_command('Gworktree', open_worktree_list, {})
  vim.api.nvim_create_user_command('GworktreeSync', M.sync_current_worktree_to_primary, {})

  vim.api.nvim_create_autocmd('FileType', { group = group, pattern = 'fugitive', callback = function(ev)
    vim.keymap.set('n', 'W', ':Gworktree<CR>', { buffer = ev.buf, silent = true })
    vim.keymap.set('n', 'gs', M.sync_current_worktree_to_primary, { buffer = ev.buf, silent = true })
  end })

  vim.api.nvim_create_autocmd('FileType', { group = group, pattern = 'fugitiveworktree', callback = function(ev)
    local b = ev.buf
    local buf_group = vim.api.nvim_create_augroup('fugitive_worktree_buf_' .. b, { clear = true })
    vim.opt_local.number, vim.opt_local.relativenumber, vim.opt_local.signcolumn = false, false, 'no'
    vim.keymap.set('n', 'g?', function() help.show('Worktree keys', { 'g? help', '<CR> open', 'gs sync', 'a add', 'X remove', 'R refresh', 'q close' }) end, { buffer = b })
    vim.keymap.set('n', '<CR>', function() local e = entry_at_cursor(b); if e then M.open_worktree_path(e.path) end end, { buffer = b })
    vim.keymap.set('n', 'gs', function()
      local e = entry_at_cursor(b)
      local entries = get_worktrees(false, utils.get_buf_work_tree(b))
      if type(entries) ~= 'table' then return end
      local primary = entries[1]
      if e and primary then perform_sync(primary.path, e.head) end
    end, { buffer = b })
    vim.keymap.set('n', 'X', function() local e = entry_at_cursor(b); if e then M.remove_worktree_path(e.path) end end, { buffer = b })
    vim.keymap.set('n', 'a', function() add_worktree(b) end, { buffer = b })
    vim.keymap.set('n', 'R', function() M.refresh_worktree_list(b) end, { buffer = b })
    vim.keymap.set('n', 'q', ':bd<CR>', { buffer = b, nowait = true, silent = true })
    utils.setup_repo_refresh(buf_group, b, function(bufnr)
      M.clear_cache()
      M.refresh_worktree_list(bufnr)
    end, { visible_only = true })
  end })

  vim.api.nvim_create_autocmd({'DirChanged', 'BufEnter', 'BufWritePost'}, { group = group, callback = M.clear_cache })
  vim.api.nvim_create_autocmd('User', { group = group, pattern = 'FugitiveChanged', callback = M.clear_cache })
end

return M

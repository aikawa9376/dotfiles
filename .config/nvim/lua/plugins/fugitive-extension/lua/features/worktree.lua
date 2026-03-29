local M = {}
local help = require("features.help")

-- 内部キャッシュ（最軽量化のため）
local _cache = {
  entries = nil,
  root = nil,
  mtime = 0,
  root_mtime = 0,
}
local CACHE_TTL = 5 -- 秒

-- ワークツリーのルート取得（キャッシュ付き）
local function get_work_tree()
  local now = os.time()
  if _cache.root and (now - _cache.root_mtime) < CACHE_TTL then
    return _cache.root
  end

  local git_dir = vim.fn.FugitiveGitDir()
  if git_dir == '' then return nil end

  local work_tree = vim.fn.trim(vim.fn.system('git --git-dir=' .. vim.fn.shellescape(git_dir) .. ' rev-parse --show-toplevel'))
  if vim.v.shell_error ~= 0 or work_tree == '' then return nil end

  _cache.root = work_tree:gsub('/+$', '')
  _cache.root_mtime = now
  return _cache.root
end

-- ワークツリー一覧の取得（キャッシュ付き）
local function get_worktrees(force)
  local now = os.time()
  if not force and _cache.entries and (now - _cache.mtime) < CACHE_TTL then
    return _cache.entries
  end

  local ok, entries = pcall(function()
    local output = vim.fn.systemlist('git worktree list --porcelain')
    if vim.v.shell_error ~= 0 then return {} end

    local res, current = {}, nil
    for _, line in ipairs(output) do
      if line:match('^worktree ') then
        if current then table.insert(res, current) end
        current = { path = vim.fn.fnamemodify(line:sub(10), ':p'):gsub('/+$', '') }
      elseif current then
        local key, val = line:match('^(%S+)%s+(.*)$')
        if key == 'HEAD' then current.head = val
        elseif key == 'branch' then current.branch = val:gsub('^refs/heads/', '') end
      end
    end
    if current then table.insert(res, current) end
    return res
  end)

  if ok then
    _cache.entries = entries
    _cache.mtime = now
    return entries
  end
  return {}
end

function M.clear_cache()
  _cache.entries = nil
  _cache.root = nil
  _cache.mtime = 0
  _cache.root_mtime = 0
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
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return end
  local entries = vim.b[bufnr].worktree_entries
  if not entries then return end

  local ns = vim.api.nvim_create_namespace('fugitiveworktree_highlight')
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local current_root = get_work_tree()
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
    if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == 'fugitiveworktree' then
      M.refresh_worktree_list(bufnr)
    end
  end
end

function M.refresh_worktree_list(bufnr)
  local entries = get_worktrees(true)
  local current_root = get_work_tree()
  local main_head = entries[1] and entries[1].head

  local lines = {}
  for i, wt in ipairs(entries) do
    table.insert(lines, format_line(wt, current_root, main_head, i == 1))
  end

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.b[bufnr].worktree_entries = entries
  apply_highlights(bufnr)
end

local function open_worktree_list()
  local entries = get_worktrees(true)
  if #entries == 0 then return end

  vim.cmd('botright split fugitive-worktree://')
  local bufnr = vim.api.nvim_get_current_buf()

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
end

function M.sync_current_worktree_to_primary()
  local entries = get_worktrees()
  if #entries < 2 then return end

  local current_root = get_work_tree()
  local primary = entries[1]
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
  local now = os.time()
  if _cache.entries and (now - _cache.mtime) < CACHE_TTL then
  else
    get_worktrees()
  end

  local entries = _cache.entries
  if not entries or #entries < 2 then return '' end

  local current_root = get_work_tree()
  if not current_root then return '' end

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
  local entries = get_worktrees()
  if #entries < 2 then return false end
  local target = path and vim.fn.fnamemodify(path, ':p'):gsub('/+$', '') or get_work_tree()
  local primary = entries[1]
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
  local abs_path = vim.fn.fnamemodify(path, ':p'):gsub('/+$', '')
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
  local abs_path = vim.fn.fnamemodify(path, ':p'):gsub('/+$', '')
  local entries = get_worktrees()
  if #entries == 0 then return end

  if abs_path == entries[1].path then
    vim.notify("Cannot remove the primary worktree", vim.log.levels.WARN); return false
  end

  if vim.fn.confirm("Remove worktree?\n" .. abs_path, "&Yes\n&No", 2) ~= 1 then return false end

  local cmd = string.format('git worktree remove %s %s', force and '--force' or '', vim.fn.shellescape(abs_path))
  local output = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    if not force and output:match('%-%-force') and vim.fn.confirm("Force remove?", "&Yes\n&No", 2) == 1 then
      return M.remove_worktree_path(path, true)
    end
    vim.notify("Failed: " .. vim.fn.trim(output), vim.log.levels.ERROR); return false
  end
  M.clear_cache()
  return true
end

local function add_worktree(bufnr)
  local entries = get_worktrees()
  if #entries == 0 then return end
  local primary = entries[1]
  local project_name = vim.fn.fnamemodify(primary.path, ':t')
  local worktree_base = vim.fn.expand('~/.worktree/' .. project_name)

  vim.ui.input({ prompt = 'Worktree name: ' }, function(name)
    if not name or name == '' then return end
    local path, branch = worktree_base .. '/' .. name, name

    vim.fn.system('git rev-parse --verify --quiet ' .. vim.fn.shellescape('refs/heads/' .. branch))
    local exists = (vim.v.shell_error == 0)

    local cmd = exists
      and string.format('git worktree add %s %s', vim.fn.shellescape(path), vim.fn.shellescape(branch))
      or  string.format('git worktree add -b %s %s HEAD', vim.fn.shellescape(branch), vim.fn.shellescape(path))

    local output = vim.fn.system(cmd)
    if vim.v.shell_error == 0 then
      vim.notify(string.format("Added worktree '%s'", branch))
      M.clear_cache()
      M.refresh_worktree_list(bufnr)
    else
      vim.notify("Failed: " .. vim.fn.trim(output), vim.log.levels.ERROR)
    end
  end)
end

function M.get_summary()
  local entries = get_worktrees()
  if #entries <= 1 then return nil end
  local current_root = get_work_tree()
  local main_head = entries[1] and entries[1].head

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
    vim.opt_local.number, vim.opt_local.relativenumber, vim.opt_local.signcolumn = false, false, 'no'
    vim.keymap.set('n', 'g?', function() help.show('Worktree keys', { 'g? help', '<CR> open', 'gs sync', 'a add', 'X remove', 'R refresh', 'q close' }) end, { buffer = b })
    vim.keymap.set('n', '<CR>', function() local e = entry_at_cursor(b); if e then M.open_worktree_path(e.path) end end, { buffer = b })
    vim.keymap.set('n', 'gs', function()
      local e = entry_at_cursor(b)
      local entries = get_worktrees()
      if e and entries[1] then perform_sync(entries[1].path, e.head) end
    end, { buffer = b })
    vim.keymap.set('n', 'X', function() local e = entry_at_cursor(b); if e and M.remove_worktree_path(e.path) then M.refresh_worktree_list(b) end end, { buffer = b })
    vim.keymap.set('n', 'a', function() add_worktree(b) end, { buffer = b })
    vim.keymap.set('n', 'R', function() M.refresh_worktree_list(b) end, { buffer = b })
    vim.keymap.set('n', 'q', ':bd<CR>', { buffer = b, nowait = true, silent = true })
  end })

  vim.api.nvim_create_autocmd({'DirChanged', 'BufEnter', 'BufWritePost'}, { group = group, callback = M.clear_cache })
  vim.api.nvim_create_autocmd('User', { group = group, pattern = 'FugitiveChanged', callback = M.clear_cache })
end

return M

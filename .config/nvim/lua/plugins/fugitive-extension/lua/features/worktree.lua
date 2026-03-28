local M = {}
local help = require("features.help")

local function get_work_tree()
  local git_dir = vim.fn.FugitiveGitDir()
  if git_dir == '' then return nil end
  local work_tree_cmd = 'git --git-dir=' .. vim.fn.shellescape(git_dir) .. ' rev-parse --show-toplevel'
  local work_tree = vim.fn.trim(vim.fn.system(work_tree_cmd))
  if vim.v.shell_error ~= 0 or work_tree == '' then return nil end
  return work_tree:gsub('/+$', '') -- Normalize: remove trailing slash
end

local function parse_worktrees(work_tree)
  local output = vim.fn.systemlist('git -C ' .. vim.fn.shellescape(work_tree) .. ' worktree list --porcelain')
  if vim.v.shell_error ~= 0 then return {} end

  local entries, current = {}, nil
  for _, line in ipairs(output) do
    if line:match('^worktree ') then
      if current then table.insert(entries, current) end
      current = { path = vim.fn.fnamemodify(line:sub(10), ':p'):gsub('/+$', '') }
    elseif current then
      local key, val = line:match('^(%S+)%s+(.*)$')
      if key == 'HEAD' then current.head = val
      elseif key == 'branch' then current.branch = val:gsub('^refs/heads/', '')
      elseif key == 'bare' then current.bare = true
      elseif key == 'locked' then current.locked = true; current.lock_reason = val
      elseif key == 'prunable' then current.prunable = true end
    end
  end
  if current then table.insert(entries, current) end
  return entries
end

local function format_entries(entries, primary_path)
  local formatted = {}
  local primary_abs = primary_path and vim.fn.fnamemodify(primary_path, ':p'):gsub('/+$', '') or nil
  for _, wt in ipairs(entries) do
    local path = vim.fn.fnamemodify(wt.path or '', ':~')
    local prefix = (primary_abs and wt.path and wt.path == primary_abs) and '* ' or '  '
    local branch = wt.branch and wt.branch ~= '' and wt.branch or '(detached)'
    local head = wt.head and wt.head:sub(1, 7) or '???????'
    table.insert(formatted, string.format('%s%s  %s  %s', prefix, path, branch, head))
  end
  return formatted
end

local function apply_highlights(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return end
  local entries = vim.b[bufnr].worktree_entries
  if not entries then return end

  local ns = vim.api.nvim_create_namespace('fugitiveworktree_highlight')
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local root_abs = vim.b[bufnr].worktree_root and vim.fn.fnamemodify(vim.b[bufnr].worktree_root, ':p'):gsub('/+$', '')
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  for idx, line in ipairs(lines) do
    local entry = entries[idx]
    if entry then
      local path = vim.fn.fnamemodify(entry.path, ':~')
      local branch = entry.branch or '(detached)'
      local head = (entry.head or ''):sub(1, 7)

      local s_path = line:find(path, 1, true)
      if s_path then
        local hl = (root_abs and entry.path == root_abs) and 'DiagnosticOk' or 'Directory'
        vim.api.nvim_buf_set_extmark(bufnr, ns, idx - 1, s_path - 1, { end_col = s_path - 1 + #path, hl_group = hl })
      end
      local s_branch = line:find(branch, (s_path or 0) + #path, true)
      if s_branch then
        vim.api.nvim_buf_set_extmark(bufnr, ns, idx - 1, s_branch - 1, { end_col = s_branch - 1 + #branch, hl_group = 'Type' })
      end
      local s_head = line:find(head, (s_branch or 0) + #branch, true)
      if s_head then
        vim.api.nvim_buf_set_extmark(bufnr, ns, idx - 1, s_head - 1, { end_col = s_head - 1 + #head, hl_group = 'Comment' })
      end
    end
  end
end

local function refresh_worktree_list(bufnr)
  local work_tree = vim.b[bufnr].worktree_root or get_work_tree()
  if not work_tree then return end
  local entries = parse_worktrees(work_tree)
  local lines = format_entries(entries, work_tree)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.b[bufnr].worktree_entries = entries
  vim.b[bufnr].worktree_root = work_tree
  apply_highlights(bufnr)
end

local function open_worktree_list()
  local work_tree = get_work_tree()
  if not work_tree then return end
  local entries = parse_worktrees(work_tree)
  if #entries == 0 then return end
  local lines = format_entries(entries, work_tree)
  vim.cmd('botright split fugitive-worktree://')
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = bufnr })
  vim.api.nvim_set_option_value('buflisted', false, { buf = bufnr })
  vim.api.nvim_set_option_value('bufhidden', 'hide', { buf = bufnr })
  vim.api.nvim_set_option_value('swapfile', false, { buf = bufnr })
  vim.bo[bufnr].filetype = 'fugitiveworktree'
  vim.bo[bufnr].modifiable = false
  vim.b[bufnr].worktree_entries = entries
  vim.b[bufnr].worktree_root = work_tree
  apply_highlights(bufnr)
end

local function entry_at_cursor(bufnr)
  local entries = vim.b[bufnr].worktree_entries
  local idx = vim.fn.line('.')
  return entries and entries[idx] or nil
end

local function get_primary_worktree(any_path)
  local output = vim.fn.systemlist('git -C ' .. vim.fn.shellescape(any_path) .. ' worktree list --porcelain')
  if #output > 0 and output[1]:match('^worktree ') then
    return vim.fn.fnamemodify(output[1]:sub(10), ':p'):gsub('/+$', '')
  end
  return nil
end

local function get_default_branch(repo_path)
  local res = vim.fn.systemlist('git -C ' .. vim.fn.shellescape(repo_path) .. ' symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null')
  if vim.v.shell_error == 0 and #res > 0 then
    local branch = res[1]:gsub('^origin/', '')
    if branch ~= '' then return branch end
  end
  for _, b in ipairs({ 'main', 'master' }) do
    vim.fn.system('git -C ' .. vim.fn.shellescape(repo_path) .. ' rev-parse --verify --quiet ' .. b)
    if vim.v.shell_error == 0 then return b end
  end
  return 'main'
end

local function perform_sync(base_dir, target_head, target_path)
  local is_target_primary = vim.fn.fnamemodify(target_path, ':p'):gsub('/+$', '') == vim.fn.fnamemodify(base_dir, ':p'):gsub('/+$', '')
  if vim.fn.system('git -C ' .. vim.fn.shellescape(base_dir) .. ' status --porcelain') ~= '' then
    vim.fn.system('git -C ' .. vim.fn.shellescape(base_dir) .. ' stash push -u -m "Auto-stash before manual sync"')
    vim.notify("Primary worktree: changes stashed.", vim.log.levels.INFO)
  end
  if is_target_primary then
    local def_branch = get_default_branch(base_dir)
    vim.fn.system('git -C ' .. vim.fn.shellescape(base_dir) .. ' checkout ' .. vim.fn.shellescape(def_branch))
    vim.notify("Synced to default branch: " .. def_branch)
  else
    vim.fn.system('git -C ' .. vim.fn.shellescape(base_dir) .. ' checkout --detach ' .. vim.fn.shellescape(target_head))
    vim.notify("Synced to: " .. target_head:sub(1,7))
  end
end

function M.sync_current_worktree_to_primary()
  local work_tree = get_work_tree()
  local base_dir = work_tree and get_primary_worktree(work_tree)
  if not base_dir then return end
  local head = vim.fn.trim(vim.fn.system('git -C ' .. vim.fn.shellescape(work_tree) .. ' rev-parse HEAD'))
  perform_sync(base_dir, head, work_tree)
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

  -- 1. Save current
  pcall(resession.save, get_session_name(), { dir = "dirsession", notify = false })

  -- 2. Switch context
  vim.cmd('silent! %bwipeout!')
  vim.cmd('cd ' .. vim.fn.fnameescape(abs_path))

  -- 3. Load or default after env settles
  vim.defer_fn(function()
    pcall(resession.load, get_session_name(), { dir = "dirsession", notify = false })
    local listed = vim.fn.getbufinfo({buflisted = 1})
    local has_file = false
    for _, b in ipairs(listed) do
      if b.name ~= "" and vim.api.nvim_get_option_value('buftype', { buf = b.bufnr }) == "" then
        has_file = true; break
      end
    end
    if not has_file then vim.cmd('G') end
  end, 50)
end

function M.remove_worktree_path(path, force)
  if not path or path == "" then return end
  local abs_path = vim.fn.fnamemodify(path, ':p'):gsub('/+$', '')
  local root = get_work_tree()
  if not root then return end

  if abs_path == root:gsub('/+$', '') then
    vim.notify("Cannot remove the primary worktree", vim.log.levels.WARN); return false
  end

  if vim.fn.confirm("Remove worktree?\n" .. abs_path, "&Yes\n&No", 2) ~= 1 then return false end

  local cmd = string.format('git -C %s worktree remove %s%s', vim.fn.shellescape(root), force and '--force ' or '', vim.fn.shellescape(abs_path))
  local output = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    if not force and output:match('%-%-force') and vim.fn.confirm("Force remove?", "&Yes\n&No", 2) == 1 then
      return M.remove_worktree_path(path, true)
    end
    vim.notify("Failed: " .. vim.fn.trim(output), vim.log.levels.ERROR); return false
  end
  return true
end

local function prune_worktrees(bufnr)
  local root = get_work_tree()
  if not root then return end
  vim.fn.jobstart('git -C ' .. vim.fn.shellescape(root) .. ' worktree prune', {
    on_exit = function(_, code)
      if code == 0 then refresh_worktree_list(bufnr) end
    end
  })
end

local function add_worktree(bufnr)
  local root = get_work_tree()
  if not root then return end
  local primary = get_primary_worktree(root) or root
  local project_name = vim.fn.fnamemodify(primary, ':t')
  local worktree_base = vim.fn.expand('~/.worktree/' .. project_name)

  vim.ui.input({ prompt = 'Worktree name: ' }, function(name)
    if not name or name == '' then return end
    local path, branch = worktree_base .. '/' .. name, name
    vim.fn.system('git -C ' .. vim.fn.shellescape(root) .. ' rev-parse --verify --quiet ' .. vim.fn.shellescape('refs/heads/' .. branch))
    local exists, cmd_parts = (vim.v.shell_error == 0), { 'git', '-C', vim.fn.shellescape(root), 'worktree', 'add' }
    if exists then table.insert(cmd_parts, vim.fn.shellescape(path)); table.insert(cmd_parts, vim.fn.shellescape(branch))
    else table.insert(cmd_parts, '-b ' .. vim.fn.shellescape(branch)); table.insert(cmd_parts, vim.fn.shellescape(path)); table.insert(cmd_parts, 'HEAD') end

    local output = vim.fn.system(table.concat(cmd_parts, ' '))
    if vim.v.shell_error == 0 then
      vim.notify(string.format("Added worktree '%s'", branch))
      refresh_worktree_list(bufnr)
    else
      vim.notify("Failed: " .. vim.fn.trim(output), vim.log.levels.ERROR)
    end
  end)
end

function M.get_summary(work_tree)
  local entries = parse_worktrees(work_tree)
  if #entries <= 1 then return nil end
  local lines = { 'Worktrees (' .. #entries .. ')' }
  for _, wt in ipairs(entries) do
    table.insert(lines, string.format('%s  %s  %s', vim.fn.fnamemodify(wt.path, ':~'), wt.branch or '(detached)', (wt.head or ''):sub(1, 7)))
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
    vim.keymap.set('n', 'g?', function() help.show('Worktree keys', { 'g? help', '<CR> open', 'ws sync', 'a add', 'X remove', 'p prune', 'R refresh', 'q close' }) end, { buffer = b })
    vim.keymap.set('n', '<CR>', function() local e = entry_at_cursor(b); if e then M.open_worktree_path(e.path) end end, { buffer = b })
    vim.keymap.set('n', 'gs', function() local e = entry_at_cursor(b); if e then perform_sync(get_primary_worktree(e.path), e.head, e.path) end end, { buffer = b })
    vim.keymap.set('n', 'X', function() local e = entry_at_cursor(b); if e and M.remove_worktree_path(e.path) then refresh_worktree_list(b) end end, { buffer = b })
    vim.keymap.set('n', 'p', function() prune_worktrees(b) end, { buffer = b })
    vim.keymap.set('n', 'a', function() add_worktree(b) end, { buffer = b })
    vim.keymap.set('n', 'R', function() refresh_worktree_list(b) end, { buffer = b })
    vim.keymap.set('n', 'q', ':bd<CR>', { buffer = b, nowait = true })
  end })
end

return M

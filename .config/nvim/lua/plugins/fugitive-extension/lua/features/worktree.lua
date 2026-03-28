local M = {}
local help = require("features.help")

local function get_work_tree()
  local git_dir = vim.fn.FugitiveGitDir()
  if git_dir == '' then
    return nil
  end
  local work_tree_cmd = 'git --git-dir=' .. vim.fn.shellescape(git_dir) .. ' rev-parse --show-toplevel'
  local work_tree = vim.fn.trim(vim.fn.system(work_tree_cmd))
  if vim.v.shell_error ~= 0 or work_tree == '' then
    return nil
  end
  return work_tree
end

local function parse_worktrees(work_tree)
  local output = vim.fn.systemlist('git -C ' .. vim.fn.shellescape(work_tree) .. ' worktree list --porcelain')
  if vim.v.shell_error ~= 0 then
    return {}
  end

  local entries = {}
  local current = nil

  for _, line in ipairs(output) do
    if line:match('^worktree ') then
      if current then
        table.insert(entries, current)
      end
      current = { path = vim.fn.fnamemodify(line:sub(10), ':p') }
    elseif current then
      local key, val = line:match('^(%S+)%s+(.*)$')
      if key == 'HEAD' then
        current.head = val
      elseif key == 'branch' then
        current.branch = val:gsub('^refs/heads/', '')
      elseif key == 'bare' then
        current.bare = true
      elseif key == 'locked' then
        current.locked = true
        current.lock_reason = val
      elseif key == 'prunable' then
        current.prunable = true
      end
    end
  end
  if current then
    table.insert(entries, current)
  end

  return entries
end

local function format_entries(entries, primary_path)
  local formatted = {}
  local primary_abs = primary_path and vim.fn.fnamemodify(primary_path, ':p') or nil

  for _, wt in ipairs(entries) do
    local path = vim.fn.fnamemodify(wt.path or '', ':~')
    local prefix = (primary_abs and wt.path and vim.fn.fnamemodify(wt.path, ':p') == primary_abs) and '* ' or '  '
    local branch = wt.branch and wt.branch ~= '' and wt.branch or '(detached)'
    local head = wt.head and wt.head:sub(1, 7) or '???????'
    local flags = {}
    if wt.locked then table.insert(flags, 'locked') end
    if wt.prunable then table.insert(flags, 'prunable') end
    if wt.bare then table.insert(flags, 'bare') end
    local flag_str = #flags > 0 and (' [' .. table.concat(flags, ',') .. ']') or ''
    table.insert(formatted, string.format('%s%s  %s  %s%s', prefix, path, branch, head, flag_str))
  end

  return formatted
end

local function apply_highlights(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end

  local entries = vim.b[bufnr].worktree_entries
  if not entries then
    return
  end

  local ns = vim.api.nvim_create_namespace('fugitiveworktree_highlight')
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local root_abs = vim.b[bufnr].worktree_root and vim.fn.fnamemodify(vim.b[bufnr].worktree_root, ':p')
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local function add_range(line, substr, hl, row)
    if not (substr and substr ~= '' and hl) then return end
    local s = line:find(substr, 1, true)
    if not s then return end
    local col = s - 1
    vim.api.nvim_buf_set_extmark(bufnr, ns, (row or 1) - 1, col, {
      end_col = col + #substr,
      hl_group = hl,
      hl_mode = 'combine',
    })
  end

  for idx, line in ipairs(lines) do
    local entry = entries[idx]
    if entry then
      local path = entry.path and vim.fn.fnamemodify(entry.path, ':~')
      local is_primary = root_abs and entry.path and vim.fn.fnamemodify(entry.path, ':p') == root_abs
      local head = entry.head and entry.head:sub(1, 7)
      local branch = entry.branch and (entry.branch ~= '' and entry.branch or '(detached)')
      local flag_str = line:match('%[(.+)%]')

      if is_primary and path then
        add_range(line, path, 'DiagnosticOk', idx)
      end
      if branch then
        add_range(line, branch, 'Identifier', idx)
      end
      if head then
        add_range(line, head, 'Number', idx)
      end
      if flag_str then
        for flag in flag_str:gmatch('[^,]+') do
          local hl = flag:match('locked') and 'DiagnosticWarn' or (flag:match('prunable') and 'DiagnosticHint' or 'DiagnosticInfo')
          add_range(line, flag, hl, idx)
        end
      end
    end
  end
end

local function refresh_worktree_list(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local work_tree = vim.b[bufnr].worktree_root or get_work_tree()
  if not work_tree then
    vim.notify("Not in a git repository", vim.log.levels.ERROR)
    return
  end

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
  if not work_tree then
    vim.notify("Not in a git repository", vim.log.levels.ERROR)
    return
  end

  local entries = parse_worktrees(work_tree)
  if #entries == 0 then
    vim.notify("No worktrees found.", vim.log.levels.INFO)
    return
  end

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
  if not entries then
    return nil
  end
  local idx = vim.fn.line('.')
  return entries[idx]
end

local function get_primary_worktree(any_path)
  local output = vim.fn.systemlist('git -C ' .. vim.fn.shellescape(any_path) .. ' worktree list --porcelain')
  if #output > 0 and output[1]:match('^worktree ') then
    return vim.fn.fnamemodify(output[1]:sub(10), ':p')
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
  local base_dir_abs = vim.fn.fnamemodify(base_dir, ':p')
  local target_path_abs = vim.fn.fnamemodify(target_path, ':p')
  local is_target_primary = target_path_abs == base_dir_abs

  -- Stash changes in primary if any
  local status = vim.fn.system('git -C ' .. vim.fn.shellescape(base_dir) .. ' status --porcelain')
  if status ~= '' then
    vim.fn.system('git -C ' .. vim.fn.shellescape(base_dir) .. ' stash push -u -m "Auto-stash before manual sync"')
    vim.notify("Primary worktree: changes stashed.", vim.log.levels.INFO)
  end

  if is_target_primary then
    -- Reset primary to default branch
    local def_branch = get_default_branch(base_dir)
    vim.fn.system('git -C ' .. vim.fn.shellescape(base_dir) .. ' checkout ' .. vim.fn.shellescape(def_branch))
    vim.notify("Primary worktree synced to default branch: " .. def_branch, vim.log.levels.INFO)
  else
    -- Sync primary to target's HEAD (detached)
    vim.fn.system('git -C ' .. vim.fn.shellescape(base_dir) .. ' checkout --detach ' .. vim.fn.shellescape(target_head))
    vim.notify("Primary worktree synced to: " .. target_head:sub(1,7), vim.log.levels.INFO)
  end
end

local function sync_primary_to_entry(bufnr)
  local entry = entry_at_cursor(bufnr)
  if not entry or not entry.path then return end

  local base_dir = get_primary_worktree(entry.path)
  if not base_dir then
    vim.notify("Could not identify primary worktree.", vim.log.levels.ERROR)
    return
  end

  perform_sync(base_dir, entry.head, entry.path)
end

function M.sync_current_worktree_to_primary()
  local work_tree = get_work_tree()
  if not work_tree then
    vim.notify("Not in a git repository", vim.log.levels.ERROR)
    return
  end

  local base_dir = get_primary_worktree(work_tree)
  if not base_dir then
    vim.notify("Could not identify primary worktree.", vim.log.levels.ERROR)
    return
  end

  local head = vim.fn.trim(vim.fn.system('git -C ' .. vim.fn.shellescape(work_tree) .. ' rev-parse HEAD'))
  perform_sync(base_dir, head, work_tree)
end

local function get_session_name_for_path(path)
  local branch = vim.trim(vim.fn.system('git -C ' .. vim.fn.shellescape(path) .. ' branch --show-current'))
  local name = vim.fn.fnamemodify(path, ':p'):gsub('/$', '')
  if vim.v.shell_error == 0 and branch ~= "" then
    return name .. '-' .. branch
  else
    return name
  end
end

local function open_worktree(entry, _)
  if not entry or not entry.path then
    return
  end

  local resession_ok, resession = pcall(require, "resession")
  
  -- 1. Save current session before switching
  if resession_ok then
    local current_session = get_session_name_for_path(vim.fn.getcwd())
    pcall(resession.save, current_session, { dir = "dirsession", notify = false })
  end

  local target_path = vim.fn.fnamemodify(entry.path, ':p'):gsub('/$', '')
  local target_session = get_session_name_for_path(target_path)

  -- 2. Clear all buffers to get a "fresh" state
  vim.cmd('silent! %bwipeout!')

  -- 3. Global CD to the new worktree
  vim.cmd('cd ' .. vim.fn.fnameescape(target_path))

  -- 4. Load session if exists, otherwise start with Fugitive
  local loaded = false
  if resession_ok then
    local sessions = resession.list({ dir = "dirsession" })
    local exists = false
    for _, s in ipairs(sessions) do
      if s == target_session then exists = true; break end
    end

    if exists then
      local ok = pcall(resession.load, target_session, { dir = "dirsession", notify = false })
      loaded = ok
    end
  end

  if not loaded then
    vim.cmd('G')
  end
end

local function remove_worktree(bufnr, force)
  local entry = entry_at_cursor(bufnr)
  if not entry or not entry.path then
    vim.notify("No worktree on this line", vim.log.levels.WARN)
    return
  end

  local root = vim.b[bufnr].worktree_root or get_work_tree()
  if not root then
    vim.notify("Not in a git repository", vim.log.levels.ERROR)
    return
  end

  if vim.fn.fnamemodify(entry.path, ':p') == vim.fn.fnamemodify(root, ':p') then
    vim.notify("Cannot remove the primary worktree", vim.log.levels.WARN)
    return
  end

  local confirm = vim.fn.confirm(
    string.format("Remove worktree?\n%s", vim.fn.fnamemodify(entry.path, ':~')),
    "&Yes\n&No",
    2
  )
  if confirm ~= 1 then
    return
  end

  local cmd = string.format(
    'git -C %s worktree remove %s%s',
    vim.fn.shellescape(root),
    force and '--force ' or '',
    vim.fn.shellescape(entry.path)
  )
  local output = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    if not force and output:match('%-%-force') then
      local force_confirm = vim.fn.confirm("Removal failed. Force remove?", "&Yes\n&No", 2)
      if force_confirm == 1 then
        return remove_worktree(bufnr, true)
      end
    end
    vim.notify("Failed to remove worktree: " .. vim.fn.trim(output), vim.log.levels.ERROR)
    return
  end

  vim.notify("Removed worktree: " .. vim.fn.fnamemodify(entry.path, ':~'), vim.log.levels.INFO)
  refresh_worktree_list(bufnr)
end

local function prune_worktrees(bufnr)
  local root = vim.b[bufnr].worktree_root or get_work_tree()
  if not root then
    vim.notify("Not in a git repository", vim.log.levels.ERROR)
    return
  end

  vim.notify("Pruning worktrees...", vim.log.levels.INFO)
  vim.fn.jobstart('git -C ' .. vim.fn.shellescape(root) .. ' worktree prune', {
    on_exit = function(_, exit_code)
      vim.schedule(function()
        if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
          return
        end
        if exit_code == 0 then
          vim.notify("Pruned worktrees", vim.log.levels.INFO)
          refresh_worktree_list(bufnr)
        else
          vim.notify("Prune failed", vim.log.levels.ERROR)
        end
      end)
    end,
  })
end

local function add_worktree(bufnr)
  local root = vim.b[bufnr].worktree_root or get_work_tree()
  if not root then
    vim.notify("Not in a git repository", vim.log.levels.ERROR)
    return
  end

  local primary_root = get_primary_worktree(root) or root
  local project_name = vim.fn.fnamemodify(primary_root, ':t')
  local worktree_base = vim.fn.expand('~/.worktree/' .. project_name)

  vim.ui.input({ prompt = 'Worktree name (branch name): ' }, function(name)
    if not name or name == '' then return end
    local path = worktree_base .. '/' .. name
    local branch = name

    vim.fn.system('git -C ' .. vim.fn.shellescape(root) .. ' rev-parse --verify --quiet ' .. vim.fn.shellescape('refs/heads/' .. branch))
    local exists = vim.v.shell_error == 0

    local cmd_parts = { 'git', '-C', vim.fn.shellescape(root), 'worktree', 'add' }

    if exists then
      table.insert(cmd_parts, vim.fn.shellescape(path))
      table.insert(cmd_parts, vim.fn.shellescape(branch))
    else
      table.insert(cmd_parts, '-b ' .. vim.fn.shellescape(branch))
      table.insert(cmd_parts, vim.fn.shellescape(path))
      table.insert(cmd_parts, 'HEAD')
    end

    local cmd = table.concat(cmd_parts, ' ')
    local output = vim.fn.system(cmd)
    if vim.v.shell_error ~= 0 then
      vim.notify("Failed to add worktree: " .. vim.fn.trim(output), vim.log.levels.ERROR)
      return
    end

    vim.notify(string.format("Added worktree '%s' at %s", branch, vim.fn.fnamemodify(path, ':~')), vim.log.levels.INFO)
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      refresh_worktree_list(bufnr)
    end
  end)
end
function M.get_summary(work_tree)
  local entries = parse_worktrees(work_tree)
  if #entries <= 1 then return nil end

  local lines = {}
  table.insert(lines, 'Worktrees: (' .. tostring(#entries) .. ')')
  for _, wt in ipairs(entries) do
    local branch = wt.branch and wt.branch ~= '' and wt.branch or '(detached)'
    local head = wt.head and wt.head:sub(1, 7) or '???????'
    local path = vim.fn.fnamemodify(wt.path, ':~')
    -- Left aligned for status summary
    table.insert(lines, string.format('%s  %s  %s', path, branch, head))
  end
  return lines
end


local function show_worktree_help()
  help.show('Worktree buffer keys', {
    'g?     show this help',
    '<CR>   open worktree in tab (:tcd)',
    'o      open worktree in this window (:lcd)',
    'ws     sync primary worktree to this entry',
    'a      add worktree',
    'X      remove worktree (prompt/force as needed)',
    'p      prune worktrees',
    'R      refresh list',
    'q      close buffer',
  })
end

function M.setup(group)
  vim.api.nvim_create_user_command('Gworktree', open_worktree_list, {
    bang = false,
    desc = "Open git worktree list",
  })

  vim.api.nvim_create_user_command('GworktreeSync', function()
    M.sync_current_worktree_to_primary()
  end, {
    desc = "Sync primary worktree to current worktree state",
  })

  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'fugitive',
    callback = function(ev)
      vim.keymap.set('n', 'W', function()
        vim.cmd('Gworktree')
      end, { buffer = ev.buf, silent = true, desc = "Open worktree list" })

      vim.keymap.set('n', 'gs', function()
        M.sync_current_worktree_to_primary()
      end, { buffer = ev.buf, silent = true, desc = "Sync primary worktree to current" })
    end,
  })

  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'fugitiveworktree',
    callback = function(ev)
      local bufnr = ev.buf
      vim.opt_local.number = false
      vim.opt_local.relativenumber = false
      vim.opt_local.signcolumn = 'no'
      vim.opt_local.list = false

      vim.keymap.set('n', 'g?', function()
        show_worktree_help()
      end, { buffer = bufnr, silent = true, desc = "Help" })

      vim.keymap.set('n', '<CR>', function()
        open_worktree(entry_at_cursor(bufnr), 'tab')
      end, { buffer = bufnr, silent = true, desc = "Open worktree in new tab" })

      vim.keymap.set('n', 'o', function()
        open_worktree(entry_at_cursor(bufnr), 'window')
      end, { buffer = bufnr, silent = true, desc = "Open worktree in this window" })

      vim.keymap.set('n', 'gs', function()
        sync_primary_to_entry(bufnr)
      end, { buffer = bufnr, silent = true, desc = "Sync primary to selected entry" })

      vim.keymap.set('n', 'X', function()
        remove_worktree(bufnr, false)
      end, { buffer = bufnr, silent = true, desc = "Remove worktree" })

      vim.keymap.set('n', 'p', function()
        prune_worktrees(bufnr)
      end, { buffer = bufnr, silent = true, desc = "Prune worktrees" })

      vim.keymap.set('n', 'a', function()
        add_worktree(bufnr)
      end, { buffer = bufnr, silent = true, desc = "Add worktree" })

      vim.keymap.set('n', 'R', function()
        refresh_worktree_list(bufnr)
      end, { buffer = bufnr, silent = true, desc = "Refresh list" })

      vim.keymap.set('n', 'q', function()
        vim.cmd('bd')
      end, { buffer = bufnr, silent = true, desc = "Close list" })
    end,
  })
end

return M

local M = {}
local utils = require("git.utils")
local help = require("git.features.help")

local function get_stash_ref()
  local line = vim.api.nvim_get_current_line()
  return line:match('^(stash@{[0-9]+})')
end

local function refresh_stash_list(bufnr)
  if not utils.is_valid_buf(bufnr) then return end

  local stash_output = utils.get_stash_list(utils.get_buf_work_tree(bufnr))
  utils.with_buf_modifiable(bufnr, function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, stash_output)
  end)

  if #stash_output == 0 then
    vim.notify("No stashes left.", vim.log.levels.INFO)
    vim.defer_fn(function()
      vim.cmd('bd! ' .. bufnr)
    end, 500)
  end
end

local function open_stash_list(opts)
  local work_tree = opts and opts.work_tree or utils.get_work_tree({ bufnr = vim.api.nvim_get_current_buf() })
  if not work_tree then vim.notify('Not a git repository', vim.log.levels.WARN); return end
  local stash_output = utils.get_stash_list(work_tree)
  if vim.v.shell_error ~= 0 then
    vim.notify("Not a git repository or an error occurred.", vim.log.levels.ERROR)
    return
  end

  if #stash_output == 0 then
    vim.notify("No stashes found.", vim.log.levels.INFO)
    return
  end

  utils.open_panel_split('fugitive-stash://' .. work_tree)
  local bufnr = vim.api.nvim_get_current_buf()
  utils.set_buf_work_tree(bufnr, work_tree)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, stash_output)
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = bufnr })
  vim.api.nvim_set_option_value('bufhidden', 'hide', { buf = bufnr })
  vim.api.nvim_set_option_value('swapfile', false, { buf = bufnr })
  vim.bo[bufnr].filetype = 'fugitivestash'
  vim.bo[bufnr].modifiable = false
  return bufnr
end
M.open = open_stash_list

function M.rename(bufnr, ref)
  local root = utils.get_buf_work_tree(bufnr)
  if not root or not ref then return end
  local function git(args)
    local argv = { 'git', '-C', root }; vim.list_extend(argv, args)
    return vim.system(argv, { text = true }):wait()
  end
  local object = git({ 'rev-parse', '--verify', ref })
  if object.code ~= 0 then vim.notify(vim.trim(object.stderr), vim.log.levels.ERROR); return end
  local hash = vim.trim(object.stdout)
  local subject = git({ 'show', '-s', '--format=%s', hash })
  vim.ui.input({ prompt = 'New name for ' .. ref .. ': ', default = vim.trim(subject.stdout or '') }, function(value)
    if not value or vim.trim(value) == '' then return end
    local current = git({ 'rev-parse', '--verify', ref })
    if current.code ~= 0 or vim.trim(current.stdout) ~= hash then
      vim.notify('Stash list changed; select the stash again', vim.log.levels.WARN); return
    end
    local dropped = git({ 'stash', 'drop', ref })
    if dropped.code ~= 0 then vim.notify(vim.trim(dropped.stderr), vim.log.levels.ERROR); return end
    local stored = git({ 'stash', 'store', '-m', value, hash })
    if stored.code ~= 0 then
      vim.notify('Stash rename failed. Recover with git stash store ' .. hash .. '\n' .. vim.trim(stored.stderr), vim.log.levels.ERROR)
    end
    utils.fire_fugitive_changed({ work_tree = root })
    if utils.is_valid_buf(bufnr) and vim.bo[bufnr].filetype == 'fugitivestash' then refresh_stash_list(bufnr) end
  end)
end

local function show_stash_help()
  help.show('Stash buffer keys', {
    'A      apply stash',
    'P      pop stash',
    'X      drop stash',
    'O      open stash diff in tab',
    '<CR>   open stash diff in split',
    'q      close buffer',
  })
end

function M.setup(group)
  vim.api.nvim_create_user_command('Gstash', open_stash_list, {
    bang = false,
    desc = "Open git stash list",
  })

  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'fugitivestash',
    callback = function(ev)
      local bufnr = ev.buf

      vim.keymap.set('n', '?', function()
        show_stash_help()
      end, { buffer = bufnr, silent = true, desc = "Help" })
      vim.keymap.set('n', 'q', function()
        require('utilities').smart_close()
      end, { buffer = bufnr, nowait = true, silent = true, desc = 'Close stash list' })

      -- Let fugitive know how to find the git object on each line
      vim.b[bufnr].fugitive_object_pattern = [[\v(stash@\{[0-9]+\})]]

      vim.keymap.set('n', 'A', function()
        local stash_ref = get_stash_ref()
        if stash_ref then
          vim.cmd('Git stash apply ' .. stash_ref)
          utils.fire_fugitive_changed({ bufnr = bufnr })
        end
      end, { buffer = bufnr, silent = true, desc = "Apply stash" })

      vim.keymap.set('n', 'P', function()
        local stash_ref = get_stash_ref()
        if stash_ref then
          vim.cmd('Git stash pop --index ' .. stash_ref)
          utils.fire_fugitive_changed({ bufnr = bufnr })
        end
      end, { buffer = bufnr, silent = true, desc = "Pop stash" })

      vim.keymap.set('n', 'X', function()
        local stash_ref = get_stash_ref()
        if stash_ref then
          vim.cmd('Git stash drop ' .. stash_ref)
          utils.fire_fugitive_changed({ bufnr = bufnr })
        end
      end, { buffer = bufnr, silent = true, desc = "Drop stash" })

      vim.keymap.set('n', 'O', function()
        local stash_ref = get_stash_ref()
        if stash_ref then
          vim.cmd('tabnew')
          vim.cmd('Gedit ' .. stash_ref)
        end
      end, { buffer = bufnr, silent = true, desc = "Open stash diff in new tab" })

      vim.keymap.set('n', '<CR>', function()
        local stash_ref = get_stash_ref()
        if stash_ref then
          vim.cmd('Gvsplit ' .. stash_ref)
        end
      end, { buffer = bufnr, silent = true, desc = "Open stash diff in split buffer" })

      vim.keymap.set('n', 'R', function() refresh_stash_list(bufnr) end,
        { buffer = bufnr, silent = true, desc = 'Refresh stash list' })
      vim.keymap.set('n', 'cw', function() M.rename(bufnr, get_stash_ref()) end,
        { buffer = bufnr, silent = true, desc = 'Rename selected stash' })
      for key, action in pairs({ cza = 'apply', czp = 'pop' }) do
        vim.keymap.set('n', key, function()
          local ref = get_stash_ref()
          if ref then require('git.commands').git({ bufnr = bufnr, args = 'stash ' .. action .. ' --index ' .. ref }) end
        end, { buffer = bufnr, silent = true, desc = action .. ' selected stash with index' })
      end
      for key, action in pairs({ czA = 'apply', czP = 'pop' }) do
        vim.keymap.set('n', key, function()
          local ref = get_stash_ref()
          if ref then require('git.commands').git({ bufnr = bufnr, args = 'stash ' .. action .. ' ' .. ref }) end
        end, { buffer = bufnr, silent = true, desc = action .. ' selected stash without index' })
      end
      require('git.features.panel_keys').configure(bufnr)

      -- Set buffer options
      vim.opt_local.number = false
      vim.opt_local.relativenumber = false
      vim.opt_local.signcolumn = 'no'


      local buf_group = vim.api.nvim_create_augroup('fugitive_stash_buf_' .. bufnr, { clear = true })
      utils.setup_repo_refresh(buf_group, bufnr, function(target_bufnr)
        refresh_stash_list(target_bufnr)
      end, { visible_only = true })
    end,
  })
end

return M

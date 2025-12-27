local M = {}
local help = require("features.help")

local function get_stash_list()
  return vim.fn.systemlist("git stash list")
end

local function get_stash_ref()
  local line = vim.api.nvim_get_current_line()
  return line:match('^(stash@{[0-9]+})')
end

local function refresh_stash_list(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.api.nvim_set_option_value('modifiable', true, { buf = bufnr })

  local stash_output = get_stash_list()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, stash_output)

  if #stash_output == 0 then
    vim.notify("No stashes left.", vim.log.levels.INFO)
    vim.defer_fn(function()
      vim.cmd('bd! ' .. bufnr)
    end, 500)
  end

  vim.api.nvim_set_option_value('modifiable', false, { buf = bufnr })
end

local function open_stash_list()
  local stash_output = get_stash_list()
  if vim.v.shell_error ~= 0 then
    vim.notify("Not a git repository or an error occurred.", vim.log.levels.ERROR)
    return
  end

  if #stash_output == 0 then
    vim.notify("No stashes found.", vim.log.levels.INFO)
    return
  end

  vim.cmd('botright split fugitive-stash://')
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, stash_output)
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = bufnr })
  vim.api.nvim_set_option_value('bufhidden', 'hide', { buf = bufnr })
  vim.api.nvim_set_option_value('swapfile', false, { buf = bufnr })
  vim.bo[bufnr].filetype = 'fugitivestash'
  vim.bo[bufnr].modifiable = false
end

local function show_stash_help()
  help.show('Stash buffer keys', {
    'g?     show this help',
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

      vim.keymap.set('n', 'g?', function()
        show_stash_help()
      end, { buffer = bufnr, silent = true, desc = "Help" })

      -- Let fugitive know how to find the git object on each line
      vim.b[bufnr].fugitive_object_pattern = [[\v(stash@\{[0-9]+\})]]

      vim.keymap.set('n', 'A', function()
        local stash_ref = get_stash_ref()
        if stash_ref then
          vim.cmd('Git stash apply ' .. stash_ref)
          refresh_stash_list(bufnr)
        end
      end, { buffer = bufnr, silent = true, desc = "Apply stash" })

      vim.keymap.set('n', 'P', function()
        local stash_ref = get_stash_ref()
        if stash_ref then
          vim.cmd('Git stash pop ' .. stash_ref)
          refresh_stash_list(bufnr)
        end
      end, { buffer = bufnr, silent = true, desc = "Pop stash" })

      vim.keymap.set('n', 'X', function()
        local stash_ref = get_stash_ref()
        if stash_ref then
          vim.cmd('Git stash drop ' .. stash_ref)
          refresh_stash_list(bufnr)
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

      -- Set buffer options
      vim.opt_local.number = false
      vim.opt_local.relativenumber = false
      vim.opt_local.signcolumn = 'no'

      -- Load fugitive's default mappings
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
          vim.cmd('runtime! ftplugin/git.vim ftplugin/git_*.vim after/ftplugin/git.vim')
        end
      end, 10)
    end,
  })
end

return M

local M = {}
local utils = require("fugitive_utils")
local commands = require("features.commands")
local help = require("features.help")

local function get_reflog_list()
  local cmd = "git reflog --pretty=format:'%h%x09%gd%x09%gs' -n 1000"
  return vim.fn.systemlist(cmd)
end

local function refresh_reflog_list(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.api.nvim_set_option_value('modifiable', true, { buf = bufnr })

  local log_output = get_reflog_list()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, log_output)

  vim.api.nvim_set_option_value('modifiable', false, { buf = bufnr })
end

local function open_reflog_list()
  -- タブ区切り: hash <tab> selector <tab> subject
  local cmd = "reflog --pretty=format:'%h%x09%gd%x09%gs' -n 1000"
  vim.cmd('Git ' .. cmd)

  local bufnr = vim.api.nvim_get_current_buf()

  vim.bo[bufnr].filetype = 'fugitivereflog'
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = bufnr })
  vim.api.nvim_set_option_value('swapfile', false, { buf = bufnr })
  vim.opt_local.list = false
end

local function show_reflog_help()
  help.show('Reflog buffer keys', {
    'g?     show this help',
    'd      Diffview commit',
    'C      commit info float',
    '<C-y>  copy short hash',
    '<C-p>  toggle commit preview',
    'R      reload reflog',
    '<Leader>R  reset --mixed to commit',
    '<CR>   open in fugitive (:G edit)',
    'q      close buffer',
  })
end

function M.setup(group)
  vim.api.nvim_create_user_command('Greflog', open_reflog_list, {
    bang = false,
    desc = "Open git reflog list",
  })

  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'fugitivereflog',
    callback = function(ev)
      -- Syntax highlighting
      vim.opt_local.conceallevel = 0
      vim.opt_local.list = false

      vim.keymap.set('n', 'g?', function()
        show_reflog_help()
      end, { buffer = ev.buf, silent = true, desc = "Help" })
      vim.cmd([[
        syntax match FugitiveReflogHash /^[^\t]\+/ nextgroup=FugitiveReflogSep1
        syntax match FugitiveReflogSep1 /\t/ contained nextgroup=FugitiveReflogSelector
        syntax match FugitiveReflogSelector /[^\t]\+/ contained nextgroup=FugitiveReflogSep2
        syntax match FugitiveReflogSep2 /\t/ contained nextgroup=FugitiveReflogSubject
        syntax match FugitiveReflogSubject /.*/ contained

        highlight default link FugitiveReflogHash String
        highlight default link FugitiveReflogSelector Directory
      ]])

      -- Load fugitive's default mappings
      vim.cmd('runtime! ftplugin/git.vim ftplugin/git_*.vim after/ftplugin/git.vim')

      -- Keymaps

      -- d: Diffview
      vim.keymap.set('n', 'd', function()
        local commit = utils.get_commit(ev.buf)
        if not commit or commit == '' then
          commit = vim.api.nvim_get_current_line():match('^(%x+)')
        end
        if not commit then
          return
        end

        local filepath = utils.get_filepath_at_cursor(ev.buf)

        vim.schedule(function()
          if filepath then
            vim.cmd('DiffviewOpen ' .. commit .. '^..' .. commit .. ' --selected-file=' .. filepath)
          else
            vim.cmd('DiffviewOpen ' .. commit .. '^..' .. commit)
          end
        end)
      end, { buffer = ev.buf, nowait = true, silent = true, desc = 'Diffview commit' })

      -- C: Show commit info
      vim.keymap.set('n', 'C', function()
        local commit = utils.get_commit(ev.buf)
        if not commit or commit == '' then
          commit = vim.api.nvim_get_current_line():match('^(%x+)')
        end
        if not commit then
          print('No commit found')
          return
        end

        commands.show_commit_info_float(commit, true, true)
      end, { buffer = ev.buf, nowait = true, silent = true, desc = 'Show commit info in float window' })

      -- Ctrl-y: Copy commit hash
      vim.keymap.set('n', '<C-y>', function()
        local commit = utils.get_commit(ev.buf)
        if not commit or commit == '' then
          commit = vim.api.nvim_get_current_line():match('^(%x+)')
        end
        if not commit then
          print('No commit found')
          return
        end
        local short_commit = commit:sub(1, 7)
        vim.fn.setreg('+', short_commit)
        vim.fn.setreg('"', short_commit)
        print('Copied: ' .. short_commit)
      end, { buffer = ev.buf, nowait = true, silent = true })

      -- <space>p: Toggle preview
      vim.keymap.set('n', '<C-p>', function()
        local commit = vim.api.nvim_get_current_line():match('^(%x+)')
        commands.toggle_preview(commit)
      end, { buffer = ev.buf, silent = true, desc = "Toggle commit preview" })

      -- Update preview on cursor move (debounced)
      vim.api.nvim_create_autocmd('CursorMoved', {
        buffer = ev.buf,
        callback = function()
          if commands.is_preview_open() then
            local commit = vim.api.nvim_get_current_line():match('^(%x+)')
            commands.schedule_update_preview(commit)
          end
        end
      })

      -- Close preview on buffer unload
      vim.api.nvim_create_autocmd('BufUnload', {
          buffer = ev.buf,
          callback = function()
              commands.close_preview()
          end
      })

      -- q: Close window
      vim.keymap.set('n', 'q', function()
        commands.close_commit_info_float()
        require"utilities".smart_close()
      end, { buffer = ev.buf, nowait = true, silent = true })

      -- <Leader>R: reset --mixed
      vim.keymap.set('n', '<Leader>R', function()
        local commit = vim.api.nvim_get_current_line():match('^(%x+)')
        if not commit or commit == '' then
          vim.notify('No commit found', vim.log.levels.WARN)
          return
        end
        local confirm = vim.fn.confirm('git reset --mixed ' .. commit .. '?', '&Yes\n&No', 2)
        if confirm == 1 then
          vim.cmd('G reset --mixed ' .. commit)
        end
      end, { buffer = ev.buf, nowait = true, silent = true, desc = 'git reset --mixed to commit' })

      -- R: Reload
      vim.keymap.set('n', 'R', function()
        refresh_reflog_list(ev.buf)
      end, { buffer = ev.buf, silent = true, desc = "Reload reflog" })

      -- <CR>: fugitive:O
      vim.keymap.set('n', '<CR>', '<Plug>fugitive:O', { buffer = ev.buf, silent = true })

      -- Clean up float window on unload
      vim.api.nvim_create_autocmd('BufUnload', {
        buffer = ev.buf,
        callback = function()
          commands.close_commit_info_float()
        end,
      })
    end,
  })
end

return M

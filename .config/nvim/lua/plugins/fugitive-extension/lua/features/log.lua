local M = {}
local utils = require("fugitive_utils")
local commands = require("features.commands")

local function get_commit_at_line(bufnr, lnum)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  if not line then return nil end
  return line:match("^([^\t]+)")
end

local function apply_highlights(bufnr)
  local ns_id = vim.api.nvim_create_namespace('fugitivelog_highlight')
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local is_pushed = false

  for i, line in ipairs(lines) do
    -- タブ区切り: hash <tab> subject <tab> refs
    local hash, subject, refs = line:match("^([^\t]+)\t([^\t]*)\t(.*)$")

    -- マッチしない場合はスキップ（あるいは空文字で処理）
    if hash then
      if refs and (refs:match("origin/") or refs:match("remotes/")) then
        is_pushed = true
      end

      local hl_group = is_pushed and "Directory" or "GitSignsChangeDelete"

      vim.api.nvim_buf_set_extmark(bufnr, ns_id, i - 1, 0, {
        end_col = #hash,
        hl_group = hl_group,
      })
    end
  end
end

local function get_log_list()
  local cmd = "git log --pretty=format:'%h%x09%s%x09%d' --abbrev-commit -n 1000"
  return vim.fn.systemlist(cmd)
end

local function refresh_log_list(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.api.nvim_set_option_value('modifiable', true, { buf = bufnr })

  local log_output = get_log_list()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, log_output)

  vim.api.nvim_set_option_value('modifiable', false, { buf = bufnr })

  apply_highlights(bufnr)
end

local function open_log_list()
  -- %d (ref names) を取得して未プッシュ判定に使用する
  -- タブ区切り: hash <tab> subject <tab> refs
  local cmd = "log --pretty=format:'%h%x09%s%x09%d' --abbrev-commit -n 1000"
  vim.cmd('Git ' .. cmd)

  local bufnr = vim.api.nvim_get_current_buf()

  vim.bo[bufnr].filetype = 'fugitivelog'
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = bufnr })
  vim.api.nvim_set_option_value('swapfile', false, { buf = bufnr })
  vim.opt_local.list = false

  apply_highlights(bufnr)
end

function M.setup(group)
  vim.api.nvim_create_user_command('FugitiveLog', open_log_list, {
    bang = false,
    desc = "Open git log list",
  })

  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'fugitive',
    callback = function(ev)
      vim.keymap.set('n', 'L', function()
        vim.cmd('FugitiveLog')
      end, { buffer = ev.buf, silent = true, desc = "Open git log" })
    end
  })

  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'fugitivelog',
    callback = function(ev)
      -- Syntax highlighting
      vim.opt_local.conceallevel = 0
      vim.opt_local.list = false
      vim.cmd([[
        syntax match FugitiveLogHash /^[^\t]\+/
        syntax match FugitiveLogSubject /\t[^\t]*/
        syntax match FugitiveLogRefs /\t[^\t]*$/
        highlight default link FugitiveLogRefs Comment
      ]])

      apply_highlights(ev.buf)

      -- Re-apply highlights on reload
      vim.api.nvim_create_autocmd('BufReadPost', {
        buffer = ev.buf,
        callback = function()
          apply_highlights(ev.buf)
        end
      })

      -- Load fugitive's default mappings
      vim.cmd('runtime! ftplugin/git.vim ftplugin/git_*.vim after/ftplugin/git.vim')

      -- Keymaps (Inherited functionality)

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
      end, { buffer = ev.buf, nowait = true, silent = true })

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

        commands.show_commit_info_float(commit, true)
      end, { buffer = ev.buf, nowait = true, silent = true, desc = 'Show commit info in float window' })

      -- O: Octo PR
      vim.keymap.set('n', 'O', function()
        local commit = utils.get_commit(ev.buf)
        if not commit or commit == '' then
          commit = vim.api.nvim_get_current_line():match('^(%x+)')
        end
        if not commit then
          return
        end
        vim.cmd('OctoPrFromSha ' .. commit)
      end, { buffer = ev.buf, nowait = true, silent = true })

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

      -- <Leader>cf: Fixup commit
      vim.keymap.set('n', '<Leader>cf', function()
        local commit = utils.get_commit(ev.buf)
        if not commit or commit == '' then
          commit = vim.api.nvim_get_current_line():match('^(%x+)')
        end
        if not commit then
          vim.notify('No commit found at cursor', vim.log.levels.WARN)
          return
        end
        commands.fixup_commit(commit, function()
          refresh_log_list(ev.buf)
        end)
      end, { buffer = ev.buf, nowait = true, silent = true, desc = 'Fixup commit under cursor into its parent' })

      -- <M-j>: Move commit down
      vim.keymap.set('n', '<M-j>', function()
        local lnum = vim.fn.line('.')
        local commit = get_commit_at_line(ev.buf, lnum)
        local next_commit = get_commit_at_line(ev.buf, lnum + 1)
        if commit and next_commit then
          commands.move_commit(commit, next_commit, 'down', function()
            refresh_log_list(ev.buf)
          end)
        end
      end, { buffer = ev.buf, silent = true, desc = "Move commit down" })

      -- <M-k>: Move commit up
      vim.keymap.set('n', '<M-k>', function()
        local lnum = vim.fn.line('.')
        local commit = get_commit_at_line(ev.buf, lnum)
        local prev_commit = get_commit_at_line(ev.buf, lnum - 1)
        if commit and prev_commit then
          commands.move_commit(commit, prev_commit, 'up', function()
            refresh_log_list(ev.buf)
          end)
        end
      end, { buffer = ev.buf, silent = true, desc = "Move commit up" })

      -- X: Drop commit(s)
      vim.keymap.set({'n', 'v'}, 'X', function()
        local mode = vim.fn.mode()
        local commits = {}

        if mode == 'v' or mode == 'V' or mode == '\22' then
          -- Visual mode - get commits from each selected line
          local saved_cursor = vim.api.nvim_win_get_cursor(0)
          local start_pos = vim.fn.getpos('v')
          local end_pos = vim.fn.getpos('.')
          local start_line = math.min(start_pos[2], end_pos[2])
          local end_line = math.max(start_pos[2], end_pos[2])

          -- Exit visual mode first
          vim.cmd('normal! \27')

          -- Get hash for each line in selection
          for line = start_line, end_line do
            local commit = get_commit_at_line(ev.buf, line)
            if commit and commit ~= '' and not vim.tbl_contains(commits, commit) then
              table.insert(commits, commit)
            end
          end

          -- Restore cursor
          vim.api.nvim_win_set_cursor(0, saved_cursor)
        else
          -- Normal mode - get current commit
          local commit = get_commit_at_line(ev.buf, vim.fn.line('.'))
          if commit then table.insert(commits, commit) end
        end

        if #commits == 0 then
          vim.notify('No commits found', vim.log.levels.WARN)
          return
        end

        -- Confirm drop
        local commit_str = #commits > 1
          and string.format('%s ... %s (%d commits)', commits[1]:sub(1,7), commits[#commits]:sub(1,7), #commits)
          or commits[1]:sub(1,7)
        local confirm = vim.fn.confirm(
          string.format('Drop %d commit(s)?\n%s', #commits, commit_str),
          '&Yes\n&No',
          2
        )

        if confirm ~= 1 then
          return
        end

        -- Execute git rebase to drop commits
        -- Get current branch name
        local current_branch = vim.fn.system('git rev-parse --abbrev-ref HEAD'):gsub('\n', '')

        if current_branch == 'HEAD' then
          vim.notify('Cannot drop commits in detached HEAD state', vim.log.levels.ERROR)
          return
        end

        local cmd
        if #commits == 1 then
          cmd = string.format('git rebase --onto %s^ %s %s', commits[1], commits[1], current_branch)
        else
          -- For multiple commits: rebase onto the commit before first, skipping up to last
          cmd = string.format('git rebase --onto %s^ %s %s', commits[#commits], commits[1], current_branch)
        end

        vim.notify('Executing: ' .. cmd, vim.log.levels.INFO)
        vim.notify('Dropping commits: ' .. commit_str, vim.log.levels.INFO)

        local output = vim.fn.system(cmd)
        if vim.v.shell_error ~= 0 then
          vim.notify('Failed to drop commits:\n' .. output, vim.log.levels.ERROR)
        else
          vim.notify('Successfully dropped commits', vim.log.levels.INFO)
          -- Reload log
          vim.schedule(function()
            refresh_log_list(ev.buf)
          end)
        end
      end, { buffer = ev.buf, silent = true, desc = "Drop commit(s)" })

      -- <C-Space>: Flogウィンドウトグル
      vim.keymap.set('n', '<C-Space>', function()
        if vim.g.flog_win and vim.api.nvim_win_is_valid(vim.g.flog_win) then
          vim.api.nvim_win_close(vim.g.flog_win, false)
          vim.g.flog_win = nil
          vim.g.flog_bufnr = nil
        else
          local current_win = vim.api.nvim_get_current_win()
          vim.cmd("Flogsplit -open-cmd=vertical\\ rightbelow\\ 60vsplit")
          vim.g.flog_bufnr = vim.api.nvim_get_current_buf()
          vim.g.flog_win = vim.api.nvim_get_current_win()

          utils.setup_flog_window(vim.g.flog_win, vim.g.flog_bufnr)

          -- Initial highlight
          local commit = vim.api.nvim_get_current_line():match('^(%x+)')
          if commit then
             utils.highlight_flog_commit(vim.g.flog_bufnr, vim.g.flog_win, commit)
          end

          vim.api.nvim_set_current_win(current_win)
        end
      end, { buffer = ev.buf, nowait = true, silent = true, desc = 'Toggle Flog window' })

      -- Update Flog highlight on cursor move
      vim.api.nvim_create_autocmd('CursorMoved', {
        buffer = ev.buf,
        callback = function()
          if vim.g.flog_win and vim.api.nvim_win_is_valid(vim.g.flog_win) then
             local commit = vim.api.nvim_get_current_line():match('^(%x+)')
             if commit then
                utils.highlight_flog_commit(vim.g.flog_bufnr, vim.g.flog_win, commit)
             end
          end
        end,
      })

      -- q: Close window
      vim.keymap.set('n', 'q', function()
        if vim.g.flog_win and vim.api.nvim_win_is_valid(vim.g.flog_win) then
          vim.api.nvim_win_close(vim.g.flog_win, false)
          vim.g.flog_win = nil
          vim.g.flog_bufnr = nil
        end
        commands.close_commit_info_float()
        require"utilities".smart_close()
      end, { buffer = ev.buf, nowait = true, silent = true })

      -- R: Reload
      vim.keymap.set('n', 'R', function() commands.reload_log() end, { buffer = ev.buf, silent = true, desc = "Reload log" })

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

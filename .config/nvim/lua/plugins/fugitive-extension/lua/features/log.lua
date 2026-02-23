local M = {}
local utils = require("fugitive_utils")
local commands = require("features.commands")
local help = require("features.help")

local function get_commit_at_line(bufnr, lnum)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  if not line then return nil end
  return line:match("^([^\t]+)")
end

local function apply_highlights(bufnr)
  local ns_id = vim.api.nvim_create_namespace('fugitivelog_highlight')
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Get list of unpushed/diverged commit hashes
  local args = vim.b[bufnr].fugitive_log_args or "HEAD"
  if args == "" then args = "HEAD" end
  local target = vim.fn.trim(args)

  local current_branch = vim.fn.system("git rev-parse --abbrev-ref HEAD"):gsub("\n", "")
  local diverged_commits = {}
  local unpushed_commits = {}
  local cmd_diverged = nil
  local cmd_unpushed = nil

  if target == "HEAD" or target == current_branch then
    -- If viewing current branch, compare against upstream for unpushed (Red)
    local upstream = vim.fn.system("git rev-parse --abbrev-ref " .. target .. "@{u} 2>/dev/null"):gsub("\n", "")
    if vim.v.shell_error == 0 and upstream ~= "" then
      cmd_unpushed = "git log " .. target .. " --not " .. upstream .. " --format='%h'"
    end
  else
    -- If viewing another branch:
    -- 1. Compare against HEAD (current branch) for diverged (Orange)
    cmd_diverged = "git log " .. target .. " --not HEAD --format='%h'"

    -- 2. Compare against its own upstream for unpushed (Red)
    -- This handles the case where we view a branch that has unpushed commits relative to ITS upstream
    local upstream = vim.fn.system("git rev-parse --abbrev-ref " .. target .. "@{u} 2>/dev/null"):gsub("\n", "")
    if vim.v.shell_error == 0 and upstream ~= "" then
      cmd_unpushed = "git log " .. target .. " --not " .. upstream .. " --format='%h'"
    end
  end

  if cmd_diverged then
    local output = vim.fn.systemlist(cmd_diverged)
    for _, hash in ipairs(output) do
      diverged_commits[hash] = true
    end
  end

  if cmd_unpushed then
    local output = vim.fn.systemlist(cmd_unpushed)
    for _, hash in ipairs(output) do
      unpushed_commits[hash] = true
    end
  end

  for i, line in ipairs(lines) do
    -- タブ区切り: hash <tab> date <tab> subject <tab> author <tab> refs
    local hash = line:match("^([^\t]+)")

    if hash then
      local hl_group = "String" -- Default string-ish

      if unpushed_commits[hash] then
        hl_group = "@text.danger" -- Red for unpushed
      elseif diverged_commits[hash] then
        hl_group = "Constant" -- Orange for diverged (but pushed)
      end

      vim.api.nvim_buf_set_extmark(bufnr, ns_id, i - 1, 0, {
        end_col = #hash,
        hl_group = hl_group,
      })
    end
  end
end

local function apply_log_syntax(bufnr)
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd([[
      syntax clear
      syntax match FugitiveLogHash /^[^\t]\+/ nextgroup=FugitiveLogSep1
      syntax match FugitiveLogSep1 /\t/ contained nextgroup=FugitiveLogDate
      syntax match FugitiveLogDate /[^\t]\+/ contained nextgroup=FugitiveLogSep2
      syntax match FugitiveLogSep2 /\t/ contained nextgroup=FugitiveLogSubject
      syntax match FugitiveLogSubject /[^\t]\+/ contained nextgroup=FugitiveLogSep3
      syntax match FugitiveLogSep3 /\t/ contained nextgroup=FugitiveLogAuthor
      syntax match FugitiveLogAuthor /[^\t]\+/ contained nextgroup=FugitiveLogSep4
      syntax match FugitiveLogSep4 /\t/ contained nextgroup=FugitiveLogRefs
      syntax match FugitiveLogRefs /.*/ contained

      highlight default link FugitiveLogDate Directory
      highlight default link FugitiveLogAuthor Type
      highlight default link FugitiveLogRefs Comment
    ]])
  end)
end

local function get_log_list(bufnr)
  local args = ""
  if bufnr then
    args = vim.b[bufnr].fugitive_log_args or ""
  end
  local cmd = "git log --pretty=format:'%h%x09%as%x09%s%x09%an%x09%d' --abbrev-commit -n 1000 " .. args
  return vim.fn.systemlist(cmd)
end

local function refresh_log_list(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.api.nvim_set_option_value('modifiable', true, { buf = bufnr })

  local log_output = get_log_list(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, log_output)

  vim.api.nvim_set_option_value('modifiable', false, { buf = bufnr })

  apply_highlights(bufnr)
  apply_log_syntax(bufnr)
end

local function open_log_list(opts)
  -- %d (ref names) を取得して未プッシュ判定に使用する
  -- タブ区切り: hash <tab> date <tab> subject <tab> author <tab> refs
  local args = opts and opts.args or ""
  local cmd = "log --pretty=format:'%h%x09%as%x09%s%x09%an%x09%d' --abbrev-commit -n 1000 " .. args
  vim.cmd('Git ' .. cmd)

  local bufnr = vim.api.nvim_get_current_buf()

  vim.bo[bufnr].filetype = 'fugitivelog'
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = bufnr })
  vim.api.nvim_set_option_value('swapfile', false, { buf = bufnr })
  vim.opt_local.list = false

  vim.b[bufnr].fugitive_log_args = args

  apply_highlights(bufnr)
end

local function show_log_help()
  help.show('Log buffer keys', {
    'g?          show this help',
    'd           Diffview commit (or file if detected)',
    'C           commit info float',
    'O           Octo PR from commit',
    '<C-y>       copy short hash',
    '<Leader>cf  fixup commit into parent',
    'cf          fixup/reword commit with index',
    '<M-j>/<M-k> move commit down/up',
    'X (n/V)     drop commit(s)',
    'cw          reword commit',
    '<C-p>       toggle commit preview',
    '<Leader>R   reset --mixed to commit',
  })
end

function M.setup(group)
  vim.api.nvim_create_user_command('FugitiveLog', open_log_list, {
    bang = false,
    nargs = '*',
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
      local buf_group = vim.api.nvim_create_augroup('fugitive_log_buf_' .. ev.buf, { clear = true })
      -- Syntax highlighting
      vim.opt_local.conceallevel = 0
      vim.opt_local.list = false
      vim.opt_local.tabstop = 1

      vim.keymap.set('n', 'g?', function()
        show_log_help()
      end, { buffer = ev.buf, silent = true, desc = "Help" })
      apply_log_syntax(ev.buf)
      apply_highlights(ev.buf)

      -- Re-apply highlights on reload
      vim.api.nvim_create_autocmd('BufReadPost', {
        buffer = ev.buf,
        group = buf_group,
        callback = function()
          apply_highlights(ev.buf)
          apply_log_syntax(ev.buf)
        end
      })

      -- Auto-refresh on specific events (FugitiveChanged)
      vim.api.nvim_create_autocmd('User', {
        pattern = 'FugitiveChanged',
        group = buf_group,
        callback = function()
          if vim.api.nvim_buf_is_valid(ev.buf) then
            refresh_log_list(ev.buf)
          end
        end,
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

        commands.show_commit_info_float(commit, true, true)
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
      vim.keymap.set({'n', 'x'}, '<C-y>', function()
        local mode = vim.fn.mode()
        if mode == 'v' or mode == 'V' or mode == '\22' then
          -- Visual mode logic
          local _, csrow, _, _ = unpack(vim.fn.getpos("."))
          local _, ssrow, _, _ = unpack(vim.fn.getpos("v"))
          local start_line = math.min(csrow, ssrow)
          local end_line = math.max(csrow, ssrow)

          local lines = vim.api.nvim_buf_get_lines(ev.buf, start_line - 1, end_line, false)
          local hashes = {}
          for _, line in ipairs(lines) do
            local commit = line:match('^(%x+)')
            if commit then
              table.insert(hashes, commit:sub(1, 7))
            end
          end

          if #hashes == 0 then
            vim.notify('No commits found in selection', vim.log.levels.WARN)
            return
          end

          -- Join with newline for commands.lua compatibility
          local joined = table.concat(hashes, '\n')
          vim.fn.setreg('+', joined)
          vim.fn.setreg('"', joined)
          print('Copied ' .. #hashes .. ' commits')

          -- Exit visual mode
          vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', false)
        else
          -- Normal mode logic
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
        end
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

      -- cf: Fixup/Reword commit with index
      vim.keymap.set('n', 'cf', function()
        local commit = utils.get_commit(ev.buf)
        if not commit or commit == '' then
          commit = vim.api.nvim_get_current_line():match('^(%x+)')
        end
        if not commit then
          vim.notify('No commit found', vim.log.levels.WARN)
          return
        end
        commands.mix_index_with_input(commit)
      end, { buffer = ev.buf, nowait = true, silent = true, desc = 'Fixup/Reword commit under cursor with index' })

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

        commands.drop_commits(commits, function()
          refresh_log_list(ev.buf)
        end)
      end, { buffer = ev.buf, silent = true, desc = "Drop commit(s)" })

      -- cw: Reword commit
      vim.keymap.set('n', 'cw', function()
        local commit = utils.get_commit(ev.buf)
        if not commit or commit == '' then
          commit = vim.api.nvim_get_current_line():match('^(%x+)')
        end
        if not commit then
          vim.notify('No commit found', vim.log.levels.WARN)
          return
        end

        -- Get current subject for default value
        local line = vim.api.nvim_get_current_line()
        -- Hash <tab> Date <tab> Subject <tab> ...
        local subject = line:match("^[^\t]+\t[^\t]+\t([^\t]*)") or ""

        vim.ui.input({ prompt = 'New commit message: ', default = subject }, function(input)
          if input and input ~= subject then
            commands.reword_commit(commit, input, function()
              refresh_log_list(ev.buf)
            end)
          end
        end)
      end, { buffer = ev.buf, silent = true, desc = "Reword commit" })

      -- <C-p>: Toggle preview
      vim.keymap.set('n', '<C-p>', function()
        local commit = get_commit_at_line(ev.buf, vim.fn.line('.'))
        commands.toggle_preview(commit)
      end, { buffer = ev.buf, silent = true, desc = "Toggle commit preview" })

      -- Update preview on cursor move (debounced)
      vim.api.nvim_create_autocmd('CursorMoved', {
        buffer = ev.buf,
        group = buf_group,
        callback = function()
          if commands.is_preview_open() then
            local commit = get_commit_at_line(ev.buf, vim.fn.line('.'))
            commands.schedule_update_preview(commit)
          end
        end
      })

      -- Close preview on buffer unload
      vim.api.nvim_create_autocmd('BufUnload', {
          buffer = ev.buf,
          group = buf_group,
          callback = function()
              commands.close_preview()
          end
      })

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
        group = buf_group,
        callback = function()
          if vim.g.flog_win and vim.api.nvim_win_is_valid(vim.g.flog_win) then
             local commit = vim.api.nvim_get_current_line():match('^(%x+)')
             if commit then
                utils.highlight_flog_commit(vim.g.flog_bufnr, vim.g.flog_win, commit)
                -- Update commit info float only if it already exists (no creation)
                commands.show_commit_info_float(commit, false, false)
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

      -- <Leader>R: reset --mixed
      vim.keymap.set('n', '<Leader>R', function()
        local commit = get_commit_at_line(ev.buf, vim.fn.line('.'))
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
        refresh_log_list(ev.buf)
        vim.notify("Log refreshed", vim.log.levels.INFO)
      end, { buffer = ev.buf, silent = true, desc = "Reload log" })

      -- <CR>: Open commit in new tab
      vim.keymap.set('n', '<CR>', function()
        local commit = get_commit_at_line(ev.buf, vim.fn.line('.'))
        if commit then
          vim.cmd('tab Git show ' .. commit)
        end
      end, { buffer = ev.buf, silent = true, desc = "Open commit in tab" })

      -- Clean up float window on unload
      vim.api.nvim_create_autocmd('BufUnload', {
        buffer = ev.buf,
        group = buf_group,
        callback = function()
          commands.close_commit_info_float()
          pcall(vim.api.nvim_del_augroup_by_id, buf_group)
        end,
      })
    end,
  })
end

return M

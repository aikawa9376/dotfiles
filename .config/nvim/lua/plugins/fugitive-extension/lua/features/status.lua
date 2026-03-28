local M = {}
local utils = require("fugitive_utils")
local commands = require("features.commands")

-- Helper: Get the repository top-level path (work tree) from Fugitive's git dir.
local function get_fugitive_work_tree()
  local git_dir = vim.fn.FugitiveGitDir()
  if git_dir == '' then
    return nil
  end
  local work_tree_cmd = 'git --git-dir=' .. vim.fn.shellescape(git_dir) .. ' rev-parse --show-toplevel'
  local work_tree = vim.fn.trim(vim.fn.system(work_tree_cmd))
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return work_tree
end

-- Return `git stash list` for the current repo as a table of lines.
local function get_stash_list()
  local work_tree = get_fugitive_work_tree()
  if not work_tree then
    return {}
  end
  local stash_output = vim.fn.systemlist('git -C ' .. vim.fn.shellescape(work_tree) .. ' stash list')
  if vim.v.shell_error ~= 0 then
    return {}
  end
  return stash_output
end

-- Extract a stash ref like "stash@{0}" from a line. Returns nil if none found.
local function stash_ref_from_line(line)
  if not line then return nil end
  return line:match('stash@%{%d+%}')
end

-- Find and remove all custom sections (Worktrees and Stashes) from the buffer.
local function remove_custom_sections(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local ranges = {}
  local i = 1
  while i <= #lines do
    local line = lines[i]
    if line:match('^Worktrees:') or line:match('^Stashes:') then
      local start_idx = i
      -- Include one blank line above the header if it exists
      if start_idx > 1 and lines[start_idx - 1] == '' then
        start_idx = start_idx - 1
      end

      i = i + 1
      -- Collect all following lines that belong to this section or are trailing blanks
      while i <= #lines do
        local l = lines[i]
        if l == '' then
          i = i + 1
        elseif line:match('^Worktrees:') and l:match('^[%~%/]') then
          i = i + 1
        elseif line:match('^Stashes:') and l:match('^%s+stash@') then
          i = i + 1
        else
          break
        end
      end
      table.insert(ranges, { start_idx, i - 1 })
    else
      i = i + 1
    end
  end

  -- Delete ranges in reverse order to keep indices valid
  for r = #ranges, 1, -1 do
    vim.api.nvim_buf_set_lines(bufnr, ranges[r][1] - 1, ranges[r][2], false, {})
  end
end

-- Find the insertion point (after the last non-empty line) for the dynamic blocks.
local function find_insert_point(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i = #lines, 1, -1 do
    local l = lines[i]
    if l and l ~= '' then
      return i + 1
    end
  end
  return #lines + 1
end

-- Main function to refresh all custom sections (Worktree summary and Stashes)
local function refresh_status_sections(bufnr, ns_worktree, ns_stash)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end

  local work_tree = get_fugitive_work_tree()
  if not work_tree then return end

  -- Data collection
  local worktree_mod = require("features.worktree")
  local worktree_summary = worktree_mod.get_summary(work_tree)
  local stash_list = get_stash_list()

  -- Buffer flags
  local prev_modifiable = vim.bo[bufnr].modifiable
  local prev_readonly = vim.bo[bufnr].readonly
  if not prev_modifiable or prev_readonly then
    vim.bo[bufnr].modifiable = true
    vim.bo[bufnr].readonly = false
  end

  -- Step 1: Clean up existing ones
  remove_custom_sections(bufnr)

  -- Step 2: Build new block
  local final_lines = {}
  
  -- Add Worktrees if any
  if worktree_summary and #worktree_summary > 0 then
    table.insert(final_lines, '') -- Leading spacer
    for _, l in ipairs(worktree_summary) do table.insert(final_lines, l) end
  end

  -- Add Stashes if any
  if stash_list and #stash_list > 0 then
    table.insert(final_lines, '') -- Spacer before stash
    table.insert(final_lines, 'Stashes: (' .. #stash_list .. ')')
    for _, l in ipairs(stash_list) do table.insert(final_lines, l) end
  end

  -- Step 3: Insert at the bottom
  if #final_lines > 0 then
    local insert_idx = find_insert_point(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, insert_idx - 1, insert_idx - 1, false, final_lines)
  end

  -- Step 4: Highlighting
  vim.api.nvim_buf_clear_namespace(bufnr, ns_worktree, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_stash, 0, -1)
  
  local lines_after = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local in_worktree = false
  local in_stash = false
  local current_wt_abs = vim.fn.fnamemodify(work_tree, ':p')

  for i, l in ipairs(lines_after) do
    if l:match('^Worktrees:') then
      -- Use DiagnosticOk for a deeper green header
      vim.api.nvim_buf_set_extmark(bufnr, ns_worktree, i - 1, 0, { end_col = #l, hl_group = 'DiagnosticOk' })
      in_worktree = true
      in_stash = false
    elseif l:match('^Stashes:') then
      vim.api.nvim_buf_set_extmark(bufnr, ns_stash, i - 1, 0, { end_col = #l, hl_group = 'GitSignsChange' })
      in_worktree = false
      in_stash = true
    elseif in_worktree then
      -- Parse path from the beginning of line
      local path_part = l:match('^(%S+)')
      if path_part then
        local abs_p = vim.fn.fnamemodify(path_part, ':p'):gsub('/$', '')
        local target_abs = current_wt_abs:gsub('/$', '')
        if abs_p == target_abs then
          -- Highlight ONLY the current worktree name
          vim.api.nvim_buf_set_extmark(bufnr, ns_worktree, i - 1, 0, { end_col = #path_part, hl_group = 'GitSignsAdd' })
        end
      else
        in_worktree = false
      end
    elseif in_stash then
      if l:match('^%s+stash@') then
        vim.api.nvim_buf_set_extmark(bufnr, ns_stash, i - 1, 0, { end_col = #l, hl_group = 'GitSignsAdd' })
      else
        in_stash = false
      end
    end
  end

  if not prev_modifiable or prev_readonly then
    vim.bo[bufnr].modifiable = prev_modifiable
    vim.bo[bufnr].readonly = prev_readonly
  end
end

-- Convenience helper to find the stash ref at the cursor in specified buffer (e.g. "stash@{0}").
local function get_stash_ref_at_cursor(bufnr)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
  return stash_ref_from_line(line)
end

-- Return true if the cursor is currently on the Stashes header line or on one of the stash entry lines.
local function is_cursor_in_stash_area()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] -- 0-based

  -- If the cursor is on a stash entry line (e.g., "  stash@{0}: ...")
  if line:match('^%s*stash@%{%d+%}') then
    return true
  end

  -- If the cursor is on the header line "Stashes: N", consider stash area when the cursor
  -- is on or after the "Stashes:" text.
  local s, _ = line:find('Stashes:')
  if s then
    if (col + 1) >= s then
      return true
    end
  end

  return false
end

function M.setup(group)
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'fugitive',
    callback = function(ev)
      -- 行番号を非表示
      vim.opt_local.number = false
      vim.opt_local.relativenumber = false

      -- Section integration
      local ns_stash = vim.api.nvim_create_namespace('fugitive_status_stash')
      local ns_worktree = vim.api.nvim_create_namespace('fugitive_status_worktree')

      local function refresh()
        refresh_status_sections(ev.buf, ns_worktree, ns_stash)
      end

      -- Initial refresh
      refresh()

      -- Buffer-local autocmd to prevent accumulation
      local bufgroupt = vim.api.nvim_create_augroup('FugitiveStatusRefresh' .. ev.buf, { clear = true })
      vim.api.nvim_create_autocmd('BufEnter', {
        group = bufgroupt,
        buffer = ev.buf,
        callback = function() vim.schedule(refresh) end,
      })

      -- Stash-specific mappings that only act if the cursor is within the Stashes header or
      local map_A, map_P, map_X, map_O, map_CR

      map_A = function()
        if is_cursor_in_stash_area() then
          local ref = get_stash_ref_at_cursor(ev.buf)
          if not ref then vim.notify('No stash at cursor', vim.log.levels.WARN) return end
          vim.cmd('Git stash apply ' .. ref)
          vim.fn['fugitive#ReloadStatus']()
          vim.schedule(refresh)
          return
        end
        vim.api.nvim_feedkeys(
          vim.api.nvim_replace_termcodes("<Plug>fugitive:ce", true, false, true),
          'm',
          true
        )
      end
      vim.keymap.set('n', 'A', map_A, { buffer = ev.buf, nowait = true, silent = true, desc = 'Apply stash under cursor' })

      map_P = function()
        if is_cursor_in_stash_area() then
          local ref = get_stash_ref_at_cursor(ev.buf)
          if not ref then vim.notify('No stash at cursor', vim.log.levels.WARN) return end
          vim.cmd('Git stash pop ' .. ref)
          vim.fn['fugitive#ReloadStatus']()
          vim.schedule(refresh)
          return
        end
        vim.api.nvim_feedkeys(
          vim.api.nvim_replace_termcodes("<Plug>fugitive:P", true, false, true),
          'm',
          true
        )
      end
      vim.keymap.set('n', 'P', map_P, { buffer = ev.buf, nowait = true, silent = true, desc = 'Pop stash under cursor' })

      map_X = function()
        if is_cursor_in_stash_area() then
          local ref = get_stash_ref_at_cursor(ev.buf)
          if not ref then vim.notify('No stash at cursor', vim.log.levels.WARN) return end
          vim.cmd('Git stash drop ' .. ref)
          vim.fn['fugitive#ReloadStatus']()
          vim.schedule(refresh)
          return
        end
        vim.api.nvim_feedkeys(
          vim.api.nvim_replace_termcodes("<Plug>fugitive:X", true, false, true),
          'm',
          true
        )
      end
      vim.keymap.set('n', 'X', map_X, { buffer = ev.buf, nowait = true, silent = true, desc = 'Drop stash under cursor' })

      map_O = function()
        if is_cursor_in_stash_area() then
          local ref = get_stash_ref_at_cursor(ev.buf)
          if not ref then vim.notify('No stash at cursor', vim.log.levels.WARN) return end
          vim.cmd('tabnew')
          vim.cmd('Gedit ' .. ref)
          return
        end
        vim.api.nvim_feedkeys(
          vim.api.nvim_replace_termcodes("<Plug>fugitive:O", true, false, true),
          'm',
          true
        )
      end
      vim.keymap.set('n', 'O', map_O, { buffer = ev.buf, nowait = true, silent = true, desc = 'Open stash diff in new tab' })

      map_CR = function()
        if is_cursor_in_stash_area() then
          local ref = get_stash_ref_at_cursor(ev.buf)
          if not ref then vim.notify('No stash at cursor', vim.log.levels.WARN) return end
          vim.cmd('Gvsplit ' .. ref)
          return
        end
        local file_path = utils.get_filepath_at_cursor(ev.buf)
        if file_path then
          local work_tree = get_fugitive_work_tree()
          if work_tree then
            local abs_path = vim.fn.fnamemodify(work_tree .. '/' .. file_path, ':p')
            if vim.fn.isdirectory(abs_path) == 1 then
              pcall(vim.cmd, 'Oil ' .. vim.fn.fnameescape(abs_path))
              return
            end
          end
        end
        vim.api.nvim_feedkeys(
          vim.api.nvim_replace_termcodes("<Plug>fugitive:<cr>", true, false, true),
          'm',
          true
        )
      end
      vim.keymap.set('n', '<CR>', map_CR, { buffer = ev.buf, nowait = true, silent = true, desc = 'Open stash diff in split buffer' })

      vim.keymap.set('n', 'd', function()
        local file_path = utils.get_filepath_at_cursor(ev.buf)
        if not file_path then
          print('No file found')
          return
        end

        -- 現在のカーソル位置から上に遡って@@ 行を探す
        local target_line = nil
        local current_line = vim.api.nvim_win_get_cursor(0)[1]
        local hunk_line = nil

        for lnum = current_line, 1, -1 do
          local line = vim.api.nvim_buf_get_lines(ev.buf, lnum - 1, lnum, false)[1]
          if line then
            -- @@ -97,6 +97,8 @@ のような形式から行番号を抽出
            local line_num = line:match('^@@ %-(%d+)')
            if line_num then
              hunk_line = lnum
              target_line = tonumber(line_num)
              break
            end
            -- ファイル名の行に到達したら停止
            if line:match('^[MADRCU?!][MADRCU?!]? (.+)$') then
              break
            end
          end
        end

        -- @@行からの距離を計算して行番号を調整（-行は除外）
        if target_line and hunk_line then
          local offset = 0
          for lnum = hunk_line + 1, current_line do
            local line = vim.api.nvim_buf_get_lines(ev.buf, lnum - 1, lnum, false)[1]
            if line and not line:match('^%-') then
              offset = offset + 1
            end
          end
          target_line = target_line + offset - 1
        end

        local fugitive_path = vim.fn.FugitiveFind(':' .. file_path)
        vim.cmd('tabedit ' .. vim.fn.fnameescape(fugitive_path))

        vim.schedule(function()
          vim.cmd('Gvdiffsplit')

          -- @@ 行から計算した行番号にカーソルを移動
          if target_line then
            vim.schedule(function()
              local buf_line_count = vim.api.nvim_buf_line_count(0)
              target_line = math.min(target_line, buf_line_count)
              vim.api.nvim_win_set_cursor(0, { target_line, 0 })
              vim.cmd('normal! zz')
            end)
          end
        end)
      end, { buffer = ev.buf, nowait = true, silent = true, desc = 'Open file diff in new tab' })

      -- deviconsでファイル名に色とアイコンを付ける
      local ns_id = vim.api.nvim_create_namespace('fugitive_status_icons')
      vim.api.nvim_buf_clear_namespace(ev.buf, ns_id, 0, -1)

      -- Smart Continue/Skip/Abort for Rebase, Cherry-pick, Merge, Revert
      local function get_git_dir()
        return vim.fn.FugitiveGitDir()
      end

      local function perform_continue()
        local git_dir = get_git_dir()
        if not git_dir or git_dir == '' then return end

        if vim.fn.isdirectory(git_dir .. "/rebase-merge") == 1 or vim.fn.isdirectory(git_dir .. "/rebase-apply") == 1 then
          vim.cmd("Git rebase --continue")
        elseif vim.fn.filereadable(git_dir .. "/CHERRY_PICK_HEAD") == 1 then
          vim.cmd("Git cherry-pick --continue")
        elseif vim.fn.filereadable(git_dir .. "/MERGE_HEAD") == 1 then
          vim.cmd("Git merge --continue")
        elseif vim.fn.filereadable(git_dir .. "/REVERT_HEAD") == 1 then
          vim.cmd("Git revert --continue")
        else
          vim.notify("No rebase, cherry-pick, merge, or revert in progress.", vim.log.levels.WARN)
        end
      end

      local function perform_skip()
        local git_dir = get_git_dir()
        if not git_dir or git_dir == '' then return end

        if vim.fn.isdirectory(git_dir .. "/rebase-merge") == 1 or vim.fn.isdirectory(git_dir .. "/rebase-apply") == 1 then
          vim.cmd("Git rebase --skip")
        elseif vim.fn.filereadable(git_dir .. "/CHERRY_PICK_HEAD") == 1 then
          vim.cmd("Git cherry-pick --skip")
        elseif vim.fn.filereadable(git_dir .. "/REVERT_HEAD") == 1 then
          vim.cmd("Git revert --skip")
        else
          vim.notify("Skip not applicable.", vim.log.levels.WARN)
        end
      end

      local function perform_abort()
        local git_dir = get_git_dir()
        if not git_dir or git_dir == '' then return end

        if vim.fn.isdirectory(git_dir .. "/rebase-merge") == 1 or vim.fn.isdirectory(git_dir .. "/rebase-apply") == 1 then
          vim.cmd("Git rebase --abort")
        elseif vim.fn.filereadable(git_dir .. "/CHERRY_PICK_HEAD") == 1 then
          vim.cmd("Git cherry-pick --abort")
        elseif vim.fn.filereadable(git_dir .. "/MERGE_HEAD") == 1 then
          vim.cmd("Git merge --abort")
        elseif vim.fn.filereadable(git_dir .. "/REVERT_HEAD") == 1 then
          vim.cmd("Git revert --abort")
        else
          vim.notify("No operation to abort.", vim.log.levels.WARN)
        end
      end

      vim.keymap.set('n', 'rr', perform_continue, { buffer = ev.buf, silent = true, desc = "Continue rebase/cherry-pick/merge" })
      vim.keymap.set('n', 'rs', perform_skip, { buffer = ev.buf, silent = true, desc = "Skip commit in rebase/cherry-pick" })
      vim.keymap.set('n', 'ra', perform_abort, { buffer = ev.buf, silent = true, desc = "Abort rebase/cherry-pick/merge" })

      -- Enable syntax highlighting for diffs
      require('features.syntax_highlight').attach(ev.buf)

      local lines = vim.api.nvim_buf_get_lines(ev.buf, 0, -1, false)
      for idx, line in ipairs(lines) do
        -- "Staged"という文字列を緑色にする
        if line:match('^Staged') then
          vim.api.nvim_buf_set_extmark(ev.buf, ns_id, idx - 1, 0, {
            end_col = 6,
            hl_group = 'GitSignsAdd',
          })
        -- "Unpulled"という文字列をオレンジ色にする
        elseif line:match('^Unpulled') then
          vim.api.nvim_buf_set_extmark(ev.buf, ns_id, idx - 1, 0, {
            end_col = 8,
            hl_group = 'GitSignsChange',
          })
        -- "Untracked"という文字列をオレンジ色にする
        elseif line:match('^Untracked') then
          vim.api.nvim_buf_set_extmark(ev.buf, ns_id, idx - 1, 0, {
            end_col = 9,
            hl_group = 'GitSignsDelete',
          })
        end

        local filepath = line:match('^[MADRCU?!][MADRCU?!]? (.+)$')
        if filepath then
          local status = line:sub(1, 1)

          if status == 'A' then
            vim.api.nvim_buf_set_extmark(ev.buf, ns_id, idx - 1, 0, { end_col = 1, hl_group = 'GitSignsAdd' })
          elseif status == 'D' then
            vim.api.nvim_buf_set_extmark(ev.buf, ns_id, idx - 1, 0, { end_col = 1, hl_group = 'GitSignsDelete' })
          end

          local icon, icon_hl = utils.get_devicon(filepath)
          -- ファイル名全体に色を適用
          local filename_start = line:find(filepath, 1, true)
            if filename_start then
              vim.api.nvim_buf_set_extmark(ev.buf, ns_id, idx - 1, filename_start - 1, {
                end_col = filename_start - 1 + #filepath,
                hl_group = icon_hl,
              })
              -- virtual textでアイコンをファイル名の直前に表示
              vim.api.nvim_buf_set_extmark(ev.buf, ns_id, idx - 1, filename_start - 1, {
                virt_text = { { icon .. ' ', icon_hl } },
                virt_text_pos = 'inline',
              })
            end
          end
      end

      -- Flog integration
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
          vim.api.nvim_set_current_win(current_win)
        end
      end, { buffer = ev.buf, nowait = true, silent = true, desc = 'Toggle Flog window' })

      -- カーソル行のコミットを一つ前のコミットにfixupする (Leader cf)
      vim.keymap.set('n', '<Leader>cf', function()
        local current_line = vim.api.nvim_get_current_line()
        local commit_hash = current_line:match('^(%x+)')
        if not commit_hash then
          vim.notify('No commit found at cursor', vim.log.levels.WARN)
          return
        end
        commands.fixup_commit(commit_hash)
      end, { buffer = ev.buf, nowait = true, silent = true, desc = 'Squash commit under cursor into its parent' })

      -- 現在のインデックスをカーソル行のコミットに混ぜる (cf)
      vim.keymap.set('n', 'cf', function()
        local current_line = vim.api.nvim_get_current_line()
        local commit_hash = current_line:match('^(%x+)')

        if not commit_hash then
          vim.notify('No commit found at cursor', vim.log.levels.WARN)
          return
        end
        commands.mix_index_with_input(commit_hash)
      end, { buffer = ev.buf, nowait = true, silent = true, desc = 'Fixup/Reword commit under cursor with index' })

      -- gr: Revert commit under cursor
      vim.keymap.set('n', 'gr', function()
        local current_line = vim.api.nvim_get_current_line()
        local commit_hash = current_line:match('^(%x+)')
        if not commit_hash then
          vim.notify('No commit found at cursor', vim.log.levels.WARN)
          return
        end
        local confirm = vim.fn.confirm('Revert ' .. commit_hash:sub(1, 7) .. '?', '&Yes\n&No', 2)
        if confirm ~= 1 then return end
        commands.revert_commits({ commit_hash })
      end, { buffer = ev.buf, nowait = true, silent = true, desc = 'Revert commit under cursor' })

      vim.keymap.set('n', 'q', function()
        if vim.g.flog_win and vim.api.nvim_win_is_valid(vim.g.flog_win) then
          vim.api.nvim_win_close(vim.g.flog_win, true)
        end
        require"utilities".smart_close()
      end, { buffer = ev.buf, nowait = true, silent = true, desc = 'Close status and Flog window' })

      -- all close
      vim.keymap.set('n', 'R', function()
        vim.cmd('e!')
        vim.cmd('normal gU')
      end, { buffer = ev.buf, silent = true })

      -- <Leader>wd: Toggle word diff style
      vim.keymap.set('n', '<Leader>wd', function()
        local sh = require('features.syntax_highlight')
        local new_style = sh.config.word_diff_style == 'github' and 'lazygit' or 'github'
        sh.config.word_diff_style = new_style
        vim.notify('Word diff style: ' .. new_style, vim.log.levels.INFO)
      end, { buffer = ev.buf, silent = true, desc = 'Toggle word diff style (lazygit/github)' })
    end,
  })
end

return M

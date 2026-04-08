local M = {}
local utils = require("fugitive_utils")
local commands = require("features.commands")

local function get_fugitive_work_tree()
  local git_dir = vim.fn.FugitiveGitDir()
  if git_dir == '' then return nil end
  local work_tree_cmd = 'git --git-dir=' .. vim.fn.shellescape(git_dir) .. ' rev-parse --show-toplevel'
  local work_tree = vim.fn.trim(vim.fn.system(work_tree_cmd))
  return (vim.v.shell_error == 0) and work_tree or nil
end

local function get_stash_list(work_tree)
  local stash_output = vim.fn.systemlist('git -C ' .. vim.fn.shellescape(work_tree) .. ' stash list')
  return (vim.v.shell_error == 0) and stash_output or {}
end

local function stash_ref_from_line(line)
  return line and line:match('stash@%{%d+%}')
end

local function remove_custom_sections(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local ranges = {}
  local i = 1
  while i <= #lines do
    local line = lines[i]
    -- カスタムセクションのヘッダーを検知
    if line:match('^Worktrees %(') or line:match('^Stashes %(') then
      local start_idx = i
      -- 直前の空行も含める
      if start_idx > 1 and lines[start_idx - 1] == '' then start_idx = start_idx - 1 end

      -- セクションの終わり（次のヘッダーまたは空行の連続後、またはバッファ末尾）までを削除範囲とする
      local end_idx = i
      while end_idx < #lines do
        local next_line = lines[end_idx + 1]
        -- セクションに含まれる可能性のある行のパターン
        if next_line == '' or
           next_line:match('^[~/]') or next_line:match('^stash@') or
           next_line:match('^Worktrees %(') or next_line:match('^Stashes %(') then
          end_idx = end_idx + 1
        else break end
      end
      table.insert(ranges, { start_idx, end_idx })
      i = end_idx + 1
    else i = i + 1 end
  end
  -- 後ろから順に削除
  for r = #ranges, 1, -1 do
    vim.api.nvim_buf_set_lines(bufnr, ranges[r][1] - 1, ranges[r][2], false, {})
  end
end

local function find_insert_point(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i = #lines, 1, -1 do
    if lines[i] ~= '' then return i + 1 end
  end
  return #lines + 1
end

local function refresh_status_sections(bufnr, ns_worktree, ns_stash)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local work_tree = get_fugitive_work_tree()
  if not work_tree then return end

  local worktree_mod = require("features.worktree")
  local worktree_summary = worktree_mod.get_summary(work_tree)
  local stash_list = get_stash_list(work_tree)

  local prev_modifiable = vim.bo[bufnr].modifiable
  local prev_readonly = vim.bo[bufnr].readonly
  vim.bo[bufnr].modifiable, vim.bo[bufnr].readonly = true, false

  remove_custom_sections(bufnr)

  local final_lines = {}
  if worktree_summary and #worktree_summary > 0 then
    table.insert(final_lines, '')
    for _, l in ipairs(worktree_summary) do table.insert(final_lines, l) end
  end
  if stash_list and #stash_list > 0 then
    table.insert(final_lines, '')
    table.insert(final_lines, 'Stashes (' .. #stash_list .. ')')
    for _, l in ipairs(stash_list) do table.insert(final_lines, l) end
  end

  if #final_lines > 0 then
    local insert_idx = find_insert_point(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, insert_idx - 1, insert_idx - 1, false, final_lines)
  end

  vim.api.nvim_buf_clear_namespace(bufnr, ns_worktree, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_stash, 0, -1)

  local lines_after = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local in_worktree, in_stash = false, false
  local current_wt_abs = vim.fn.fnamemodify(work_tree, ':p'):gsub('/+$', '')

  for i, l in ipairs(lines_after) do
    if l:match('^Worktrees') then
      vim.api.nvim_buf_set_extmark(bufnr, ns_worktree, i - 1, 0, { end_col = #l, hl_group = 'RainbowDelimiterViolet' })
      in_worktree, in_stash = true, false
    elseif l:match('^Stashes') then
      vim.api.nvim_buf_set_extmark(bufnr, ns_stash, i - 1, 0, { end_col = #l, hl_group = 'GitSignsChange' })
      in_worktree, in_stash = false, true
    elseif in_worktree then
      -- 形式: [path]  [branch]  [head] [sync_icon]
      local p_part = l:match('^(%S+)')
      if p_part then
        local s_p, e_p = l:find(p_part, 1, true)
        local path_hl = (vim.fn.fnamemodify(p_part, ':p'):gsub('/+$', '') == current_wt_abs) and 'DiagnosticOk' or 'Directory'
        vim.api.nvim_buf_set_extmark(bufnr, ns_worktree, i - 1, s_p - 1, { end_col = e_p, hl_group = path_hl })

        -- ブランチ
        local br_part = l:sub(e_p + 1):match('%s+(%S+)')
        local s_b, e_b
        if br_part then
          s_b, e_b = l:find(br_part, e_p + 1, true)
          vim.api.nvim_buf_set_extmark(bufnr, ns_worktree, i - 1, s_b - 1, { end_col = e_b, hl_group = 'Type' })
        end

        -- ハッシュ
        local hd_part = l:sub((e_b or e_p) + 1):match('%s+(%S+)')
        local s_h, e_h
        if hd_part then
          s_h, e_h = l:find(hd_part, (e_b or e_p) + 1, true)
          vim.api.nvim_buf_set_extmark(bufnr, ns_worktree, i - 1, s_h - 1, { end_col = e_h, hl_group = 'Comment' })
        end

        -- 同期アイコン (一番右)
        local icon_str = '󰚰'
        local icon_pos, icon_end = l:find(icon_str, (e_h or e_b or e_p), true)
        if icon_pos then
          vim.api.nvim_buf_set_extmark(bufnr, ns_worktree, i - 1, icon_pos - 1, { end_col = icon_end, hl_group = 'DiagnosticOk' })
        end
      else
        if l ~= '' then in_worktree = false end
      end

    elseif in_stash then
      local ref = stash_ref_from_line(l)
      if ref then
        local s, e = l:find(ref, 1, true)
        -- stash@{n} の部分を強調
        vim.api.nvim_buf_set_extmark(bufnr, ns_stash, i - 1, s - 1, { end_col = e, hl_group = 'GitSignsAdd' })
        -- それ以降（メッセージ部分）をコメント色に
        vim.api.nvim_buf_set_extmark(bufnr, ns_stash, i - 1, e, { end_col = #l, hl_group = 'Comment' })
      else in_stash = false end
    end
  end
  vim.bo[bufnr].modifiable, vim.bo[bufnr].readonly = prev_modifiable, prev_readonly
end

local function get_stash_ref_at_cursor(bufnr)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
  return stash_ref_from_line(line)
end

local function is_cursor_in_stash_area()
  local line = vim.api.nvim_get_current_line()
  if line:match('^%s*stash@%{%d+%}') then return true end
  local s = line:find('Stashes')
  return s ~= nil and (vim.api.nvim_win_get_cursor(0)[2] + 1) >= s
end

local function is_cursor_in_worktree_area()
  local line = vim.api.nvim_get_current_line()
  return line:match('^Worktrees') or line:match('^[~/]')
end

local function get_worktree_path_at_cursor()
  local line = vim.api.nvim_get_current_line()
  return line:match('^(%S+)')
end

function M.setup(group)
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'fugitive',
    callback = function(ev)
      local b = ev.buf
      vim.opt_local.number, vim.opt_local.relativenumber = false, false
      local ns_stash = vim.api.nvim_create_namespace('fugitive_status_stash')
      local ns_worktree = vim.api.nvim_create_namespace('fugitive_status_worktree')
      local ns_id = vim.api.nvim_create_namespace('fugitive_status_icons')

      local function refresh()
        refresh_status_sections(b, ns_worktree, ns_stash)
      end

      vim.schedule(refresh)

      local bufgroupt = vim.api.nvim_create_augroup('FugitiveStatusRefresh' .. b, { clear = true })
      vim.api.nvim_create_autocmd('BufEnter', {
        group = bufgroupt, buffer = b,
        callback = function() vim.schedule(refresh) end,
      })

      local function apply_icons()
        if not vim.api.nvim_buf_is_valid(b) then return end
        vim.api.nvim_buf_clear_namespace(b, ns_id, 0, -1)
        local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
        for idx, line in ipairs(lines) do
          if line:match('^Staged') then
            vim.api.nvim_buf_set_extmark(b, ns_id, idx - 1, 0, { end_col = 6, hl_group = 'GitSignsAdd' })
          elseif line:match('^Unpulled') then
            vim.api.nvim_buf_set_extmark(b, ns_id, idx - 1, 0, { end_col = 8, hl_group = 'GitSignsChange' })
          elseif line:match('^Untracked') then
            vim.api.nvim_buf_set_extmark(b, ns_id, idx - 1, 0, { end_col = 9, hl_group = 'GitSignsDelete' })
          end

          local filepath = line:match('^[MADRCU?!][MADRCU?!]? (.+)$')
          if filepath then
            local status = line:sub(1, 1)
            if status == 'A' then vim.api.nvim_buf_set_extmark(b, ns_id, idx - 1, 0, { end_col = 1, hl_group = 'GitSignsAdd' })
            elseif status == 'D' then vim.api.nvim_buf_set_extmark(b, ns_id, idx - 1, 0, { end_col = 1, hl_group = 'GitSignsDelete' }) end

            local icon, icon_hl = utils.get_devicon(filepath)
            local f_start = line:find(filepath, 1, true)
            if f_start then
              vim.api.nvim_buf_set_extmark(b, ns_id, idx - 1, f_start - 1, { end_col = f_start - 1 + #filepath, hl_group = icon_hl })
              vim.api.nvim_buf_set_extmark(b, ns_id, idx - 1, f_start - 1, { virt_text = { { icon .. ' ', icon_hl } }, virt_text_pos = 'inline' })
            end
          end
        end
      end
      apply_icons()

      local function perform_continue()
        local git_dir = vim.fn.FugitiveGitDir()
        if not git_dir or git_dir == '' then return end
        if vim.fn.isdirectory(git_dir .. "/rebase-merge") == 1 or vim.fn.isdirectory(git_dir .. "/rebase-apply") == 1 then vim.cmd("Git rebase --continue")
        elseif vim.fn.filereadable(git_dir .. "/CHERRY_PICK_HEAD") == 1 then vim.cmd("Git cherry-pick --continue")
        elseif vim.fn.filereadable(git_dir .. "/MERGE_HEAD") == 1 then vim.cmd("Git merge --continue")
        elseif vim.fn.filereadable(git_dir .. "/REVERT_HEAD") == 1 then vim.cmd("Git revert --continue")
        else vim.notify("No operation in progress.", vim.log.levels.WARN) end
      end

      local function perform_skip()
        local git_dir = vim.fn.FugitiveGitDir()
        if not git_dir or git_dir == '' then return end
        if vim.fn.isdirectory(git_dir .. "/rebase-merge") == 1 or vim.fn.isdirectory(git_dir .. "/rebase-apply") == 1 then vim.cmd("Git rebase --skip")
        elseif vim.fn.filereadable(git_dir .. "/CHERRY_PICK_HEAD") == 1 then vim.cmd("Git cherry-pick --skip")
        elseif vim.fn.filereadable(git_dir .. "/REVERT_HEAD") == 1 then vim.cmd("Git revert --skip")
        else vim.notify("Skip not applicable.", vim.log.levels.WARN) end
      end

      local function perform_abort()
        local git_dir = vim.fn.FugitiveGitDir()
        if not git_dir or git_dir == '' then return end
        if vim.fn.isdirectory(git_dir .. "/rebase-merge") == 1 or vim.fn.isdirectory(git_dir .. "/rebase-apply") == 1 then vim.cmd("Git rebase --abort")
        elseif vim.fn.filereadable(git_dir .. "/CHERRY_PICK_HEAD") == 1 then vim.cmd("Git cherry-pick --abort")
        elseif vim.fn.filereadable(git_dir .. "/MERGE_HEAD") == 1 then vim.cmd("Git merge --abort")
        elseif vim.fn.filereadable(git_dir .. "/REVERT_HEAD") == 1 then vim.cmd("Git revert --abort")
        else vim.notify("No operation to abort.", vim.log.levels.WARN) end
      end

      vim.keymap.set('n', 'rr', perform_continue, { buffer = b, silent = true, desc = "Continue" })
      vim.keymap.set('n', 'rs', perform_skip, { buffer = b, silent = true, desc = "Skip" })
      vim.keymap.set('n', 'ra', perform_abort, { buffer = b, silent = true, desc = "Abort" })

      vim.keymap.set('n', 'A', function()
        if is_cursor_in_stash_area() then
          local r = get_stash_ref_at_cursor(b)
          if r then vim.cmd('Git stash apply ' .. r); vim.fn['fugitive#ReloadStatus'](); vim.schedule(refresh) end
          return
        end
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Plug>fugitive:ce", true, false, true), 'm', true)
      end, { buffer = b, nowait = true, silent = true })

      vim.keymap.set('n', 'P', function()
        if is_cursor_in_stash_area() then
          local r = get_stash_ref_at_cursor(b)
          if r then vim.cmd('Git stash pop ' .. r); vim.fn['fugitive#ReloadStatus'](); vim.schedule(refresh) end
          return
        end
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Plug>fugitive:P", true, false, true), 'm', true)
      end, { buffer = b, nowait = true, silent = true })

      vim.keymap.set('n', 'X', function()
        if is_cursor_in_worktree_area() then
          local p = get_worktree_path_at_cursor()
          if p and require("features.worktree").remove_worktree_path(p) then vim.fn['fugitive#ReloadStatus'](); vim.schedule(refresh) end
          return
        end
        if is_cursor_in_stash_area() then
          local r = get_stash_ref_at_cursor(b)
          if r then vim.cmd('Git stash drop ' .. r); vim.fn['fugitive#ReloadStatus'](); vim.schedule(refresh) end
          return
        end
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Plug>fugitive:X", true, false, true), 'm', true)
      end, { buffer = b, nowait = true, silent = true })

      vim.keymap.set('n', '<CR>', function()
        if is_cursor_in_worktree_area() then
          local p = get_worktree_path_at_cursor()
          if p then require("features.worktree").open_worktree_path(p); return end
        end
        if is_cursor_in_stash_area() then
          local r = get_stash_ref_at_cursor(b)
          if r then vim.cmd('Gvsplit ' .. r); return end
        end
        local f = utils.get_filepath_at_cursor(b)
        if f then
          local wt = get_fugitive_work_tree()
          local abs = wt and vim.fn.fnamemodify(wt .. '/' .. f, ':p') or nil
          -- Only open Oil when cursor is directly on the status line for that path
          local cur_line = vim.api.nvim_get_current_line()
          local cur_match = cur_line:match('^[MADRCU?!][MADRCU?!]? (.+)$')
          if cur_match then
            local _, new = cur_match:match('^(.+) %-> (.+)$')
            cur_match = new or cur_match
          end
          if abs and cur_match == f and vim.fn.isdirectory(abs) == 1 then
            pcall(vim.cmd, 'Oil ' .. vim.fn.fnameescape(abs)); return
          end
        end
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Plug>fugitive:<cr>", true, false, true), 'm', true)
      end, { buffer = b, nowait = true, silent = true })

      -- Toggle Flog
      vim.keymap.set('n', '<C-Space>', function()
        if vim.g.flog_win and vim.api.nvim_win_is_valid(vim.g.flog_win) then
          vim.api.nvim_win_close(vim.g.flog_win, false); vim.g.flog_win, vim.g.flog_bufnr = nil, nil
        else
          local cw = vim.api.nvim_get_current_win()
          vim.cmd("Flogsplit -open-cmd=vertical\\ rightbelow\\ 60vsplit")
          vim.g.flog_bufnr, vim.g.flog_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
          utils.setup_flog_window(vim.g.flog_win, vim.g.flog_bufnr)
          vim.api.nvim_set_current_win(cw)
        end
      end, { buffer = b, nowait = true, silent = true })

      -- Smart Close
      vim.keymap.set('n', 'q', function()
        if vim.g.flog_win and vim.api.nvim_win_is_valid(vim.g.flog_win) then vim.api.nvim_win_close(vim.g.flog_win, true) end
        require"utilities".smart_close()
      end, { buffer = b, nowait = true, silent = true })

      vim.keymap.set('n', 'R', function() vim.cmd('e!'); vim.cmd('normal gU') end, { buffer = b, silent = true })

      -- cf: Fixup/Reword commit under cursor with index
      vim.keymap.set('n', 'cf', function()
        local l = vim.api.nvim_get_current_line()
        local h = l:match('^(%x+)')
        if not h then vim.notify('No commit found at cursor', vim.log.levels.WARN) return end
        commands.mix_index_with_input(h)
      end, { buffer = b, nowait = true, silent = true, desc = 'Fixup/Reword commit under cursor with index' })

      -- <Leader>cf: Squash commit under cursor into its parent (Fixup)
      vim.keymap.set('n', '<Leader>cf', function()
        local l = vim.api.nvim_get_current_line()
        local h = l:match('^(%x+)')
        if not h then vim.notify('No commit found at cursor', vim.log.levels.WARN) return end
        commands.fixup_commit(h)
      end, { buffer = b, nowait = true, silent = true, desc = 'Fixup/Reword commit under cursor into its parent' })

      -- gr: Revert commit under cursor
      vim.keymap.set('n', 'gr', function()
        local l = vim.api.nvim_get_current_line()
        local h = l:match('^(%x+)')
        if not h then vim.notify('No commit found at cursor', vim.log.levels.WARN) return end
        local confirm = vim.fn.confirm('Revert ' .. h:sub(1, 7) .. '?', '&Yes\n&No', 2)
        if confirm ~= 1 then return end
        commands.revert_commits({ h })
      end, { buffer = b, nowait = true, silent = true, desc = 'Revert commit under cursor' })

      -- d: Open file diff in new tab
      vim.keymap.set('n', 'd', function()
        local file_path = utils.get_filepath_at_cursor(b)
        if not file_path then vim.notify('No file found at cursor', vim.log.levels.WARN) return end

        local target_line = nil
        local current_line_idx = vim.api.nvim_win_get_cursor(0)[1]
        local hunk_line = nil

        for lnum = current_line_idx, 1, -1 do
          local line = vim.api.nvim_buf_get_lines(b, lnum - 1, lnum, false)[1]
          if line then
            local line_num = line:match('^@@ %-(%d+)')
            if line_num then
              hunk_line = lnum
              target_line = tonumber(line_num)
              break
            end
            if line:match('^[MADRCU?!][MADRCU?!]? (.+)$') then break end
          end
        end

        if target_line and hunk_line then
          local offset = 0
          for lnum = hunk_line + 1, current_line_idx do
            local line = vim.api.nvim_buf_get_lines(b, lnum - 1, lnum, false)[1]
            if line and not line:match('^%-') then offset = offset + 1 end
          end
          target_line = target_line + offset - 1
        end

        local fugitive_path = vim.fn.FugitiveFind(':' .. file_path)
        vim.cmd('tabedit ' .. vim.fn.fnameescape(fugitive_path))

        vim.schedule(function()
          vim.cmd('Gvdiffsplit')
          if target_line then
            vim.schedule(function()
              local buf_line_count = vim.api.nvim_buf_line_count(0)
              target_line = math.min(target_line, buf_line_count)
              vim.api.nvim_win_set_cursor(0, { target_line, 0 })
              vim.cmd('normal! zz')
            end)
          end
        end)
      end, { buffer = b, nowait = true, silent = true, desc = 'Open file diff in new tab' })

      -- Load syntax
      require('features.syntax_highlight').attach(b)

      -- <Leader>wd: Toggle word diff style
      vim.keymap.set('n', '<Leader>wd', function()
        local sh = require('features.syntax_highlight')
        local new_style = sh.config.word_diff_style == 'github' and 'lazygit' or 'github'
        sh.config.word_diff_style = new_style
        vim.notify('Word diff style: ' .. new_style, vim.log.levels.INFO)
      end, { buffer = b, silent = true, desc = 'Toggle word diff style (lazygit/github)' })
    end,
  })
end

return M

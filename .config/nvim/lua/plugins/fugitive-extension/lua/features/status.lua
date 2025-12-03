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

-- Find the insertion point (after the last non-empty line) for the Stashes block.
local function find_insert_point(lines)
  -- Insert stash section at the bottom of the status buffer, after the last
  -- non-empty line. This ensures the stash block never ends up inserted in
  -- the middle of a section (e.g., between the Unstaged header and files).
  for i = #lines, 1, -1 do
    local l = lines[i]
    if l and l ~= '' then
      return i + 1
    end
  end
  return #lines + 1
end

-- Ensure stash section exists and is updated for the provided buffer.
-- Accepts a namespace id (ns_stash) for stash extmarks/highlight updates.
local function ensure_stash_section(bufnr, ns_stash)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end

  local stash_list = get_stash_list()
  local cur_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Avoid "W10: Warning: Changing a readonly file" messages by temporarily
  -- making buffer writable (and clearing readonly) while we update the
  -- content, and restore the original flags before returning.
  local prev_modifiable = vim.bo[bufnr].modifiable
  local prev_readonly = vim.bo[bufnr].readonly
  if not prev_modifiable or prev_readonly then
    vim.bo[bufnr].modifiable = true
    vim.bo[bufnr].readonly = false
  end

  -- find existing header if present
  local header_idx = nil
  for i, ln in ipairs(cur_lines) do
    if ln:match('^Stashes:') then
      header_idx = i
      break
    end
  end

  if not stash_list or #stash_list == 0 then
    if header_idx then
      -- remove section (header + stash entries)
      local end_idx = header_idx
      for j = header_idx + 1, #cur_lines do
        local l = cur_lines[j]
        -- stop when first non-stash line found
        if not l or l == '' then
          -- Include trailing blank line when removing so we don't leave duplicates.
          end_idx = j
          break
        end
        if not l:match('^%s+stash@') then
          end_idx = j - 1
          break
        end
      end
      -- If the loop completed without finding a non-stash line, remove through EOF.
      if end_idx == header_idx then
        end_idx = #cur_lines
      end
      vim.api.nvim_buf_set_lines(bufnr, header_idx - 1, end_idx, false, {})
    end
    -- Restore original buffer flags if we changed them earlier.
    if not prev_modifiable or prev_readonly then
      vim.bo[bufnr].modifiable = prev_modifiable
      vim.bo[bufnr].readonly = prev_readonly
    end
    return
  end

  -- build the new stash section
  local new_lines = {}
  table.insert(new_lines, 'Stashes: (' .. tostring(#stash_list) .. ')')
  for _, sline in ipairs(stash_list) do
    table.insert(new_lines, '  ' .. sline)
  end

      if header_idx then
          -- replace old block
          local end_idx = header_idx
          for j = header_idx + 1, #cur_lines do
            local l = cur_lines[j]
            if not l or l == '' then
              -- include trailing blank line in the removal range to avoid producing
              -- duplicate blank lines after re-inserting the stash section.
              end_idx = j
              break
            end
            if not l:match('^%s+stash@') then
              end_idx = j - 1
              break
            end
          end

      -- If the loop completed without finding a non-stash line, the stash section runs to EOF.
      if end_idx == header_idx then
        end_idx = #cur_lines
      end

    -- If the header does not have a blank line above it, add one so it doesn't
    -- visually touch the section above.
    if header_idx > 1 and cur_lines[header_idx - 1] ~= '' then
      table.insert(new_lines, 1, '')
    end

    -- Add a trailing separator only when there are lines after the stash section.
    if end_idx < #cur_lines then
      table.insert(new_lines, '')
    end

    vim.api.nvim_buf_set_lines(bufnr, header_idx - 1, end_idx, false, new_lines)
  else
    local insert_idx = find_insert_point(cur_lines)

    -- Advance past existing blank lines so stash won't be inserted before them.
    while insert_idx <= #cur_lines and cur_lines[insert_idx] == '' do
      insert_idx = insert_idx + 1
    end

    -- Ensure there's a single blank line between the previous content and the stash block.
    if insert_idx > 1 and cur_lines[insert_idx - 1] ~= '' then
      table.insert(new_lines, 1, '')
    end

    -- Only append a trailing blank if the stash block will be followed by additional content.
    if insert_idx <= #cur_lines then
      table.insert(new_lines, '')
    end

    vim.api.nvim_buf_set_lines(bufnr, insert_idx - 1, insert_idx - 1, false, new_lines)
  end
  vim.bo[bufnr].modifiable = false

  -- clear existing stash extmarks in this buffer and mark the new ones
  vim.api.nvim_buf_clear_namespace(bufnr, ns_stash, 0, -1)
  local lines_after = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, l in ipairs(lines_after) do
    if l:match('^Stashes:') then
      vim.api.nvim_buf_set_extmark(bufnr, ns_stash, i - 1, 0, { end_col = #l, hl_group = 'GitSignsChange' })
    elseif l:match('^%s+stash@') then
      vim.api.nvim_buf_set_extmark(bufnr, ns_stash, i - 1, 0, { end_col = #l, hl_group = 'GitSignsAdd' })
    end
  end

  -- Restore original buffer flags if we changed them earlier.
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

      -- Stash section integration (inserts a "Stashes: N" block directly in the fugitive status buffer)
      local ns_stash = vim.api.nvim_create_namespace('fugitive_status_stash')

      -- Ensure stash section is present initially and refresh on enter
      ensure_stash_section(ev.buf, ns_stash)
      vim.api.nvim_create_autocmd('BufEnter', {
        buffer = ev.buf,
        callback = function() vim.schedule(function() ensure_stash_section(ev.buf, ns_stash) end) end,
      })

      -- Stash-specific mappings that only act if the cursor is within the Stashes header or
      local map_A, map_P, map_X, map_O, map_CR

      map_A = function()
        if is_cursor_in_stash_area() then
          local ref = get_stash_ref_at_cursor(ev.buf)
          if not ref then vim.notify('No stash at cursor', vim.log.levels.WARN) return end
          vim.cmd('Git stash apply ' .. ref)
          vim.fn['fugitive#ReloadStatus']()
          vim.schedule(function() ensure_stash_section(ev.buf, ns_stash) end)
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
          vim.schedule(function() ensure_stash_section(ev.buf, ns_stash) end)
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
          vim.schedule(function() ensure_stash_section(ev.buf, ns_stash) end)
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
        vim.api.nvim_feedkeys(
          vim.api.nvim_replace_termcodes("<Plug>fugitive:<cr>", true, false, true),
          'm',
          true
        )
      end
      vim.keymap.set('n', '<CR>', map_CR, { buffer = ev.buf, nowait = true, silent = true, desc = 'Open stash diff in split buffer' })

      vim.keymap.set('n', 'dd', function()
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
        -- "Stashes" ヘッダをハイライト
        elseif line:match('^Stashes:') then
          vim.api.nvim_buf_set_extmark(ev.buf, ns_id, idx - 1, 0, {
            end_col = #line,
            hl_group = 'GitSignsChange',
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

        -- Highlight stash entry lines (e.g., "  stash@{0}: ...")
        if line:match('^%s*stash@%{%d+%}') then
          vim.api.nvim_buf_set_extmark(ev.buf, ns_id, idx - 1, 0, {
            end_col = #line,
            hl_group = 'GitSignsAdd',
          })
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

      -- カーソル行のコミットを一つ前のコミットにfixupする
      vim.keymap.set('n', '<Leader>cf', function()
        local current_line = vim.api.nvim_get_current_line()
        -- コミットハッシュを抽出（Unpushedセクションのコミット行から）
        local commit_hash = current_line:match('^(%x+)')

        if not commit_hash then
          vim.notify('No commit found at cursor', vim.log.levels.WARN)
          return
        end
        commands.fixup_commit(commit_hash)
      end, { buffer = ev.buf, nowait = true, silent = true, desc = 'Fixup commit under cursor into its parent' })

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
    end,
  })
end

return M

local M = {}
local utils = require("fugitive_utils")
local commands = require("features.commands")

local is_navigating = false

local function get_commit_from_buffer(bufnr)
  local commit = utils.get_commit(bufnr)

  if not commit or commit == '' then
    local line = vim.api.nvim_get_current_line()
    commit = line:match('^commit (%x+)') or line:match('^(%x%x%x%x%x%x%x+)')
  end

  if not commit then
     local lnum = vim.fn.line('.')
     while lnum > 0 do
       local l = vim.fn.getline(lnum)
       local c = l:match('^commit (%x+)')
       if c then
         commit = c
         break
       end
       lnum = lnum - 1
     end
  end
  return commit
end

_G.fugitive_foldtext = function()
  local line = vim.fn.getline(vim.v.foldstart)
  local filename = line:match("^diff %-%-git [ab]/(.+) [ab]/") or line:match("^(%S+)") or "folding"

  local icon, icon_hl = utils.get_devicon(filename)

  -- ファイルの状態を判定（削除/リネーム）
  local is_deleted = false
  local is_renamed = false
  local new_filename = nil

  for i = vim.v.foldstart, vim.v.foldstart + 10 do
    local l = vim.fn.getline(i)
    if l:match("^deleted file mode") then
      is_deleted = true
      break
    elseif l:match("^rename from") then
      is_renamed = true
    elseif l:match("^rename to") then
      new_filename = l:match("^rename to (.+)$")
    end
  end

  local added, removed, changed = 0, 0, 0
  for i = vim.v.foldstart, vim.v.foldend do
    local l = vim.fn.getline(i)
    if l:match("^%+[^%+]") then
      added = added + 1
    elseif l:match("^%-[^%-]") then
      removed = removed + 1
    elseif l:match("^~") then
      changed = changed + 1
    end
  end
  local result = {}

  if is_deleted then
    table.insert(result, { icon .. " ", icon_hl })
    table.insert(result, { filename, "GitSignsDelete" })
  elseif is_renamed then
    table.insert(result, { icon .. " ", icon_hl })
    table.insert(result, { filename, "GitSignsChange" })
    if new_filename then
      table.insert(result, { " → " .. new_filename, "GitSignsChange" })
    end
  else
    table.insert(result, { icon .. " ", icon_hl })
    table.insert(result, { filename, icon_hl })
  end

  if added > 0 then
    table.insert(result, { " +" .. added, "GitSignsAdd" })
  end
  if changed > 0 then
    table.insert(result, { " ~" .. changed, "GitSignsChange" })
  end
  if removed > 0 then
    table.insert(result, { " -" .. removed, "GitSignsDelete" })
  end

  table.insert(result, { " ", "Normal" })

  return result
end

-- Helpers for X: discard diff changes from commit
local function get_diff_context_at_line(bufnr, lnum)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local on_file_header = (lines[lnum] or ''):match('^diff %-%-git') ~= nil
  local filepath, file_lnum = nil, nil
  for i = lnum, 1, -1 do
    local p = lines[i]:match('^diff %-%-git [ab]/(.+) [ab]/')
    if p then filepath, file_lnum = p, i; break end
  end
  local hunk_start = nil
  if not on_file_header then
    for i = lnum, 1, -1 do
      if lines[i]:match('^@@') then hunk_start = i; break end
      if lines[i]:match('^diff %-%-git') then break end
    end
  end
  return filepath, file_lnum, on_file_header, hunk_start, lines
end

local function collect_file_patch(lines, file_lnum)
  local result = {}
  for i = file_lnum, #lines do
    if i > file_lnum and lines[i]:match('^diff %-%-git') then break end
    table.insert(result, lines[i])
  end
  return result
end

local function collect_hunk_patch(lines, file_lnum, hunk_start)
  local result = {}
  for i = file_lnum, hunk_start - 1 do
    local l = lines[i]
    if l:match('^diff %-%-git') or l:match('^index ') or l:match('^old mode')
      or l:match('^new mode') or l:match('^new file') or l:match('^deleted file')
      or l:match('^rename') or l:match('^similarity')
      or l:match('^%-%-%-') or l:match('^%+%+%+') then
      table.insert(result, l)
    end
  end
  table.insert(result, lines[hunk_start])
  for i = hunk_start + 1, #lines do
    local l = lines[i]
    if l:match('^@@') or l:match('^diff %-%-git') then break end
    table.insert(result, l)
  end
  return result
end

-- Build a patch that individually reverses only the selected +/- lines (zero-context hunks)
local function build_partial_reverse_patch(filepath, lines, hunk_start, sel_start, sel_end)
  local header = lines[hunk_start]
  local old_s, new_s = header:match('^@@ %-(%d+),?%d* %+(%d+),?%d* @@')
  if not old_s then return nil end
  local old_cur, new_cur = tonumber(old_s), tonumber(new_s)
  local sub_hunks = {}
  for i = hunk_start + 1, #lines do
    local l = lines[i]
    if l:match('^@@') or l:match('^diff %-%-git') then break end
    local prefix, content = l:sub(1, 1), l:sub(2)
    local in_sel = (i >= sel_start and i <= sel_end)
    if prefix == ' ' then
      old_cur, new_cur = old_cur + 1, new_cur + 1
    elseif prefix == '-' then
      if in_sel then
        -- Add back the deleted line at the current position in the new (commit) file
        table.insert(sub_hunks, '@@ -' .. new_cur .. ',0 +' .. new_cur .. ',1 @@')
        table.insert(sub_hunks, '+' .. content)
      end
      old_cur = old_cur + 1
    elseif prefix == '+' then
      if in_sel then
        -- Remove the added line at the current position in the new (commit) file
        table.insert(sub_hunks, '@@ -' .. new_cur .. ',1 +' .. new_cur .. ',0 @@')
        table.insert(sub_hunks, '-' .. content)
      end
      new_cur = new_cur + 1
    end
  end
  if #sub_hunks == 0 then return nil end
  local patch = {
    'diff --git a/' .. filepath .. ' b/' .. filepath,
    '--- a/' .. filepath,
    '+++ b/' .. filepath,
  }
  vim.list_extend(patch, sub_hunks)
  return patch
end

local function commit_auto_stash(work_tree)
  local status = vim.fn.systemlist('git -C ' .. vim.fn.shellescape(work_tree) .. ' status --porcelain')
  if vim.v.shell_error ~= 0 then
    vim.notify('git status failed; skipping auto-stash', vim.log.levels.WARN)
    return false
  end
  if #status == 0 then return false end
  vim.fn.system('git -C ' .. vim.fn.shellescape(work_tree)
    .. ' stash push -u -k -m ' .. vim.fn.shellescape('fugitive-ext commit auto-stash'))
  if vim.v.shell_error ~= 0 then
    vim.notify('auto-stash failed; aborting', vim.log.levels.ERROR)
    return nil
  end
  vim.notify('Auto-stashed dirty worktree', vim.log.levels.INFO)
  return true
end

local function commit_auto_pop(work_tree)
  vim.fn.system('git -C ' .. vim.fn.shellescape(work_tree) .. ' stash pop --index --quiet')
  if vim.v.shell_error ~= 0 then
    vim.notify('Auto-stash pop failed; please pop manually', vim.log.levels.ERROR)
  else
    vim.notify('Auto-stash popped', vim.log.levels.INFO)
  end
end

-- Run git rebase -i (stop at commit), apply/reverse the patch, amend, then continue
local function apply_patch_and_amend(git_dir, commit, filepath, patch_lines, use_reverse)
  local patch_file = vim.fn.tempname()
  local f = io.open(patch_file, 'w')
  if not f then
    vim.notify('Failed to create temp file', vim.log.levels.ERROR)
    return false
  end
  f:write(table.concat(patch_lines, '\n') .. '\n')
  f:close()

  local rebase_cmd = 'cd ' .. vim.fn.shellescape(git_dir)
    .. " && GIT_SEQUENCE_EDITOR=\"sed -i '/" .. commit:sub(1, 7)
    .. "/s/^pick/edit/'\" git rebase -i " .. commit .. '^ 2>&1'
  local out = vim.fn.system(rebase_cmd)
  if not out:match('Stopped at') then
    vim.notify('Rebase failed: ' .. out:sub(1, 120), vim.log.levels.ERROR)
    os.remove(patch_file)
    return false
  end

  local rev = use_reverse and '--reverse ' or ''
  out = vim.fn.system('cd ' .. vim.fn.shellescape(git_dir)
    .. ' && git apply ' .. rev .. '--unidiff-zero ' .. vim.fn.shellescape(patch_file)
    .. ' && git add ' .. vim.fn.shellescape(filepath)
    .. ' && git commit --amend --allow-empty --no-edit 2>&1')
  if vim.v.shell_error ~= 0 then
    vim.notify('Apply failed: ' .. out:sub(1, 120), vim.log.levels.ERROR)
    vim.fn.system('cd ' .. vim.fn.shellescape(git_dir) .. ' && git rebase --abort')
    os.remove(patch_file)
    return false
  end

  out = vim.fn.system('cd ' .. vim.fn.shellescape(git_dir) .. ' && GIT_EDITOR=true git rebase --continue 2>&1')
  if not (out:match('Successfully rebased') or vim.v.shell_error == 0) then
    vim.notify('Rebase continue failed: ' .. out:sub(1, 120), vim.log.levels.ERROR)
    vim.fn.system('cd ' .. vim.fn.shellescape(git_dir) .. ' && git rebase --abort')
    os.remove(patch_file)
    return false
  end

  os.remove(patch_file)
  return true
end

-- Post-discard: stash pop, check empty commit, reload buffer
local function do_discard(git_dir, commit, filepath, patch, use_reverse, scope, stashed)
  local ok = apply_patch_and_amend(git_dir, commit, filepath, patch, use_reverse)
  if stashed then commit_auto_pop(git_dir) end
  vim.cmd('checktime')
  if not ok then return end

  local new_hash = vim.fn.system('git -C ' .. vim.fn.shellescape(git_dir)
    .. ' rev-parse HEAD 2>/dev/null'):gsub('%s+', '')

  -- Check if commit became empty
  local diff_out = vim.fn.systemlist('git -C ' .. vim.fn.shellescape(git_dir)
    .. ' diff-tree --no-commit-id -r ' .. new_hash .. ' 2>/dev/null')
  if #diff_out == 0 and new_hash ~= '' then
    if vim.fn.confirm(
      'Commit ' .. new_hash:sub(1, 7) .. ' is now empty. Drop it?',
      '&Yes\n&No', 1
    ) == 1 then
      vim.fn.system('cd ' .. vim.fn.shellescape(git_dir)
        .. " && GIT_SEQUENCE_EDITOR=\"sed -i '1s/^pick/drop/'\" GIT_EDITOR=true git rebase -i HEAD^ 2>&1")
      vim.notify('Dropped empty commit ' .. new_hash:sub(1, 7), vim.log.levels.INFO)
      vim.cmd('silent! doautocmd User FugitiveChanged')
      vim.cmd('checktime')
      vim.schedule(function() require('utilities').smart_close() end)
      return
    end
  end

  vim.notify(string.format('Discarded %s from %s', scope, commit:sub(1, 7)), vim.log.levels.INFO)
  -- Trigger log buffer refresh via standard fugitive event
  vim.cmd('silent! doautocmd User FugitiveChanged')
  -- Reload the buffer to reflect the amended commit
  if new_hash ~= '' then
    vim.schedule(function() vim.cmd('Gedit ' .. new_hash) end)
  end
end

function M.setup(group)
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = "git",
    callback = function()
      vim.opt_local.foldmethod = "syntax"
      vim.opt_local.foldlevel = 0
      vim.opt_local.foldenable = true
      vim.opt_local.foldtext = "v:lua.fugitive_foldtext()"
    end,
  })

  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'git',
    callback = function(ev)
      -- Highlight diff paths
      local ns_id = vim.api.nvim_create_namespace('git_diff_path_highlight')

      local function apply_diff_highlights()
        if not vim.api.nvim_buf_is_valid(ev.buf) then
          return
        end
        vim.api.nvim_buf_clear_namespace(ev.buf, ns_id, 0, -1)

        local lines = vim.api.nvim_buf_get_lines(ev.buf, 0, -1, false)
        for idx, line in ipairs(lines) do
          if line:match('^diff') or line:match('^@') then
            local win_width = vim.api.nvim_win_get_width(0)
            local line_len = vim.fn.strdisplaywidth(line)
            local pad = win_width - line_len - 1
            if pad > 0 then
              vim.api.nvim_buf_set_extmark(ev.buf, ns_id, idx - 1, 0, {
                virt_text = {{ " " .. string.rep("·", pad), "Comment" }},
                virt_text_pos = 'eol',
                hl_mode = 'combine',
              })
            end
          end

          if line:match('^diff') then
            local prefix_a = 'diff --git a/'
            local path1_start_col_0based = #prefix_a

            local b_start_1based, _ = line:find(' b/', #prefix_a + 1)

            if b_start_1based then
              local path1_end_col_0based = b_start_1based - 1

              vim.api.nvim_buf_set_extmark(ev.buf, ns_id, idx - 1, path1_start_col_0based, {
                end_col = path1_end_col_0based,
                hl_group = 'GitSignsChange',
              })

              local path2_start_col_0based = b_start_1based + #' b/' - 1
              vim.api.nvim_buf_set_extmark(ev.buf, ns_id, idx - 1, path2_start_col_0based, {
                end_col = #line,
                hl_group = 'GitSignsAdd',
              })
            end
          end
        end
      end

      apply_diff_highlights()

      vim.api.nvim_create_autocmd({ 'BufEnter', 'TextChanged' }, {
        buffer = ev.buf,
        callback = function()
          vim.schedule(apply_diff_highlights)
        end,
      })

      -- Enable syntax highlighting for diffs
      require('features.syntax_highlight').attach(ev.buf)

      local function update_flog_highlight()
        if not vim.api.nvim_buf_is_valid(ev.buf) then return end
        utils.highlight_flog_commit(vim.g.flog_bufnr, vim.g.flog_win, utils.get_commit(ev.buf))
      end

      -- BufEnter時にハイライト更新
      vim.api.nvim_create_autocmd('BufEnter', {
        buffer = ev.buf,
        callback = function()
          vim.schedule(update_flog_highlight)
        end,
      })

      -- Update flog highlight and commit info float on cursor movement.
      -- We only update the float if it already exists (create_if_missing=false).
      vim.api.nvim_create_autocmd('CursorMoved', {
        buffer = ev.buf,
        callback = function()
          vim.schedule(function()
            if not vim.api.nvim_buf_is_valid(ev.buf) then return end
            update_flog_highlight()
            local commit = utils.get_commit(ev.buf) or vim.api.nvim_get_current_line():match('^(%x+)')
            if commit and commit ~= '' then
              commands.schedule_update_preview(commit)
            end
          end)
        end,
      })

      -- <C-Space>: Flogウィンドウトグル
      vim.keymap.set('n', '<C-Space>', function()
        if vim.g.flog_win and vim.api.nvim_win_is_valid(vim.g.flog_win) then
          vim.api.nvim_win_close(vim.g.flog_win, false)
          vim.g.flog_win = nil
          vim.g.flog_bufnr = nil
          vim.g.flog_opener_bufnr = nil
        else
          local current_win = vim.api.nvim_get_current_win()
          vim.cmd("Flogsplit -open-cmd=vertical\\ rightbelow\\ 60vsplit")
          vim.g.flog_bufnr = vim.api.nvim_get_current_buf()
          vim.g.flog_win = vim.api.nvim_get_current_win()
          vim.g.flog_opener_bufnr = ev.buf

          utils.setup_flog_window(vim.g.flog_win, vim.g.flog_bufnr)
          update_flog_highlight()
          vim.api.nvim_set_current_win(current_win)
        end
      end, { buffer = ev.buf, nowait = true, silent = true, desc = 'Toggle Flog window' })

      vim.api.nvim_create_autocmd('BufUnload', {
        buffer = ev.buf,
        callback = function(args)
          if is_navigating then
            return
          end
          if vim.g.flog_opener_bufnr and vim.g.flog_opener_bufnr == args.buf then
            if vim.g.flog_win and vim.api.nvim_win_is_valid(vim.g.flog_win) then
              vim.api.nvim_win_close(vim.g.flog_win, true)
              vim.g.flog_win = nil
              vim.g.flog_bufnr = nil
              vim.g.flog_opener_bufnr = nil
            end
          end

          commands.close_commit_info_float()
        end,
      })

      -- d: Diffview
      vim.keymap.set('n', 'd', function()
        local commit = get_commit_from_buffer(ev.buf)

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

      -- C: コミット概要をフロートウィンドウで表示
      vim.keymap.set('n', 'C', function()
        local commit = get_commit_from_buffer(ev.buf)

        if not commit then
          print('No commit found')
          return
        end

        commands.show_commit_info_float(commit, true, true)
      end, { buffer = ev.buf, nowait = true, silent = true, desc = 'Show commit info in float window' })

      -- p: カーソル位置ファイルの前のコミット
      vim.keymap.set('n', 'p', function()
        local commit = get_commit_from_buffer(ev.buf)
        if not commit then
          return
        end
        local filepath = utils.get_filepath_at_cursor(ev.buf)
        if not filepath then
          return
        end

        local result = vim.fn.systemlist('git log --format=%H --skip=1 -n 1 ' .. commit .. ' -- ' .. vim.fn.shellescape(filepath))
        if not result or #result == 0 or result[1] == '' then
          print('No previous commit found for ' .. filepath)
          return
        end

        local prev_commit = result[1]
        is_navigating = true
        vim.schedule(function()
          vim.cmd('Gedit ' .. prev_commit)
          utils.highlight_flog_commit(vim.g.flog_bufnr, vim.g.flog_win, prev_commit)
          commands.show_commit_info_float(prev_commit, false, false)
          vim.schedule(function()
            local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
            for i, line in ipairs(lines) do
              if line:match('^diff %-%-git [ab]/' .. vim.pesc(filepath) .. ' ') then
                vim.api.nvim_win_set_cursor(0, { i, 0 })
                vim.cmd('normal! zO')
                break
              end
            end
            is_navigating = false
          end)
        end)
      end, { buffer = ev.buf, nowait = true, silent = true })

      -- ~: 前のコミット
      vim.keymap.set('n', '~', function()
        is_navigating = true
        vim.fn.feedkeys(vim.api.nvim_replace_termcodes('<Plug>fugitive:~', true, false, true), 'n')
        vim.schedule(function()
          is_navigating = false
        end)
      end, { buffer = ev.buf, nowait = true, silent = true })

      -- <C-o>: Jump back (original behavior) and update flog highlight + commit float if open.
      -- We explicitly do not create a float if it's not already open.
      vim.keymap.set('n', '<C-o>', function()
        is_navigating = true
        -- Do the original <C-o> jump
        vim.fn.feedkeys(vim.api.nvim_replace_termcodes('<C-o>', true, false, true), 'n')
        vim.schedule(function()
          -- We need to check the current buffer after the jump
          local curr_buf = vim.api.nvim_get_current_buf()
          local commit = utils.get_commit(curr_buf) or vim.api.nvim_get_current_line():match('^(%x+)')
          if commit and commit ~= '' then
            utils.highlight_flog_commit(vim.g.flog_bufnr, vim.g.flog_win, commit)
            commands.show_commit_info_float(commit, false, false)
          end
          is_navigating = false
        end)
      end, { buffer = ev.buf, nowait = true, silent = true })

      -- O: Octo PR
      vim.keymap.set('n', 'O', function()
        local commit = get_commit_from_buffer(ev.buf)
        if not commit then
          return
        end
        vim.cmd('OctoPrFromSha ' .. commit)
      end, { buffer = ev.buf, nowait = true, silent = true, noremap = true })

      -- gf: カーソル位置のファイルを開く
      vim.keymap.set('n', 'gf', function()
        local filepath = utils.get_filepath_at_cursor(ev.buf)
        if filepath then
          vim.cmd('edit ' .. filepath)
        end
      end, { buffer = ev.buf, nowait = true, silent = true })

      -- gq: ファイル一覧をQuickfixに追加
      vim.keymap.set('n', 'gq', function()
        local lines = vim.api.nvim_buf_get_lines(ev.buf, 0, -1, false)
        local qf_list = {}
        for _, line in ipairs(lines) do
          local filepath = line:match('^diff %-%-git [ab]/(.+) [ab]/')
          if filepath then
            table.insert(qf_list, { filename = filepath, lnum = 1 })
          end
        end
        if #qf_list > 0 then
          vim.fn.setqflist(qf_list)
          vim.cmd('copen')
        else
          print('No files found')
        end
      end, { buffer = ev.buf, nowait = true, silent = true })

      -- Ctrl-y: コミットハッシュをクリップボードにコピー
      vim.keymap.set('n', '<C-y>', function()
        local commit = get_commit_from_buffer(ev.buf)
        if not commit then
          print('No commit found')
          return
        end
        local short_commit = commit:sub(1, 7)
        vim.fn.setreg('+', short_commit)
        vim.fn.setreg('"', short_commit)
        print('Copied: ' .. short_commit)
      end, { buffer = ev.buf, nowait = true, silent = true })

      -- X: Discard diff changes from commit (hunk / file / visual selection)
      vim.keymap.set('n', 'X', function()
        local lnum = vim.fn.line('.')
        local filepath, file_lnum, on_file_header, hunk_start, lines =
          get_diff_context_at_line(ev.buf, lnum)
        if not filepath or (not on_file_header and not hunk_start) then
          vim.notify('Not in a diff section', vim.log.levels.WARN)
          return
        end
        local commit = get_commit_from_buffer(ev.buf)
        if not commit then
          vim.notify('No commit found', vim.log.levels.WARN)
          return
        end
        local scope = on_file_header and 'file' or 'hunk'
        if vim.fn.confirm(
          string.format('Discard %s changes from commit %s?', scope, commit:sub(1, 7)),
          '&Yes\n&No', 2
        ) ~= 1 then return end
        local git_dir = vim.fn.FugitiveWorkTree()
        local stashed = commit_auto_stash(git_dir)
        if stashed == nil then return end
        local patch
        if on_file_header then
          patch = collect_file_patch(lines, file_lnum)
        else
          patch = collect_hunk_patch(lines, file_lnum, hunk_start)
        end
        do_discard(git_dir, commit, filepath, patch, true, scope, stashed)
      end, { buffer = ev.buf, nowait = true, silent = true, desc = 'Discard diff changes from commit' })

      vim.keymap.set('v', 'X', function()
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'x', false)
        local sel_start = vim.fn.line("'<")
        local sel_end   = vim.fn.line("'>")
        local filepath, _, _, hunk_start, lines =
          get_diff_context_at_line(ev.buf, sel_start)
        if not filepath or not hunk_start then
          vim.notify('No hunk in selection', vim.log.levels.WARN)
          return
        end
        local commit = get_commit_from_buffer(ev.buf)
        if not commit then
          vim.notify('No commit found', vim.log.levels.WARN)
          return
        end
        if vim.fn.confirm(
          string.format('Discard selected changes from commit %s?', commit:sub(1, 7)),
          '&Yes\n&No', 2
        ) ~= 1 then return end
        local git_dir = vim.fn.FugitiveWorkTree()
        local stashed = commit_auto_stash(git_dir)
        if stashed == nil then return end
        local patch = build_partial_reverse_patch(filepath, lines, hunk_start, sel_start, sel_end)
        if not patch then
          vim.notify('No diff lines in selection', vim.log.levels.WARN)
          if stashed then commit_auto_pop(git_dir) end
          return
        end
        do_discard(git_dir, commit, filepath, patch, false, 'selection', stashed)
      end, { buffer = ev.buf, silent = true, desc = 'Discard selected diff changes from commit' })

      -- q: Close window and flog window
      vim.keymap.set('n', 'q', function()
        if vim.g.flog_win and vim.api.nvim_win_is_valid(vim.g.flog_win) then
          vim.api.nvim_win_close(vim.g.flog_win, false)
          vim.g.flog_win = nil
          vim.g.flog_bufnr = nil
          vim.g.flog_opener_bufnr = nil
        end
        require"utilities".smart_close()
      end, { buffer = ev.buf, nowait = true, silent = true })

      -- all close
      vim.keymap.set('n', 'R', function() vim.cmd('e!') end, { buffer = ev.buf, silent = true })
    end,
  })
end

return M

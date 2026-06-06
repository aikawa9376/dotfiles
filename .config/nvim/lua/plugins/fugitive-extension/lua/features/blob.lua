local M = {}
local utils = require("fugitive_utils")

function M.setup(group)
  vim.api.nvim_create_autocmd('BufReadPost', {
    group = group,
    pattern = 'fugitive://*',
    callback = function(ev)
      local bufname = vim.api.nvim_buf_get_name(ev.buf)
      local parse = vim.fn.FugitiveParse(bufname)
      if not parse or not parse[1] then
        return
      end
      local commit, filepath = parse[1]:match('^([^:]+):(.+)$')
      if not commit or not filepath then
        return
      end
      local work_tree = utils.set_buf_work_tree(ev.buf, utils.get_work_tree({ git_dir = parse[2] }))
      if not work_tree then
        return
      end

      local function git_cmd(args)
        return 'git -C ' .. vim.fn.shellescape(work_tree) .. ' ' .. args
      end

      local function git_systemlist(args)
        return vim.fn.systemlist(git_cmd(args))
      end

      local function git_system(args)
        return vim.fn.system(git_cmd(args))
      end

      vim.keymap.set('n', 'p', function()
        local current_pos = vim.api.nvim_win_get_cursor(0)
        local result = git_systemlist(
          'log --format=%H --skip=1 -n 1 ' .. vim.fn.shellescape(commit) .. ' -- ' .. vim.fn.shellescape(filepath)
        )
        if result and #result > 0 and result[1] ~= '' then
          vim.cmd('Gedit ' .. vim.fn.fnameescape(result[1] .. ':' .. filepath))
          vim.schedule(function()
            local line_count = vim.api.nvim_buf_line_count(0)
            local target_line = math.min(current_pos[1], line_count)
            vim.api.nvim_win_set_cursor(0, { target_line, current_pos[2] })
          end)
        else
          print('No previous commit found for ' .. filepath)
        end
      end, { buffer = ev.buf, nowait = true, silent = true })

      vim.keymap.set('n', 'gf', function()
        local abs_path = utils.worktree_relative_abs_path(work_tree, filepath)
        if not abs_path then
          vim.notify('Could not resolve file from repository root: ' .. filepath, vim.log.levels.WARN)
          return
        end
        if vim.fn.filereadable(abs_path) ~= 1 then
          vim.notify('File does not exist in worktree: ' .. filepath, vim.log.levels.WARN)
          return
        end

        local current_pos = vim.api.nvim_win_get_cursor(0)
        vim.cmd('edit ' .. vim.fn.fnameescape(abs_path))
        vim.schedule(function()
          local line_count = vim.api.nvim_buf_line_count(0)
          local target_line = math.min(current_pos[1], line_count)
          vim.api.nvim_win_set_cursor(0, { target_line, current_pos[2] })
        end)
      end, { buffer = ev.buf, nowait = true, silent = true, desc = 'Open blob file in worktree' })

      local ns_id = vim.api.nvim_create_namespace("FugitiveDiffDim")
      local dim_enabled = false
      vim.keymap.set('n', 'dd', function()
        if dim_enabled then
          vim.api.nvim_buf_clear_namespace(ev.buf, ns_id, 0, -1)
          dim_enabled = false
          print('Diff highlight cleared')
        else
          local parent_result = git_systemlist(
            'log --format=%H --skip=1 -n 1 ' .. vim.fn.shellescape(commit) .. ' -- ' .. vim.fn.shellescape(filepath)
          )
          local parent_commit = parent_result and #parent_result > 0 and parent_result[1] ~= '' and parent_result[1]
            or commit .. '^'

          local diff_output = git_systemlist(
            'diff --unified=0 '
              .. vim.fn.shellescape(parent_commit)
              .. ' '
              .. vim.fn.shellescape(commit)
              .. ' -- '
              .. vim.fn.shellescape(filepath)
          )
          local diff_lines = {}

          for _, line in ipairs(diff_output) do
            local start_line, line_count = line:match('^@@ %-%d+,?%d* %+(%d+),?(%d*) @@')
            if start_line then
              start_line = tonumber(start_line)
              line_count = line_count == '' and 1 or tonumber(line_count)
              for i = start_line, start_line + line_count - 1 do
                diff_lines[i] = true
              end
            end
          end

          local buf_line_count = vim.api.nvim_buf_line_count(ev.buf)
          for i = 1, buf_line_count do
            if not diff_lines[i] then
              vim.api.nvim_buf_set_extmark(ev.buf, ns_id, i - 1, 0, {
                line_hl_group = 'LineNr',
              })
            end
          end
          dim_enabled = true
          print('Diff highlight enabled')
        end
      end, { buffer = ev.buf, nowait = true, silent = true, desc = 'Toggle diff highlight' })

      vim.keymap.set('n', 'dv', function()
        vim.cmd('tabedit %')
        vim.cmd('Gvdiffsplit!')
      end, { buffer = ev.buf, nowait = true, silent = true })

      -- du: blobの選択行の変更を打ち消してコミット履歴を書き換え、変更をステージング
      vim.keymap.set('v', 'du', function()
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'x', false)
        local start_line = vim.fn.line("'<")
        local end_line = vim.fn.line("'>")

        if start_line == 0 or end_line == 0 then
          print('Invalid line selection')
          return
        end

        local commit_lines = vim.api.nvim_buf_get_lines(ev.buf, start_line - 1, end_line, false)

        local patch_lines = {
          'diff --git a/' .. filepath .. ' b/' .. filepath,
          'index 0000000..0000000 100644',
          '--- a/' .. filepath,
          '+++ b/' .. filepath,
          '@@ -' .. start_line .. ',' .. (end_line - start_line + 1) .. ' +' .. start_line .. ',0 @@',
        }

        for i = start_line, end_line do
          local commit_line = commit_lines[i - start_line + 1] or ''
          table.insert(patch_lines, '-' .. commit_line)
        end

        local patch_file = vim.fn.tempname()
        local f = io.open(patch_file, 'w')
        if not f then
          return
        end
        f:write(table.concat(patch_lines, '\n') .. '\n')
        f:close()

        -- Step 1: インタラクティブリベースで対象コミットを編集モードに
        local rebase_cmd = 'GIT_SEQUENCE_EDITOR='
          .. vim.fn.shellescape("sed -i '/" .. commit:sub(1, 7) .. "/s/^pick/edit/'")
          .. ' '
          .. git_cmd('rebase -i ' .. vim.fn.shellescape(commit .. '^') .. ' 2>&1')
        local rebase_result = vim.fn.system(rebase_cmd)

        if not rebase_result:match('Stopped at') then
          print('Rebase failed: ' .. rebase_result:sub(1, 100))
          os.remove(patch_file)
          return
        end

        -- Step 2: パッチを適用してコミットから変更を削除
        local apply_cmd = git_cmd('apply --unidiff-zero ' .. vim.fn.shellescape(patch_file))
          .. ' && '
          .. git_cmd('add ' .. vim.fn.shellescape(filepath))
          .. ' && '
          .. git_cmd('commit --amend --no-edit 2>&1')
        local apply_result = vim.fn.system(apply_cmd)

        if vim.v.shell_error ~= 0 then
          print('Apply failed (conflict?): ' .. apply_result:sub(1, 100))
          git_system('rebase --abort')
          os.remove(patch_file)
          return
        end

        -- Step 3: リベース継続
        local continue_result = git_system('rebase --continue 2>&1')

        if not (continue_result:match('Successfully rebased') or vim.v.shell_error == 0) then
          print('Rebase continue failed (conflict?): ' .. continue_result:sub(1, 100))
          git_system('rebase --abort')
          os.remove(patch_file)
          return
        end

        -- Step 4: ワーキングツリーをクリーンな状態にリセット
        git_system('checkout HEAD -- ' .. vim.fn.shellescape(filepath))

        -- Step 5: 削除した変更をインデックスに復元（逆パッチを適用）
        local forward_patch_lines = {
          'diff --git a/' .. filepath .. ' b/' .. filepath,
          'index 0000000..0000000 100644',
          '--- a/' .. filepath,
          '+++ b/' .. filepath,
          '@@ -' .. start_line .. ',0 +' .. start_line .. ',' .. (end_line - start_line + 1) .. ' @@',
        }

        for i = start_line, end_line do
          local commit_line = commit_lines[i - start_line + 1] or ''
          table.insert(forward_patch_lines, '+' .. commit_line)
        end

        local forward_patch_file = vim.fn.tempname()
        local f2 = io.open(forward_patch_file, 'w')
        if f2 then
          f2:write(table.concat(forward_patch_lines, '\n') .. '\n')
          f2:close()

          local restore_cmd = git_cmd('apply --unidiff-zero ' .. vim.fn.shellescape(forward_patch_file))
            .. ' && '
            .. git_cmd('add ' .. vim.fn.shellescape(filepath) .. ' 2>&1')
          local restore_result = vim.fn.system(restore_cmd)
          os.remove(forward_patch_file)

          if vim.v.shell_error == 0 then
            print('Reverted ' .. (end_line - start_line + 1) .. ' lines in ' .. commit:sub(1, 7) .. ' and staged')
          else
            print('Staging failed: ' .. restore_result:sub(1, 80))
          end
        end

        os.remove(patch_file)
        vim.cmd('checktime')
      end, { buffer = ev.buf, silent = true, desc = 'Revert lines and stage' })

      -- df: ファイル全体の変更を対象コミットから取り除き、後続へ反映
      vim.keymap.set('n', 'df', function()
        local stashed = utils.auto_stash(work_tree, {
          message = "fugitive-ext blob auto-stash",
          keep_index = true,
          notify_stashed = true,
        })
        if stashed == nil then return end

        local parent_result = git_systemlist(
          'log --format=%H --skip=1 -n 1 ' .. vim.fn.shellescape(commit) .. ' -- ' .. vim.fn.shellescape(filepath)
        )
        local parent_commit = commit .. '^'
        if parent_result and #parent_result > 0 and parent_result[1] ~= '' then
          parent_commit = parent_result[1]
        end

        -- Step 1: rebase -i edit
        local rebase_cmd = 'GIT_SEQUENCE_EDITOR='
          .. vim.fn.shellescape("sed -i '/" .. commit:sub(1, 7) .. "/s/^pick/edit/'")
          .. ' '
          .. git_cmd('rebase -i ' .. vim.fn.shellescape(commit .. '^') .. ' 2>&1')
        local rebase_result = vim.fn.system(rebase_cmd)
        if not rebase_result:match('Stopped at') then
          vim.notify('Rebase failed: ' .. rebase_result:sub(1, 120), vim.log.levels.ERROR)
          if stashed then utils.pop_auto_stash(work_tree, { notify_popped = true }) end
          return
        end

        -- Step 2: 親の状態に戻して amend
        local restore_cmd = git_cmd(
          'checkout ' .. vim.fn.shellescape(parent_commit) .. ' -- ' .. vim.fn.shellescape(filepath)
        )
          .. ' && '
          .. git_cmd('add ' .. vim.fn.shellescape(filepath))
          .. ' && '
          .. git_cmd('commit --amend --no-edit 2>&1')
        local restore_result = vim.fn.system(restore_cmd)
        if vim.v.shell_error ~= 0 then
          vim.notify('Amend failed: ' .. restore_result:sub(1, 120), vim.log.levels.ERROR)
          git_system('rebase --abort')
          if stashed then utils.pop_auto_stash(work_tree, { notify_popped = true }) end
          return
        end

        -- Step 3: rebase --continue
        local continue_result = git_system('rebase --continue 2>&1')
        if not (continue_result:match('Successfully rebased') or vim.v.shell_error == 0) then
          vim.notify('Rebase continue failed: ' .. continue_result:sub(1, 120), vim.log.levels.ERROR)
          git_system('rebase --abort')
          if stashed then utils.pop_auto_stash(work_tree, { notify_popped = true }) end
          return
        end

        -- Step 4: ワークツリーをHEADに揃える
        git_system('checkout HEAD -- ' .. vim.fn.shellescape(filepath))

        if stashed then utils.pop_auto_stash(work_tree, { notify_popped = true }) end
        vim.cmd('checktime')
        vim.notify('Removed file changes from commit ' .. commit:sub(1, 7), vim.log.levels.INFO)
      end, { buffer = ev.buf, silent = true, desc = 'Drop file changes from commit' })

      vim.keymap.set('n', 'q', function()
        vim.cmd('tabclose')
      end, { buffer = ev.buf, nowait = true, silent = true })
    end,
  })
end

return M

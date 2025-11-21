return {
  "rbong/vim-flog",
  cmd = { "Flog", "Flogsplit", "Floggit" },
  config = function()
    vim.g.flog_enable_dynamic_commit_hl = true
    vim.g.flog_enable_extended_chars = true

    vim.g.flog_default_opts = {
      format = '%ad %an [%h]%d%n%s',
      date = 'short',
      max_count = 2000
    }

    vim.api.nvim_create_autocmd('FileType', {
      pattern = 'floggraph',
      callback = function()
        vim.opt_local.list = false
        vim.opt_local.number = false

        vim.api.nvim_set_hl(0, 'flogBranch1', { fg = '#8aa872', bold = true })  -- Green
        vim.api.nvim_set_hl(0, 'flogBranch2', { fg = '#d6746f', bold = true })  -- Orange
        vim.api.nvim_set_hl(0, 'flogBranch3', { fg = '#d84f76', bold = true })  -- Red
        vim.api.nvim_set_hl(0, 'flogBranch4', { fg = '#d871a6', bold = true })  -- Violet
        vim.api.nvim_set_hl(0, 'flogBranch5', { fg = '#e6a852', bold = true })  -- Yellow
        vim.api.nvim_set_hl(0, 'flogBranch6', { fg = '#7bb8c1', bold = true })  -- Cyan
        vim.api.nvim_set_hl(0, 'flogBranch7', { fg = '#4a869c', bold = true })  -- Blue
        -- ハッシュ - 黄色
        vim.api.nvim_set_hl(0, 'flogHash', { fg = '#586e75' })
        -- 著者名 - シアン
        vim.api.nvim_set_hl(0, 'flogAuthor', { fg = '#e6a852' })
        -- 日付 - グレー
        vim.api.nvim_set_hl(0, 'flogDate', { fg = '#7bb8c1' })
        -- ブランチ/タグ - マゼンタ
        vim.api.nvim_set_hl(0, 'flogRef', { fg = '#d871a6' })

        -- X: Drop commits (works with visual selection)
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
              vim.api.nvim_win_set_cursor(0, {line, 0})
              local hash = vim.fn['flog#Format']("%H")
              if hash and hash ~= '' and not vim.tbl_contains(commits, hash) then
                table.insert(commits, hash)
              end
            end

            -- Restore cursor
            vim.api.nvim_win_set_cursor(0, saved_cursor)
          else
            -- Normal mode - get current commit
            local format_cmd = vim.fn['flog#Format']("%H")
            table.insert(commits, format_cmd)
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
            vim.notify('Successfully dropped commits\nOutput: ' .. output, vim.log.levels.INFO)
            -- Force reload flog
            vim.schedule(function()
              vim.cmd('normal u')
            end)
          end
        end, { buffer = true, silent = true, desc = 'Drop commit(s)' })
      end,
    })

    -- flogのサイドウインドウを左に開く
    vim.api.nvim_create_autocmd('User', {
      pattern = 'FlogSideWinSetup',
      callback = function()
        vim.schedule(function()
          if not (vim.g.flog_win and vim.api.nvim_win_is_valid(vim.g.flog_win)) then
            return
          end

          -- 再描画を一時的に無効化してちらつきを防ぐ
          local lazyredraw = vim.o.lazyredraw
          vim.o.lazyredraw = true

          -- すべてのウインドウをチェック
          local all_wins = vim.api.nvim_tabpage_list_wins(0)
          local flog_pos = vim.api.nvim_win_get_position(vim.g.flog_win)

          -- flogウインドウと同じ行で、左にあるウインドウを見つける
          local left_win = nil
          for _, win in ipairs(all_wins) do
            local pos = vim.api.nvim_win_get_position(win)
            -- 同じ行（row）で、列（col）が左にあるウインドウ
            if pos[1] == flog_pos[1] and pos[2] < flog_pos[2] then
              left_win = win
              break
            end
          end

          if not left_win then
            vim.o.lazyredraw = lazyredraw
            return
          end

          -- 新しく開かれたサイドウインドウを見つける（flogでも左ウインドウでもない）
          local side_win = nil
          -- まずflogと同じ行を探す（diffなど）
          for _, win in ipairs(all_wins) do
            local pos = vim.api.nvim_win_get_position(win)
            if win ~= vim.g.flog_win and win ~= left_win and pos[1] == flog_pos[1] then
              side_win = win
              break
            end
          end
          -- 見つからなければ、flogの下を探す（rebaseなど）
          if not side_win then
            for _, win in ipairs(all_wins) do
              local pos = vim.api.nvim_win_get_position(win)
              if win ~= vim.g.flog_win and win ~= left_win and pos[1] > flog_pos[1] then
                side_win = win
                break
              end
            end
          end

          if side_win and vim.api.nvim_win_is_valid(side_win) then
            local new_bufnr = vim.api.nvim_win_get_buf(side_win)
            local filetype = vim.bo[new_bufnr].filetype

            -- バッファタイプで処理を分岐
            if filetype == 'git' then
              -- diffなどの通常バッファ（flogと同じ行に開く）
              vim.api.nvim_win_set_buf(left_win, new_bufnr)
              vim.api.nvim_win_close(side_win, true)
              vim.api.nvim_win_set_width(vim.g.flog_win, 60)
              vim.api.nvim_set_current_win(left_win)
            else
              -- rebase-todoなどのnowriteバッファ（flogの下に開く）
              vim.api.nvim_win_set_buf(left_win, new_bufnr)
              vim.api.nvim_win_close(side_win, true)
              vim.api.nvim_set_current_win(left_win)
            end
          end

          -- 再描画を元に戻して画面を更新
          vim.o.lazyredraw = lazyredraw
          vim.cmd('redraw')
        end)
      end,
    })
  end,
}

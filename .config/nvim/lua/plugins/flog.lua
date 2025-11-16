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

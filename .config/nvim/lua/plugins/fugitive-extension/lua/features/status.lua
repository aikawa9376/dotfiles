local M = {}
local utils = require("utils")

function M.setup(group)
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'fugitive',
    callback = function(ev)
      -- 行番号を非表示
      vim.opt_local.number = false
      vim.opt_local.relativenumber = false

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
        end

        local filepath = line:match('^[MADRCU?!][MADRCU?!]? (.+)$')
        if filepath then
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

      vim.keymap.set('n', 'q', function()
        if vim.g.flog_win and vim.api.nvim_win_is_valid(vim.g.flog_win) then
          vim.api.nvim_win_close(vim.g.flog_win, true)
        end
        vim.cmd('q')
      end, { buffer = ev.buf, nowait = true, silent = true, desc = 'Close status and Flog window' })
    end,
  })
end

return M

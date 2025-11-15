return {
  "tpope/vim-fugitive",
  cmd = {
    "G", "Git", "Gdiff", "Gwrite", "Gread", "Gdiffsplit",
    "Gedit", "Gcd", "Gclog", "GeditHeadAtFile", "Gvsplit"
  },
  keys = {
    { "<Leader>gs", "<cmd>Git<CR>", silent = true },
    { "<Leader>gg", "<cmd>GeditHeadAtFile<CR>", silent = true },
    { "<Leader>gb", "<cmd>Git blame -w --date=format:'%Y-%m-%d %H:%M'<CR>", silent = true },
    { "<Leader>gp", "<cmd>Git! push --force-with-lease<CR>", silent = true },
    { "<Leader>gr", "<cmd>Git! rm --cached %<CR>", silent = true },
    { "<Leader>gM", "<cmd>Git! commit -m 'tmp'<CR>", silent = true },
    { "<Leader>gA", "<cmd>Gwrite<CR>", silent = true },
  },
  config = function()
    local group = vim.api.nvim_create_augroup('fugitive_custom', { clear = true })

    -- ------------------------------------------------------------------
    -- fugitive status view settings
    -- ------------------------------------------------------------------
    vim.api.nvim_create_autocmd('FileType', {
      group = group,
      pattern = 'fugitive',
      callback = function(ev)
        -- 行番号を非表示
        vim.opt_local.number = false
        vim.opt_local.relativenumber = false

        -- カーソル位置から上に遡ってファイル名を探す
        local function get_filepath_at_cursor()
          local current_line = vim.api.nvim_win_get_cursor(0)[1]
          for lnum = current_line, 1, -1 do
            local line = vim.api.nvim_buf_get_lines(ev.buf, lnum - 1, lnum, false)[1]
            if line then
              local match = line:match('^[MADRCU?!][MADRCU?!]? (.+)$')
              if match then return match end
            end
          end
        end

        vim.keymap.set('n', 'dd', function()
          local file_path = get_filepath_at_cursor()
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
                vim.api.nvim_win_set_cursor(0, {target_line, 0})
                vim.cmd('normal! zz')
              end)
            end
          end)
        end, { buffer = ev.buf, nowait = true, silent = true, desc = 'Open file diff in new tab' })

        -- deviconsでファイル名に色とアイコンを付ける
        local ok, devicons = pcall(require, 'nvim-web-devicons')
        if ok then
          local ns_id = vim.api.nvim_create_namespace('fugitive_status_icons')
          vim.api.nvim_buf_clear_namespace(ev.buf, ns_id, 0, -1)

          local lines = vim.api.nvim_buf_get_lines(ev.buf, 0, -1, false)
          for idx, line in ipairs(lines) do
            local filepath = line:match('^[MADRCU?!][MADRCU?!]? (.+)$')
            if filepath then
              local icon, icon_hl = devicons.get_icon(filepath, vim.fn.fnamemodify(filepath, ":e"), { default = true })
              if icon and icon_hl then
                -- ファイル名全体に色を適用
                local filename_start = line:find(filepath, 1, true)
                if filename_start then
                  vim.api.nvim_buf_set_extmark(ev.buf, ns_id, idx - 1, filename_start - 1, {
                    end_col = filename_start - 1 + #filepath,
                    hl_group = icon_hl,
                  })
                  -- virtual textでアイコンをファイル名の直前に表示
                  vim.api.nvim_buf_set_extmark(ev.buf, ns_id, idx - 1, filename_start - 1, {
                    virt_text = {{ icon .. ' ', icon_hl }},
                    virt_text_pos = 'inline',
                  })
                end
              end
            end
          end
        end
      end,
    })

    -- ------------------------------------------------------------------
    -- fugitive blame view settings
    -- ------------------------------------------------------------------

    local function setup_blame_gradients()
      local colors = {
        { name = 'FugitiveBlameDate0', fg = '#50c878' },  -- 緑（最新）より明るく
        { name = 'FugitiveBlameDate1', fg = '#70cd80' },
        { name = 'FugitiveBlameDate2', fg = '#90d288' },
        { name = 'FugitiveBlameDate3', fg = '#b0d790' },
        { name = 'FugitiveBlameDate4', fg = '#d0dc98' },
        { name = 'FugitiveBlameDate5', fg = '#f0e1a0' },
        { name = 'FugitiveBlameDate6', fg = '#ffc580' },
        { name = 'FugitiveBlameDate7', fg = '#ffb060' },
        { name = 'FugitiveBlameDate8', fg = '#ff9b40' },
        { name = 'FugitiveBlameDate9', fg = '#ff8620' },
        { name = 'FugitiveBlameDate10', fg = '#ff7100' },
        { name = 'FugitiveBlameDate11', fg = '#e85040' },
        { name = 'FugitiveBlameDate12', fg = '#d03030' }, -- 赤（古い）より濃く
      }
      for _, color in ipairs(colors) do
        vim.api.nvim_set_hl(0, color.name, { fg = color.fg })
      end
    end
    setup_blame_gradients()

    -- グラデーションモード: 'absolute' または 'relative'
    vim.g.fugitive_blame_gradient_mode = vim.g.fugitive_blame_gradient_mode or 'absolute'

    local function apply_blame_gradient(bufnr)
      local ns_id = vim.api.nvim_create_namespace('fugitive_blame_gradient')
      vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

      if vim.g.fugitive_blame_gradient_mode == 'absolute' then
        -- 絶対モード: 現在の日付から何ヶ月前かで判定
        local now = os.time()

        for idx, line in ipairs(lines) do
          local date_start, date_end = line:find('%d%d%d%d%-%d%d%-%d%d %d%d:%d%d')
          if date_start then
            local y, m, d, h, min = line:match('(%d%d%d%d)%-(%d%d)%-(%d%d) (%d%d):(%d%d)')
            if y then
              local commit_time = os.time({year=tonumber(y), month=tonumber(m), day=tonumber(d), hour=tonumber(h), min=tonumber(min)})
              local diff_months = math.floor((now - commit_time) / (30 * 24 * 60 * 60))

              -- 2ヶ月ごとに色を変える（0-24ヶ月を13段階に）
              local color_idx = math.min(math.floor(diff_months / 2), 12)

              vim.api.nvim_buf_set_extmark(bufnr, ns_id, idx - 1, date_start - 1, {
                end_col = date_end,
                hl_group = 'FugitiveBlameDate' .. color_idx,
              })
            end
          end
        end
      else
        -- 相対モード: ファイル内の最古と最新の日付を基準に
        local dates = {}

        for _, line in ipairs(lines) do
          local date = line:match('%d%d%d%d%-%d%d%-%d%d')
          if date then
            table.insert(dates, date)
          end
        end

        table.sort(dates)
        local oldest_date = dates[1]
        local newest_date = dates[#dates]

        if oldest_date and newest_date then
          local function date_to_days(date_str)
            local y, m, d = date_str:match('(%d%d%d%d)%-(%d%d)%-(%d%d)')
            return tonumber(y) * 365 + tonumber(m) * 30 + tonumber(d)
          end

          local oldest_days = date_to_days(oldest_date)
          local newest_days = date_to_days(newest_date)
          local range = newest_days - oldest_days

          for idx, line in ipairs(lines) do
            local date_start, date_end = line:find('%d%d%d%d%-%d%d%-%d%d %d%d:%d%d')
            if date_start then
              local date = line:match('%d%d%d%d%-%d%d%-%d%d')
              local days = date_to_days(date)

              local color_idx
              if range == 0 then
                color_idx = 0
              else
                local ratio = (days - oldest_days) / range
                color_idx = math.floor((1 - ratio) * 12)
              end

              vim.api.nvim_buf_set_extmark(bufnr, ns_id, idx - 1, date_start - 1, {
                end_col = date_end,
                hl_group = 'FugitiveBlameDate' .. color_idx,
              })
            end
          end
        end
      end
    end

    vim.api.nvim_create_autocmd('FileType', {
      group = group,
      pattern = 'fugitiveblame',
      callback = function(ev)
        apply_blame_gradient(ev.buf)

        vim.keymap.set('n', 'c', function()
          vim.g.fugitive_blame_gradient_mode = vim.g.fugitive_blame_gradient_mode == 'absolute' and 'relative' or 'absolute'
          apply_blame_gradient(ev.buf)
          print('Blame gradient mode: ' .. vim.g.fugitive_blame_gradient_mode)
        end, { buffer = ev.buf, nowait = true, silent = true })

        vim.keymap.set('n', 'd', function()
          local commit = vim.api.nvim_get_current_line():match('^(%x+)')
          if not commit then return end

          vim.cmd.wincmd('p')
          local file_path = vim.fn.expand('%:.'):match('//[%x]+/(.+)$') or vim.fn.expand('%:.')
          local line_num = vim.api.nvim_win_get_cursor(0)[1]
          local target_line = vim.api.nvim_buf_get_lines(0, line_num - 1, line_num, false)[1]
          vim.cmd.wincmd('p')

          local rev = commit:match('^0+$') and ':' or commit .. '^:'
          local fugitive_path = vim.fn.FugitiveFind(rev .. file_path)
          local existing_buf = vim.fn.bufnr(fugitive_path)

          vim.cmd(existing_buf ~= -1 and 'tabedit #' .. existing_buf or 'tabedit ' .. fugitive_path)
          vim.cmd(commit:match('^0+$') and 'Gvdiffsplit' or 'Gvdiffsplit ' .. commit)

          local found_line = 1
          local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
          for i, line in ipairs(lines) do
            if line == target_line then
              found_line = i
              break
            end
          end
          vim.cmd.normal({ found_line .. 'Gzz', bang = true })
        end, { buffer = ev.buf, nowait = true, silent = true })
      end,
    })

    -- ------------------------------------------------------------------
    -- fugitive commit detail view settings
    -- ------------------------------------------------------------------
    _G.fugitive_foldtext = function ()
      local line = vim.fn.getline(vim.v.foldstart)
      local filename = line:match("^diff %-%-git [ab]/(.+) [ab]/") or line:match("^(%S+)") or "folding"

      local icon, icon_hl = " ", "Normal"
      local ok, devicons = pcall(require, 'nvim-web-devicons')
      if ok then
        local file_icon, hl = devicons.get_icon(filename, vim.fn.fnamemodify(filename, ":e"), { default = true })
        if file_icon then
          icon, icon_hl = file_icon, hl or "Normal"
        end
      end

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

      if added > 0 then table.insert(result, { " +" .. added, "GitSignsAdd" }) end
      if changed > 0 then table.insert(result, { " ~" .. changed, "GitSignsChange" }) end
      if removed > 0 then table.insert(result, { " -" .. removed, "GitSignsDelete" }) end

      return result
    end

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
        local function get_filepath_at_cursor()
          local current_line = vim.api.nvim_win_get_cursor(0)[1]
          for lnum = current_line, 1, -1 do
            local line = vim.api.nvim_buf_get_lines(ev.buf, lnum - 1, lnum, false)[1]
            if line then
              local match = line:match('^diff %-%-git [ab]/(.+) [ab]/')
              if match then return match end
            end
          end
        end

        local function get_commit()
          local result = vim.fn.FugitiveParse(vim.api.nvim_buf_get_name(ev.buf))
          return result and result[1] or nil
        end

        -- Flogウィンドウのハイライト設定
        local function setup_flog_window(win, bufnr)
          vim.wo[win].wrap = false
          vim.wo[win].number = false
          vim.wo[win].relativenumber = false
          vim.wo[win].signcolumn = 'no'
          vim.wo[win].cursorline = false
          vim.wo[win].winhighlight = 'NormalNC:Normal'

          -- qでタブごと閉じる
          vim.keymap.set('n', 'q', function()
            vim.cmd('tabclose')
          end, { buffer = bufnr, nowait = true, silent = true })
        end

        -- Flogハイライト更新
        local function update_flog_highlight()
          if not (vim.g.flog_win and vim.api.nvim_win_is_valid(vim.g.flog_win) and vim.g.flog_bufnr and vim.api.nvim_buf_is_valid(vim.g.flog_bufnr)) then
            return
          end

          local commit = get_commit()
          if not commit then return end

          local ns_id = vim.api.nvim_create_namespace('GeditHeadAtFileHighlight')
          vim.api.nvim_buf_clear_namespace(vim.g.flog_bufnr, ns_id, 0, -1)
          local lines = vim.api.nvim_buf_get_lines(vim.g.flog_bufnr, 0, -1, false)
          for idx, line in ipairs(lines) do
            if line:match(commit:sub(1, 7)) then
              vim.api.nvim_buf_set_extmark(vim.g.flog_bufnr, ns_id, idx - 1, 0, {
                end_col = #line,
                hl_group = 'Search',
                hl_mode = 'combine'
              })
              vim.api.nvim_win_call(vim.g.flog_win, function()
                vim.api.nvim_win_set_cursor(vim.g.flog_win, {idx, 0})
                vim.cmd('normal! zt5k')
              end)
              break
            end
          end
        end

        -- BufEnter時にハイライト更新
        vim.api.nvim_create_autocmd('BufEnter', {
          buffer = ev.buf,
          callback = function()
            vim.schedule(update_flog_highlight)
          end,
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

            setup_flog_window(vim.g.flog_win, vim.g.flog_bufnr)
            update_flog_highlight()
            vim.api.nvim_set_current_win(current_win)
          end
        end, { buffer = ev.buf, nowait = true, silent = true, desc = 'Toggle Flog window' })

        -- d: Diffview
        vim.keymap.set('n', 'd', function()
          local commit = get_commit()
          if not commit then return end
          local filepath = get_filepath_at_cursor()

          vim.schedule(function()
            if filepath then
              vim.cmd('DiffviewOpen ' .. commit .. '^..' .. commit .. ' --selected-file=' .. filepath)
            else
              vim.cmd('DiffviewOpen ' .. commit .. '^..' .. commit)
            end
          end)
        end, { buffer = ev.buf, nowait = true, silent = true })

        -- p: 前のコミット
        vim.keymap.set('n', 'p', function()
          local commit = get_commit()
          if not commit then return end
          local filepath = get_filepath_at_cursor()
          if not filepath then return end

          local result = vim.fn.systemlist('git log --format=%H --skip=1 -n 1 ' .. commit .. ' -- ' .. vim.fn.shellescape(filepath))
          if not result or #result == 0 or result[1] == '' then
            print('No previous commit found for ' .. filepath)
            return
          end

          vim.schedule(function()
            vim.cmd('Gedit ' .. result[1])
            vim.schedule(function()
              local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
              for i, line in ipairs(lines) do
                if line:match('^diff %-%-git [ab]/' .. vim.pesc(filepath) .. ' ') then
                  vim.api.nvim_win_set_cursor(0, {i, 0})
                  vim.cmd('normal! zO')
                  break
                end
              end
            end)
          end)
        end, { buffer = ev.buf, nowait = true, silent = true })

        -- O: Octo PR
        vim.keymap.set('n', 'O', function()
          local commit = get_commit()
          if not commit then return end
          vim.cmd('OctoPrFromSha ' .. commit)
        end, { buffer = ev.buf, nowait = true, silent = true, noremap = true })

        -- Ctrl-y: コミットハッシュをクリップボードにコピー
        vim.keymap.set('n', '<C-y>', function()
          local commit = get_commit()
          if not commit then
            print('No commit found')
            return
          end
          local short_commit = commit:sub(1, 7)
          vim.fn.setreg('+', short_commit)
          vim.fn.setreg('"', short_commit)
          print('Copied: ' .. short_commit)
        end, { buffer = ev.buf, nowait = true, silent = true })

        vim.keymap.set('n', 'R', function()
          local cursor_commit = vim.api.nvim_get_current_line():match('^(%x+)')
          vim.cmd('G reset --mixed ' .. cursor_commit)
        end, { buffer = ev.buf, nowait = true, silent = true })
      end,
    })

    -- ------------------------------------------------------------------
    -- fugitive blob settings
    -- ------------------------------------------------------------------
    vim.api.nvim_create_autocmd('BufReadPost', {
      group = group,
      pattern = 'fugitive://*/*.git//*/**',
      callback = function(ev)
        local bufname = vim.api.nvim_buf_get_name(ev.buf)
        local parse = vim.fn.FugitiveParse(bufname)
        if not parse or not parse[1] then return end
        local commit, filepath = parse[1]:match('^(%x+):(.+)$')
        if not commit or not filepath then return end

        vim.keymap.set('n', 'p', function()
          local current_pos = vim.api.nvim_win_get_cursor(0)
          local result = vim.fn.systemlist('git log --format=%H --skip=1 -n 1 ' .. commit .. ' -- ' .. vim.fn.shellescape(filepath))
          if result and #result > 0 and result[1] ~= '' then
            vim.cmd('Gedit ' .. result[1] .. ':' .. filepath)
            vim.schedule(function()
              local line_count = vim.api.nvim_buf_line_count(0)
              local target_line = math.min(current_pos[1], line_count)
              vim.api.nvim_win_set_cursor(0, {target_line, current_pos[2]})
            end)
          else
            print('No previous commit found for ' .. filepath)
          end
        end, { buffer = ev.buf, nowait = true, silent = true })

        local ns_id = vim.api.nvim_create_namespace("FugitiveDiffDim")
        local dim_enabled = false
        vim.keymap.set('n', 'dd', function()
          if dim_enabled then
            vim.api.nvim_buf_clear_namespace(ev.buf, ns_id, 0, -1)
            dim_enabled = false
            print('Diff highlight cleared')
          else
            local parent_result = vim.fn.systemlist('git log --format=%H --skip=1 -n 1 ' .. commit .. ' -- ' .. vim.fn.shellescape(filepath))
            local parent_commit = parent_result and #parent_result > 0 and parent_result[1] ~= '' and parent_result[1] or commit .. '^'

            local diff_output = vim.fn.systemlist('git diff --unified=0 ' .. parent_commit .. ' ' .. commit .. ' -- ' .. vim.fn.shellescape(filepath))
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

          local parent_lines = vim.fn.systemlist('git show ' .. commit .. '^:' .. vim.fn.shellescape(filepath) .. ' 2>/dev/null')
          if vim.v.shell_error ~= 0 then parent_lines = {} end

          local commit_lines = vim.api.nvim_buf_get_lines(ev.buf, start_line - 1, end_line, false)

          local patch_lines = {
            'diff --git a/' .. filepath .. ' b/' .. filepath,
            'index 0000000..0000000 100644',
            '--- a/' .. filepath,
            '+++ b/' .. filepath,
          }

          local has_changes = false
          for i = start_line, end_line do
            local parent_line = parent_lines[i] or ''
            local commit_line = commit_lines[i - start_line + 1] or ''
            if commit_line ~= parent_line then
              table.insert(patch_lines, '@@ -' .. i .. ',1 +' .. i .. ',1 @@')
              table.insert(patch_lines, '-' .. commit_line)
              table.insert(patch_lines, '+' .. parent_line)
              has_changes = true
            end
          end

          if not has_changes then
            print('No changes to revert')
            return
          end

          local patch_file = vim.fn.tempname()
          local f = io.open(patch_file, 'w')
          if not f then return end
          f:write(table.concat(patch_lines, '\n') .. '\n')
          f:close()

          local git_dir = vim.fn.FugitiveWorkTree()

          -- Step 1: インタラクティブリベースで対象コミットを編集モードに
          local rebase_cmd = 'cd ' .. vim.fn.shellescape(git_dir) ..
            " && GIT_SEQUENCE_EDITOR=\"sed -i '/" .. commit:sub(1,7) .. "/s/^pick/edit/'\" git rebase -i " .. commit .. '^ 2>&1'
          local rebase_result = vim.fn.system(rebase_cmd)

          if not rebase_result:match('Stopped at') then
            print('Rebase failed: ' .. rebase_result:sub(1, 100))
            os.remove(patch_file)
            return
          end

          -- Step 2: パッチを適用してコミットから変更を削除
          local apply_cmd = 'cd ' .. vim.fn.shellescape(git_dir) ..
            ' && git apply --unidiff-zero ' .. vim.fn.shellescape(patch_file) ..
            ' && git add ' .. vim.fn.shellescape(filepath) ..
            ' && git commit --amend --no-edit 2>&1'
          local apply_result = vim.fn.system(apply_cmd)

          if vim.v.shell_error ~= 0 then
            print('Apply failed (conflict?): ' .. apply_result:sub(1, 100))
            vim.fn.system('cd ' .. vim.fn.shellescape(git_dir) .. ' && git rebase --abort')
            os.remove(patch_file)
            return
          end

          -- Step 3: リベース継続
          local continue_result = vim.fn.system('cd ' .. vim.fn.shellescape(git_dir) .. ' && git rebase --continue 2>&1')

          if not (continue_result:match('Successfully rebased') or vim.v.shell_error == 0) then
            print('Rebase continue failed (conflict?): ' .. continue_result:sub(1, 100))
            vim.fn.system('cd ' .. vim.fn.shellescape(git_dir) .. ' && git rebase --abort')
            os.remove(patch_file)
            return
          end

          -- Step 4: ワーキングツリーをクリーンな状態にリセット
          vim.fn.system('cd ' .. vim.fn.shellescape(git_dir) .. ' && git checkout HEAD -- ' .. vim.fn.shellescape(filepath))

          -- Step 5: 削除した変更をインデックスに復元（逆パッチを適用）
          local forward_patch_lines = {}
          for _, line in ipairs(patch_lines) do
            if line:match('^%-') and not line:match('^%-%-%-') then
              table.insert(forward_patch_lines, '+' .. line:sub(2))
            elseif line:match('^%+') and not line:match('^%+%+%+') then
              table.insert(forward_patch_lines, '-' .. line:sub(2))
            else
              table.insert(forward_patch_lines, line)
            end
          end

          local forward_patch_file = vim.fn.tempname()
          local f2 = io.open(forward_patch_file, 'w')
          if f2 then
            f2:write(table.concat(forward_patch_lines, '\n') .. '\n')
            f2:close()

            local restore_cmd = 'cd ' .. vim.fn.shellescape(git_dir) ..
              ' && git apply --unidiff-zero ' .. vim.fn.shellescape(forward_patch_file) ..
              ' && git add ' .. vim.fn.shellescape(filepath) .. ' 2>&1'
            local restore_result = vim.fn.system(restore_cmd)
            os.remove(forward_patch_file)

            if vim.v.shell_error == 0 then
              print('Reverted ' .. (end_line - start_line + 1) .. ' lines in ' .. commit:sub(1,7) .. ' and staged')
            else
              print('Staging failed: ' .. restore_result:sub(1, 80))
            end
          end

          os.remove(patch_file)
          vim.cmd('checktime')
        end, { buffer = ev.buf, silent = true, desc = 'Revert lines and stage' })

        vim.keymap.set('n', 'q', function() vim.cmd('tabclose') end, { buffer = ev.buf, nowait = true, silent = true })
      end,
    })

    -- ------------------------------------------------------------------
    -- fugitive command settings
    -- ------------------------------------------------------------------
    vim.api.nvim_create_user_command('GeditHeadAtFile', function()
      local filepath = vim.fn.expand('%:.')
      if filepath == '' then
        print('No file in current buffer')
        return
      end

      local handle = io.popen('git ls-files --full-name ' .. vim.fn.shellescape(filepath) .. ' 2>/dev/null')
      if not handle then return end
      local git_filepath = handle:read('*a'):gsub('\n', '')
      handle:close()

      if git_filepath == '' then
        print('File not tracked by git: ' .. filepath)
        return
      end

      local commit_handle = io.popen('git log --format=%H -n 1 -- ' .. vim.fn.shellescape(git_filepath) .. ' 2>/dev/null')
      if not commit_handle then return end
      local latest_commit = commit_handle:read('*a'):gsub('\n', '')
      commit_handle:close()

      if latest_commit == '' then
        print('No commits found for: ' .. git_filepath)
        return
      end

      vim.schedule(function()
        local fugitive_path = vim.fn.FugitiveFind(latest_commit)
        local existing_buf = vim.fn.bufnr(fugitive_path)
        local is_listed = existing_buf ~= -1 and vim.fn.getbufvar(existing_buf, '&buflisted') == 1 or false
        vim.cmd(existing_buf ~= -1 and is_listed and 'tabedit #' .. existing_buf or 'tabedit | silent! Gedit ' .. latest_commit)

        vim.schedule(function()
          local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
          for i, line in ipairs(lines) do
            if line:match('^diff %-%-git [ab]/' .. vim.pesc(git_filepath) .. ' ') then
              vim.api.nvim_win_set_cursor(0, {i, 0})
              vim.cmd('normal! zO')
              break
            end
          end
        end)
      end)
    end, {})
  end
}

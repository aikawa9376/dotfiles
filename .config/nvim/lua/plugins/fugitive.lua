return {
  "tpope/vim-fugitive",
  cmd = {
    "Git", "Gdiff", "Gwrite", "Gread", "Gdiffsplit",
    "Gedit", "Gcd", "Gclog", "GeditHeadAtFile",
  },
  keys = {
    { "<Leader>gs", "<cmd>Git<CR>", silent = true },
    { "<Leader>gg", "<cmd>GeditHeadAtFile<CR>", silent = true },
    { "<Leader>gb", "<cmd>Git blame -w --date=format:'%Y-%m-%d %H:%M'<CR>", silent = true },
    { "<Leader>gp", "<cmd>Git! push<CR>", silent = true },
    { "<Leader>gr", "<cmd>Git! rm --cached %<CR>", silent = true },
    { "<Leader>gm", "<cmd>Git! commit -m 'update'<CR>", silent = true },
    { "<Leader>gA", "<cmd>Gwrite<CR>", silent = true },
  },
  config = function()
    local group = vim.api.nvim_create_augroup('fugitive_custom', { clear = true })

    -- ------------------------------------------------------------------
    -- fugitive blame view settings
    -- ------------------------------------------------------------------
    vim.api.nvim_create_autocmd('FileType', {
      group = group,
      pattern = 'fugitiveblame',
      callback = function(ev)
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
      end,
    })

    -- ------------------------------------------------------------------
    -- fugitive blob settings
    -- ------------------------------------------------------------------
    vim.api.nvim_create_autocmd('BufReadPost', {
      group = group,
      pattern = 'fugitive://*/*.git//*/**',
      callback = function(ev)
        local parse = vim.fn.FugitiveParse(vim.api.nvim_buf_get_name(ev.buf))
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
        vim.cmd(existing_buf ~= -1 and 'tabedit #' .. existing_buf or 'tabedit | silent! Gedit ' .. latest_commit)

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

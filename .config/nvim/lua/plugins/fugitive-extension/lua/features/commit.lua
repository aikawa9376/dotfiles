local M = {}
local utils = require("fugitive_utils")
local commands = require("features.commands")

local is_navigating = false

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

  return result
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
        vim.api.nvim_buf_clear_namespace(ev.buf, ns_id, 0, -1)

        local lines = vim.api.nvim_buf_get_lines(ev.buf, 0, -1, false)
        for idx, line in ipairs(lines) do
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

      local function update_flog_highlight()
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
        local commit = utils.get_commit(ev.buf)
        if commit == '' then
          commit = vim.api.nvim_get_current_line():match('^(%x+)')
        end
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
        local commit = utils.get_commit(ev.buf)
        if not commit then
          print('No commit found')
          return
        end

        commands.show_commit_info_float(commit, true, true)
      end, { buffer = ev.buf, nowait = true, silent = true, desc = 'Show commit info in float window' })

      -- p: カーソル位置ファイルの前のコミット
      vim.keymap.set('n', 'p', function()
        local commit = utils.get_commit(ev.buf)
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
        local commit = utils.get_commit(ev.buf)
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

      -- Ctrl-y: コミットハッシュをクリップボードにコピー
      vim.keymap.set('n', '<C-y>', function()
        local commit = utils.get_commit(ev.buf)
        if not commit then
          print('No commit found')
          return
        end
        local short_commit = commit:sub(1, 7)
        vim.fn.setreg('+', short_commit)
        vim.fn.setreg('"', short_commit)
        print('Copied: ' .. short_commit)
      end, { buffer = ev.buf, nowait = true, silent = true })

      -- <Leader>cf: 現在のコミットを一つ前のコミットにfixupする
      vim.keymap.set('n', '<Leader>cf', function()
        local current_line = vim.api.nvim_get_current_line()
        -- コミットハッシュを抽出（Unpushedセクションのコミット行から）
        local commit_hash = current_line:match('^(%x+)')

        if not commit_hash then
          vim.notify('No commit found at cursor', vim.log.levels.WARN)
          return
        end
        commands.fixup_commit(commit_hash)
      end, { buffer = ev.buf, nowait = true, silent = true, desc = 'Fixup this commit into its parent' })


      vim.keymap.set('n', '<Leader>R', function()
        local cursor_commit = vim.api.nvim_get_current_line():match('^(%x+)')
        vim.cmd('G reset --mixed ' .. cursor_commit)
      end, { buffer = ev.buf, nowait = true, silent = true })

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

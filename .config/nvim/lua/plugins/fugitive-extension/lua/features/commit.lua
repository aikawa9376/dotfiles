local M = {}
local utils = require("utils")

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

          utils.setup_flog_window(vim.g.flog_win, vim.g.flog_bufnr)
          update_flog_highlight()
          vim.api.nvim_set_current_win(current_win)
        end
      end, { buffer = ev.buf, nowait = true, silent = true, desc = 'Toggle Flog window' })

      -- d: Diffview
      vim.keymap.set('n', 'd', function()
        local commit = utils.get_commit(ev.buf)
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

      -- p: 前のコミット
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

        vim.schedule(function()
          vim.cmd('Gedit ' .. result[1])
          vim.schedule(function()
            local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
            for i, line in ipairs(lines) do
              if line:match('^diff %-%-git [ab]/' .. vim.pesc(filepath) .. ' ') then
                vim.api.nvim_win_set_cursor(0, { i, 0 })
                vim.cmd('normal! zO')
                break
              end
            end
          end)
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

      vim.keymap.set('n', 'R', function()
        local cursor_commit = vim.api.nvim_get_current_line():match('^(%x+)')
        vim.cmd('G reset --mixed ' .. cursor_commit)
      end, { buffer = ev.buf, nowait = true, silent = true })
    end,
  })
end

return M

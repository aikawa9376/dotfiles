return {
  "tpope/vim-fugitive",
  cmd = {
    "Git", "Gdiff", "Gwrite", "Gread", "Gdiffsplit",
    "Gedit", "Gcd", "Gclog"
  },
  keys = {
    { "<Leader>gs", "<cmd>Git<CR>", silent = true },
    { "<Leader>gb", "<cmd>Git blame -w --date=format:'%Y-%m-%d %H:%M'<CR>", silent = true },
    { "<Leader>gp", "<cmd>Git! push<CR>", silent = true },
    { "<Leader>gr", "<cmd>Git! rm --cached %<CR>", silent = true },
    { "<Leader>gm", "<cmd>Git! commit -m 'update'<CR>", silent = true },
    { "<Leader>gA", "<cmd>Gwrite<CR>", silent = true },
  },
  config = function()
    local group = vim.api.nvim_create_augroup('fugitive_custom', { clear = true })

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

      local result = {{ icon .. " ", icon_hl }, { filename, icon_hl }}
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
          vim.cmd.Gvdiffsplit(commit:match('^0+$') and '' or commit)

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

    vim.api.nvim_create_autocmd('FileType', {
      group = group,
      pattern = 'git',
      callback = function(ev)
        vim.keymap.set('n', 'd', function()
          local bufname = vim.api.nvim_buf_get_name(ev.buf)
          local commit = bufname:match('fugitive://.*%.git//(%x+)$')
          if not commit then return end

          local current_line = vim.api.nvim_win_get_cursor(0)[1]
          local filepath = nil

          for lnum = current_line, 1, -1 do
            local line = vim.api.nvim_buf_get_lines(ev.buf, lnum - 1, lnum, false)[1]
            if line then
              local match = line:match('^diff %-%-git [ab]/(.+) [ab]/')
              if match then
                filepath = match
                break
              end
            end
          end

          vim.schedule(function()
            if filepath then
              vim.cmd('DiffviewOpen ' .. commit .. '^..' .. commit .. ' --selected-file=' .. filepath)
            else
              vim.cmd('DiffviewOpen ' .. commit .. '^..' .. commit)
            end
          end)
        end, { buffer = ev.buf, nowait = true, silent = true })
      end,
    })
  end
}

return {
  "tpope/vim-fugitive",
  cmd = {
    "Git", "Gdiff", "Gwrite", "Gread", "Gdiffsplit",
    "Gedit", "GitAddCommit", "GitAddAmend", "Gcd"
  },
  keys = {
    { "<Leader>gs", "<cmd>Git<CR>", silent = true },
    { "<Leader>gb", "<cmd>Git blame -w --date=format:'%Y-%m-%d %H:%M'<CR>", silent = true },
    { "<Leader>gp", "<cmd>Git! push<CR>", silent = true },
    { "<Leader>gr", "<cmd>Git! rm --cached %<CR>", silent = true },
    { "<Leader>gm", "<cmd>Git! commit -m 'update'<CR>", silent = true },
    { "<Leader>gA", "<cmd>Gwrite<CR>", silent = true },
    { "<Leader>gM", "<cmd>GitAddCommit update<CR>", silent = true },
    { "<Leader>gU", "<cmd>GitAddAmend<CR>", silent = true },
  },
  config = function()
    vim.api.nvim_create_autocmd('FileType', {
      group = vim.api.nvim_create_augroup('fugitive_custom', { clear = true }),
      pattern = 'fugitiveblame',
      callback = function(ev)
        vim.keymap.set('n', 'd', function()
          local commit = vim.api.nvim_get_current_line():match('^(%x+)')
          if not commit then return end

          local blame_win = vim.api.nvim_get_current_win()

          vim.cmd.wincmd('p')
          local file_path = vim.fn.expand('%:.')
          local line_num = vim.api.nvim_win_get_cursor(0)[1]
          local target_line = vim.api.nvim_buf_get_lines(0, line_num - 1, line_num, false)[1]
          vim.api.nvim_set_current_win(blame_win)

          vim.cmd.tabnew()
          if commit:match('^0+$') then
            vim.cmd.Gedit(':' .. file_path)
            vim.cmd.Gvdiffsplit()
          elseif file_path ~= '' then
            vim.cmd.Gedit(commit .. '^:' .. file_path)
            vim.cmd.Gvdiffsplit(commit)
          end

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
  end
}

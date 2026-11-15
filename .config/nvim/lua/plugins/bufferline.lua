return {
  "akinsho/bufferline.nvim",
  event = "BufReadPre",
  opts = {
    options = {
      numbers = function(opts)
        return string.format('%s', opts.id)
      end,
      indicator = {
        -- Inactive buffers reserve one cell for the indicator too.
        icon = ' ',
        style = 'icon'
      },
      name_formatter = function(buf)
        if buf.bufnr and vim.b[buf.bufnr].git_object then
          return require('git.display').name(buf.bufnr)
        end
        local hash = buf.bufnr and vim.b[buf.bufnr].git_commit
        if hash then return hash:sub(1, 7) end
        if buf.name:match('%.md') then
          return vim.fn.fnamemodify(buf.name, ':t:r')
        end
      end,
      diagnostics = "false",
      custom_filter = function(buf_number)
        if vim.fn.match(vim.fn.bufname(buf_number), "term") == -1 then
          return true
        end
        if vim.fn.getcwd() == "<work-repo>" and vim.bo[buf_number].filetype ~= "wiki" then
          return true
        end
      end,
      offsets = { { filetype = "NvimTree", text = "File Explorer", text_align = "left" } },
      show_buffer_close_icons = false,
      show_close_icon = false,
      separator_style = { '', '' },
      sort_by = 'id',
    },
    highlights = {
      fill = {
        fg = '#002b36',
        bg = '#002b36',
      },
      background = {
        fg = '#E5E9F0',
        bg = '#002b36'
      },
      buffer_selected = {
        fg = '#88C0D0',
        bg = 'none',
        underline = false,
        bold = false,
        italic = false,
      },
      numbers_selected = { bold = false, italic = false },
      duplicate = { italic = false },
      duplicate_visible = { italic = false },
      duplicate_selected = { italic = false },
      pick = { bold = false, italic = false },
      pick_visible = { bold = false, italic = false },
      pick_selected = { bold = false, italic = false },
      tab_selected = {
        fg = '#88C0D0',
        bg = 'none',
        underline = false,
      },
    },
  },
}

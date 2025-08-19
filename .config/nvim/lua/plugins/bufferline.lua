return {
  "akinsho/bufferline.nvim",
  event = "BufReadPre",
  opts = {
    options = {
      numbers = function(opts)
        return string.format('%s', opts.id)
      end,
      indicator = {
        icon = '',
        style = 'icon'
      },
      name_formatter = function(buf)
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
        fg = 'none',
        bg = 'none',
      },
      background = {
        fg = '#E5E9F0',
        bg = 'none'
      },
      buffer_selected = {
        fg = '#88C0D0',
        bg = 'none',
        underline = false,
        italic = false
      },
    },
  }
}

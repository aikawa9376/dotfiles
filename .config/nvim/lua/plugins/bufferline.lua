require('bufferline').setup {
  options = {
    numbers = function(opts)
      return string.format('%s', opts.ordinal)
    end,
    close_command = "bdelete! %d",       -- can be a string | function, see "Mouse actions"
    right_mouse_command = "bdelete! %d", -- can be a string | function, see "Mouse actions"
    left_mouse_command = "buffer %d",    -- can be a string | function, see "Mouse actions"
    middle_mouse_command = nil,          -- can be a string | function, see "Mouse actions"
    -- NOTE: this plugin is designed with this icon in mind,
    -- and so changing this is NOT recommended, this is intended
    -- as an escape hatch for people who cannot bear it for whatever reason
    indicator_icon = '',
    buffer_close_icon = '',
    modified_icon = '●',
    close_icon = '',
    left_trunc_marker = '',
    right_trunc_marker = '',
    --- name_formatter can be used to change the buffer's label in the bufferline.
    --- Please note some names can/will break the
    --- bufferline so use this at your discretion knowing that it has
    --- some limitations that will *NOT* be fixed.
    name_formatter = function(buf)  -- buf contains a "name", "path" and "bufnr"
      -- remove extension from markdown files for example
      if buf.name:match('%.md') then
        return vim.fn.fnamemodify(buf.name, ':t:r')
      end
    end,
    max_name_length = 18,
    max_prefix_length = 15, -- prefix used when a buffer is de-duplicated
    tab_size = 18,
    diagnostics = "false",
    diagnostics_indicator = function(count, level, diagnostics_dict, context)
      return "("..count..")"
    end,
    -- NOTE: this will be called a lot so don't do any heavy processing here
    custom_filter = function(buf_number)
      -- filter out filetypes you don't want to see
      if vim.bo[buf_number].filetype ~= "<i-dont-want-to-see-this>" then
        return true
      end
      -- filter out by buffer name
      if vim.fn.bufname(buf_number) ~= "<buffer-name-I-dont-want>" then
        return true
      end
      -- filter out based on arbitrary rules
      -- e.g. filter out vim wiki buffer from tabline in your work repo
      if vim.fn.getcwd() == "<work-repo>" and vim.bo[buf_number].filetype ~= "wiki" then
        return true
      end
    end,
    offsets = {{filetype = "NvimTree", text = "File Explorer", text_align = "left"}},
    show_buffer_icons = true, -- disable filetype icons for buffers
    show_buffer_close_icons = false,
    show_close_icon = false,
    show_tab_indicators = true,
    persist_buffer_sort = true, -- whether or not custom sorted buffers should persist
    -- can also be a table containing 2 custom separators
    -- [focused and unfocused]. eg: { '|', '|' }
    separator_style = { '', '' },
    enforce_regular_tabs = true,
    always_show_bufferline = true,
    sort_by = 'id',
  },
  highlights = {
    fill = {
      guifg = 'none',
      guibg = 'none',
    },
    background = {
      guifg = '#E5E9F0',
      guibg = 'none'
    },
    -- tab = {
    --   guifg = '<color-value-here>',
    --   guibg = '<color-value-here>'
    -- },
    -- tab_selected = {
    --   guifg = tabline_sel_bg,
    --   guibg = '<color-value-here>'
    -- },
    -- tab_close = {
    --   guifg = '<color-value-here>',
    --   guibg = '<color-value-here>'
    -- },
    -- close_button = {
    --   guifg = '<color-value-here>',
    --   guibg = '<color-value-here>'
    -- },
    -- close_button_visible = {
    --   guifg = '<color-value-here>',
    --   guibg = '<color-value-here>'
    -- },
    -- close_button_selected = {
    --   guifg = '<color-value-here>',
    --   guibg = '<color-value-here>'
    -- },
    -- buffer_visible = {
    --   guifg = '<color-value-here>',
    --   guibg = '<color-value-here>'
    -- },
    buffer_selected = {
      guifg = '#88C0D0',
      guibg = 'none',
      gui = 'bold,underline'
    },
    -- diagnostic = {
    --   guifg = <color-value-here>,
    --   guibg = <color-value-here>,
    -- },
    -- diagnostic_visible = {
    --   guifg = <color-value-here>,
    --   guibg = <color-value-here>,
    -- },
    -- diagnostic_selected = {
    --   guifg = <color-value-here>,
    --   guibg = <color-value-here>,
    --   gui = "bold,italic"
    -- },
    -- info = {
    --   guifg = <color-value-here>,
    --   guisp = <color-value-here>,
    --   guibg = <color-value-here>
    -- },
    -- info_visible = {
    --   guifg = <color-value-here>,
    --   guibg = <color-value-here>
    -- },
    -- info_selected = {
    --   guifg = <color-value-here>,
    --   guibg = <color-value-here>,
    --   gui = "bold,italic",
    --   guisp = <color-value-here>
    -- },
    -- info_diagnostic = {
    --   guifg = <color-value-here>,
    --   guisp = <color-value-here>,
    --   guibg = <color-value-here>
    -- },
    -- info_diagnostic_visible = {
    --   guifg = <color-value-here>,
    --   guibg = <color-value-here>
    -- },
    -- info_diagnostic_selected = {
    --   guifg = <color-value-here>,
    --   guibg = <color-value-here>,
    --   gui = "bold,italic",
    --   guisp = <color-value-here>
    -- },
    -- warning = {
    --   guifg = <color-value-here>,
    --   guisp = <color-value-here>,
    --   guibg = <color-value-here>
    -- },
    -- warning_visible = {
    --   guifg = <color-value-here>,
    --   guibg = <color-value-here>
    -- },
    -- warning_selected = {
    --   guifg = <color-value-here>,
    --   guibg = <color-value-here>,
    --   gui = "bold,italic",
    --   guisp = <color-value-here>
    -- },
    -- warning_diagnostic = {
    --   guifg = <color-value-here>,
    --   guisp = <color-value-here>,
    --   guibg = <color-value-here>
    -- },
    -- warning_diagnostic_visible = {
    --   guifg = <color-value-here>,
    --   guibg = <color-value-here>
    -- },
    -- warning_diagnostic_selected = {
    --   guifg = <color-value-here>,
    --   guibg = <color-value-here>,
    --   gui = "bold,italic",
    --   guisp = warning_diagnostic_fg
    -- },
    -- error = {
    --   guifg = <color-value-here>,
    --   guibg = <color-value-here>,
    --   guisp = <color-value-here>
    -- },
    -- error_visible = {
    --   guifg = <color-value-here>,
    --   guibg = <color-value-here>
    -- },
    -- error_selected = {
    --   guifg = <color-value-here>,
    --   guibg = <color-value-here>,
    --   gui = "bold,italic",
    --   guisp = <color-value-here>
    -- },
    -- error_diagnostic = {
    --   guifg = <color-value-here>,
    --   guibg = <color-value-here>,
    --   guisp = <color-value-here>
    -- },
    -- error_diagnostic_visible = {
    --   guifg = <color-value-here>,
    --   guibg = <color-value-here>
    -- },
    -- error_diagnostic_selected = {
    --   guifg = <color-value-here>,
    --   guibg = <color-value-here>,
    --   gui = "bold,italic",
    --   guisp = <color-value-here>
    -- },
    -- modified = {
    --   guifg = '<color-value-here>',
    --   guibg = '<color-value-here>'
    -- },
    -- modified_visible = {
    --   guifg = '<color-value-here>',
    --   guibg = '<color-value-here>'
    -- },
    -- modified_selected = {
    --   guifg = '<color-value-here>',
    --   guibg = '<color-value-here>'
    -- },
    -- duplicate_selected = {
    --   guifg = '<color-value-here>',
    --   gui = "italic",
    --   guibg = '<color-value-here>'
    -- },
    -- duplicate_visible = {
    --   guifg = '<color-value-here>',
    --   gui = "italic",
    --   guibg = '<color-value-here>'
    -- },
    -- duplicate = {
    --   guifg = '<color-value-here>',
    --   gui = "italic",
    --   guibg = '<color-value-here>'
    -- },
    -- separator_selected = {
    --   guifg = '<color-value-here>,
    --   guibg = '<color-value-here>'
    -- },
    -- separator_visible = {
    --   guifg = '<color-value-here>,
    --   guibg = '<color-value-here>'
    -- },
    -- separator = {
    --   guifg = '<color-value-here>,
    --   guibg = '<color-value-here>'
    -- },
    -- indicator_selected = {
    --   guifg = '<color-value-here>',
    --   guibg = '<color-value-here>'
    -- },
    -- pick_selected = {
    --   guifg = '<color-value-here>',
    --   guibg = '<color-value-here>',
    --   gui = "bold,italic"
    -- },
    -- pick_visible = {
    --   guifg = '<color-value-here>',
    --   guibg = '<color-value-here>',
    --   gui = "bold,italic"
    -- },
    -- pick = {
    --   guifg = '<color-value-here>',
    --   guibg = '<color-value-here>',
    --   gui = "bold,italic"
    -- }
  },
}

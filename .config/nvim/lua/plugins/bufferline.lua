require('bufferline').setup {
  options = {
    numbers = function(opts)
      return string.format('%s', opts.id)
    end,
    close_command = "bdelete! %d", -- can be a string | function, see "Mouse actions"
    right_mouse_command = "bdelete! %d", -- can be a string | function, see "Mouse actions"
    left_mouse_command = "buffer %d", -- can be a string | function, see "Mouse actions"
    middle_mouse_command = nil, -- can be a string | function, see "Mouse actions"
    -- NOTE: this plugin is designed with this icon in mind,
    -- and so changing this is NOT recommended, this is intended
    -- as an escape hatch for people who cannot bear it for whatever reason
    indicator = {
      icon = '',
      style = 'icon'
    },
    buffer_close_icon = '',
    modified_icon = '●',
    close_icon = '',
    left_trunc_marker = '',
    right_trunc_marker = '',
    --- name_formatter can be used to change the buffer's label in the bufferline.
    --- Please note some names can/will break the
    --- bufferline so use this at your discretion knowing that it has
    --- some limitations that will *NOT* be fixed.
    name_formatter = function(buf) -- buf contains a "name", "path" and "bufnr"
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
      return "(" .. count .. ")"
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
    offsets = { { filetype = "NvimTree", text = "File Explorer", text_align = "left" } },
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
      fg = 'none',
      bg = 'none',
    },
    background = {
      fg = '#E5E9F0',
      bg = 'none'
    },
    -- tab = {
    --   fg = '<color-value-here>',
    --   bg = '<color-value-here>'
    -- },
    -- tab_selected = {
    --   fg = tabline_sel_bg,
    --   bg = '<color-value-here>'
    -- },
    -- tab_close = {
    --   fg = '<color-value-here>',
    --   bg = '<color-value-here>'
    -- },
    -- close_button = {
    --   fg = '<color-value-here>',
    --   bg = '<color-value-here>'
    -- },
    -- close_button_visible = {
    --   fg = '<color-value-here>',
    --   bg = '<color-value-here>'
    -- },
    -- close_button_selected = {
    --   fg = '<color-value-here>',
    --   bg = '<color-value-here>'
    -- },
    -- buffer_visible = {
    --   fg = '<color-value-here>',
    --   bg = '<color-value-here>'
    -- },
    buffer_selected = {
      fg = '#88C0D0',
      bg = 'none',
      underline = false,
      italic = false
    },
    -- diagnostic = {
    --   fg = <color-value-here>,
    --   bg = <color-value-here>,
    -- },
    -- diagnostic_visible = {
    --   fg = <color-value-here>,
    --   bg = <color-value-here>,
    -- },
    -- diagnostic_selected = {
    --   fg = <color-value-here>,
    --   bg = <color-value-here>,
    --    = "bold,italic"
    -- },
    -- info = {
    --   fg = <color-value-here>,
    --   sp = <color-value-here>,
    --   bg = <color-value-here>
    -- },
    -- info_visible = {
    --   fg = <color-value-here>,
    --   bg = <color-value-here>
    -- },
    -- info_selected = {
    --   fg = <color-value-here>,
    --   bg = <color-value-here>,
    --    = "bold,italic",
    --   sp = <color-value-here>
    -- },
    -- info_diagnostic = {
    --   fg = <color-value-here>,
    --   sp = <color-value-here>,
    --   bg = <color-value-here>
    -- },
    -- info_diagnostic_visible = {
    --   fg = <color-value-here>,
    --   bg = <color-value-here>
    -- },
    -- info_diagnostic_selected = {
    --   fg = <color-value-here>,
    --   bg = <color-value-here>,
    --   gui = "bold,italic",
    --   sp = <color-value-here>
    -- },
    -- warning = {
    --   fg = <color-value-here>,
    --   sp = <color-value-here>,
    --   bg = <color-value-here>
    -- },
    -- warning_visible = {
    --   fg = <color-value-here>,
    --   bg = <color-value-here>
    -- },
    -- warning_selected = {
    --   fg = <color-value-here>,
    --   bg = <color-value-here>,
    --   gui = "bold,italic",
    --   sp = <color-value-here>
    -- },
    -- warning_diagnostic = {
    --   fg = <color-value-here>,
    --   sp = <color-value-here>,
    --   bg = <color-value-here>
    -- },
    -- warning_diagnostic_visible = {
    --   fg = <color-value-here>,
    --   bg = <color-value-here>
    -- },
    -- warning_diagnostic_selected = {
    --   fg = <color-value-here>,
    --   bg = <color-value-here>,
    --   gui = "bold,italic",
    --   sp = warning_diagnostic_fg
    -- },
    -- error = {
    --   fg = <color-value-here>,
    --   bg = <color-value-here>,
    --   sp = <color-value-here>
    -- },
    -- error_visible = {
    --   fg = <color-value-here>,
    --   bg = <color-value-here>
    -- },
    -- error_selected = {
    --   fg = <color-value-here>,
    --   bg = <color-value-here>,
    --   gui = "bold,italic",
    --   sp = <color-value-here>
    -- },
    -- error_diagnostic = {
    --   fg = <color-value-here>,
    --   bg = <color-value-here>,
    --   sp = <color-value-here>
    -- },
    -- error_diagnostic_visible = {
    --   fg = <color-value-here>,
    --   bg = <color-value-here>
    -- },
    -- error_diagnostic_selected = {
    --   fg = <color-value-here>,
    --   bg = <color-value-here>,
    --   gui = "bold,italic",
    --   sp = <color-value-here>
    -- },
    -- modified = {
    --   fg = '<color-value-here>',
    --   bg = '<color-value-here>'
    -- },
    -- modified_visible = {
    --   fg = '<color-value-here>',
    --   bg = '<color-value-here>'
    -- },
    -- modified_selected = {
    --   fg = '<color-value-here>',
    --   bg = '<color-value-here>'
    -- },
    -- duplicate_selected = {
    --   fg = '<color-value-here>',
    --   gui = "italic",
    --   bg = '<color-value-here>'
    -- },
    -- duplicate_visible = {
    --   fg = '<color-value-here>',
    --   gui = "italic",
    --   bg = '<color-value-here>'
    -- },
    -- duplicate = {
    --   fg = '<color-value-here>',
    --   gui = "italic",
    --   bg = '<color-value-here>'
    -- },
    -- separator_selected = {
    --   fg = '<color-value-here>,
    --   bg = '<color-value-here>'
    -- },
    -- separator_visible = {
    --   fg = '<color-value-here>,
    --   bg = '<color-value-here>'
    -- },
    -- separator = {
    --   fg = '<color-value-here>,
    --   bg = '<color-value-here>'
    -- },
    -- indicator_selected = {
    --   fg = '<color-value-here>',
    --   bg = '<color-value-here>'
    -- },
    -- pick_selected = {
    --   fg = '<color-value-here>',
    --   bg = '<color-value-here>',
    --   gui = "bold,italic"
    -- },
    -- pick_visible = {
    --   fg = '<color-value-here>',
    --   bg = '<color-value-here>',
    --   gui = "bold,italic"
    -- },
    -- pick = {
    --   fg = '<color-value-here>',
    --   bg = '<color-value-here>',
    --   gui = "bold,italic"
    -- }
  },
}

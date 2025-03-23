return {
  "b0o/incline.nvim",
  event = "VeryLazy",
  opts = {
    debounce_threshold = {
      falling = 50,
      rising = 10,
    },
    hide = {
      cursorline = false,
      focused_win = false,
      only_win = false,
    },
    highlight = {
      groups = {
        InclineNormal = {
          default = true,
          group = "NormalFloat",
        },
        InclineNormalNC = {
          default = true,
          group = "NormalFloat",
        },
      },
    },
    ignore = {
      buftypes = "special",
      filetypes = {},
      floating_wins = true,
      unlisted_buffers = true,
      wintypes = "special",
    },
    render = function(props)
      if props.buf == vim.fn.bufnr("%") then
        return nil
      end
      local a = vim.api
      local bufname = a.nvim_buf_get_name(props.buf)
      local res = bufname ~= "" and vim.fn.substitute(vim.fn.fnamemodify(bufname, ":p"), vim.fn.getcwd(), "", "g")
        or "[No Name]"
      if a.nvim_buf_get_option(props.buf, "modified") then
        res = res .. " [+]"
      end
      return res
    end,
    window = {
      margin = {
        horizontal = 1,
        vertical = 1,
      },
      options = {
        signcolumn = "no",
        wrap = false,
      },
      padding = 1,
      padding_char = " ",
      placement = {
        horizontal = "right",
        vertical = "top",
      },
      width = "fit",
      winhighlight = {
        active = {
          EndOfBuffer = "None",
          Normal = "InclineNormal",
          Search = "None",
        },
        inactive = {
          EndOfBuffer = "None",
          Normal = "InclineNormalNC",
          Search = "None",
        },
      },
      zindex = 50,
    },
  }
}

return {
  "shellRaining/hlchunk.nvim",
  event = "BufReadPre",
  opts = {
    chunk = {
      enable = true,
      notify = false,
      use_treesitter = true,
      chars = {
        horizontal_line = "─",
        vertical_line = "│",
        left_top = "┌",
        left_bottom = "└",
        right_arrow = ">",
      },
      style = {
        { fg = "#094b5c" },
        { fg = "#073642" }, -- this fg is used to highlight wrong chunk
      },
      textobject = "u",
      max_file_size = 1024 * 1024,
      error_sign = false,
    },
    indent = {
      enable = false,
    },
    line_num = {
      enable = false,
      use_treesitter = false,
      style = "#806d9c",
    },
    blank = {
      enable = false,
      chars = {
        "․",
      },
      style = {
        vim.fn.synIDattr(vim.fn.synIDtrans(vim.fn.hlID("Whitespace")), "fg", "gui"),
      },
    },
  }
}

return {
  "akinsho/toggleterm.nvim",
  keys = {
    {
      "<F12>",
      function() vim.cmd(vim.v.count1 .. "ToggleTerm") end,
      mode = { "n" },
    },
    {
      "<F12>",
      function()
        vim.api.nvim_feedkeys(
          vim.api.nvim_replace_termcodes("<Esc>", true, false, true),
          "n",
          true
        )
        vim.cmd(vim.v.count1 .. "ToggleTerm")
      end,
      mode = { "t" },
    }
  },
  opts = {
    highlights = {
      Normal = {
        guibg = "#002b36"
      }
    },
    shade_terminals = false
  }
}

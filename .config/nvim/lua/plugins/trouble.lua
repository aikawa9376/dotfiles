return {
  "folke/trouble.nvim",
  cmd = "Trouble",
  keys = {
    {
      "<Leader>tt",
      function ()
        require"trouble".toggle({
          mode = "lsp",
          open_no_results = true,
        })
      end
    },
    {
      "<Leader>td",
      function ()
        require"trouble".toggle({
          mode = "diagnostics",
          open_no_results = true,
        })
      end
    },
  },
  config = true,
  otps = {},
}

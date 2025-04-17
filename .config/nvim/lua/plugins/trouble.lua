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
    {
      "<M-j>",
      function ()
        if require("trouble").is_open() then
          require("trouble").next({ jump = true })
        else
          vim.cmd("bnext")
        end
      end
    },
    {
      "<M-k>",
      function ()
        if require("trouble").is_open() then
          require("trouble").prev({ jump = true })
        else
          vim.cmd("bprev")
        end
      end
    }
  },
  config = true,
  otps = {},
}

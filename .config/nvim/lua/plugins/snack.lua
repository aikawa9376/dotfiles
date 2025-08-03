return {
  "folke/snacks.nvim",
  -- lazy = false,
  event = "BufReadPre",
  opts = {
    bigfile = {
      enabled = true,
      line_length = 1000,
      size = 1.5 * 1024 * 1024,
    },
    image = {
      enabled = true,
      convert = {
        notify = false,
      }
    },
    bufdelete = {
      enabled = true
    }
  },
  keys = {
    -- { "<leader>gg", function() Snacks.lazygit() end, desc = "Lazygit" },
  },
}

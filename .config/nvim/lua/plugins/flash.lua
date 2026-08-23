return {
  "folke/flash.nvim",
  keys = {
    { "f", "F", "t", "T", ";", ",", mode = { "n", "x" } },
    {
      "<C-j>",
      mode = { "n", "x", "o" },
      function()
        require("flash").jump({ search = { forward = true, wrap = false, incremental = true } })
      end,
      desc = "Flash",
    },
    {
      "<C-k>",
      mode = { "n", "x", "o" },
      function() require("flash").jump({ search = { forward = false , wrap = false, incremental = true } }) end,
      desc = "Flash",
    },
    {
      "<C-s>",
      mode = { "n", "x", "o" },
      function() require("flash").treesitter() end,
      desc = "Flash Treesitter",
    },
    {
      "r",
      mode = "o",
      function() require("flash").remote() end,
      desc = "Remote Flash",
    },
    {
      "R",
      mode = { "o", "x" },
      function() require("flash").treesitter_search() end,
      desc = "Treesitter Search",
    },
    {
      "<C-s>",
      mode = { "c" },
      function() require("flash").toggle() end,
      desc = "Toggle Flash Search",
    },
  },
  ---@type Flash.Config
  opts = {
    search = {
      exclude = {
        "notify",
        "cmp_menu",
        "noice",
        "flash_prompt",
        function(win)
          -- exclude non-focusable windows
          return not vim.api.nvim_win_get_config(win).focusable
        end,
      },
    },
    ---@type table<string, Flash.Config>
    modes = {
      char = {
        enabled = true,
        -- dynamic configuration for ftFT motions
        config = function(opts)
          opts.autohide = vim.fn.mode(true):find("no")
          opts.jump_labels = not vim.fn.mode(true):find("o")
            and vim.v.count == 0
            and vim.fn.reg_executing() == ""
            and vim.fn.reg_recording() == ""
        end,
        label = { exclude = "hjkliardcy" },
        jump = {
          autojump = true,
        },
      },
    },
    prompt = {
      enabled = false,
    },
  },
}

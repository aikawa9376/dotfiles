return {
  "migemo",
  dir = os.getenv("XDG_CONFIG_HOME") .. "/nvim/lua/plugins/migemo",
  keys = {
    { "<C-j", "<C-k>", mode = { "n", "x" } },
    {
      "<A-m>",
      mode = "c",
      function()
        require("migemo").search_no_history()
      end,
      silent = true,
      desc = "Migemo search (no history)",
    },
  },
  config = function()
    require("migemo").setup()
  end,
}

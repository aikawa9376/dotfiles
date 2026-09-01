return {
  "migemo",
  dir = os.getenv("XDG_CONFIG_HOME") .. "/nvim/lua/plugins/migemo",
  keys = {
    { "/", mode = { "n", "x", "o" } },
    { "?", mode = { "n", "x", "o" } },
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

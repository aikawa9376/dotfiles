return {
  "git-search",
  dir = os.getenv("XDG_CONFIG_HOME") .. "/nvim/lua/plugins/git-search",
  keys = {
      { "<Leader>gc", function () require"git-search".search_log_content()  end, mode = { "n" }, noremap = true, silent = true },
      { "<Leader>gC", function () require"git-search".search_log_content_file()  end, mode = { "n" }, noremap = true, silent = true },
  },
  cmd = { "GitSearch" },
  config = function()
    require("git-search").setup()
  end,
}

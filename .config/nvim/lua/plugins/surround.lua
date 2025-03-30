return {
  "kylechui/nvim-surround",
  keys = {
    { "ys", mode = { "n" } },
    { "cs", mode = { "n" } },
    { "ds", mode = { "n" } },
    { "S", mode = { "x" } },
  },
  opts = {
    surrounds = {
      [")"] = {
        change = {
          replacement = { "(", ")" },
        },
      },
      ["}"] = {
        change = {
          replacement = { "{", "}" },
        },
      },
    },
    aliases = {
      ["b"] = { ")", "}", "]", ">" },
      ["q"] = { '"', "'", "`" },
      ["s"] = { "}", "]", ")", ">", '"', "'", "`" },
    },
  }
}

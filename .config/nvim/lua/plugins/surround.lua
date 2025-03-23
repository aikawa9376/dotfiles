return {
  "kylechui/nvim-surround",
  event = "VeryLazy",
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

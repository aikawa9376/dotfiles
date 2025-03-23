return {
  "enoatu/nvim-smartchr",
  event = "InsertEnter",
  opts = {
    mappings = {
      default = {
        { "+", {'+', '++', ' + ', ' ++ '}, { loop = true } },
        { "-", {'-', '--', ' - ', ' -- '}, { loop = true } },
        { "*", {'*', '**', ' * ', ' ** '}, { loop = true } },
        { "/", {'/', '//', ' / ', ' // '}, { loop = true } },
        { "&", {'&', '&&', ' & ', ' && '}, { loop = true } },
        { "%", {'%', '%%', ' % ', ' %% '}, { loop = true } },
        { ">", {'>', '>>', ' > ', ' >> '}, { loop = true } },
        { "<", {'<', '<<', ' < ', ' <= '}, { loop = true } },
        { "=", {'=', ' = ', ' == '}, { loop = true } },
        { ",", {',', ', '}, { loop = true } },
        { ";", {';', '$', '@'}, { loop = true } },
        { "?", {'?', '!', '%', '='}, { loop = true } },
        { ".", {'.', '->', '=>'}, { loop = true } },
      },
      ["lua"] = {
        { ".", {'.', '..', '->', '=>'}, { loop = true } },
      },
      ["javascript|typescript|typescriptreact"] = {
        { "=", {'=', ' = ', ' == ', ' === ', ' !== '}, { loop = true } },
      },
    },
  }
}

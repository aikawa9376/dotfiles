return {
  "rainbow-delimiters-extension",
  dir = vim.fn.stdpath("config") .. "/lua/plugins/rainbow-delimiters",
  event = { "BufReadPre", "BufNewFile" },
  dependencies = { "HiPhish/rainbow-delimiters.nvim" },
  opts = {
    strategy = { [""] = "rainbow_delimiters.strategy" },
    highlight = {
      "RainbowDelimiterBlue",
      "RainbowDelimiterGreen",
      "RainbowDelimiterViolet",
      "RainbowDelimiterYellow",
      "RainbowDelimiterOrange",
      "RainbowDelimiterCyan",
      "RainbowDelimiterRed",
    },
  },
  config = function(_, opts)
    require("rainbow-delimiters.setup").setup(opts)
    -- BufNewFile can follow filetype detection; catch up only this buffer.
    local buf = vim.api.nvim_get_current_buf()
    local lang = vim.treesitter.language.get_lang(vim.bo[buf].filetype)
    local config = require("rainbow-delimiters.config")
    if config.enabled_for(lang) and config.enabled_when(buf) then
      require("rainbow-delimiters.lib").attach(buf)
    end
  end,
}

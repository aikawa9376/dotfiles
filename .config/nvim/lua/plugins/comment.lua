return {
  "numToStr/Comment.nvim",
  keys = {
    { "<C-_>", mode = { "n" } },
    { "<C-_>", "<ESC><CMD>lua require(\"Comment.api\").toggle.linewise(vim.fn.visualmode())<CR>", mode = { "x" }, silent = true },
    { "<Leader><C-_>", "<ESC><CMD>lua require(\"Comment.api\").toggle.blockwise(vim.fn.visualmode())<CR>", mode = { "x" }, silent = true },
  },
  config = function ()
    ---@diagnostic disable: missing-fields
    require('Comment').setup {
      ---Add a space b/w comment and the line
      ---@type boolean
      padding = true,

      ---Lines to be ignored while comment/uncomment.
      ---Could be a regex string or a function that returns a regex string.
      ---Example: Use '^$' to ignore empty lines
      ---@type string|function
      ignore = nil,

      ---Whether to create basic (operator-pending) and extra mappings for NORMAL/VISUAL mode
      ---@type table
      mappings = {
        ---operator-pending mapping
        ---Includes `gcc`, `gcb`, `gc[count]{motion}` and `gb[count]{motion}`
        basic = true,
        ---extended mapping
        ---Includes `g>`, `g<`, `g>[count]{motion}` and `g<[count]{motion}`
        extra = false,
      },

      ---LHS of line and block comment toggle mapping in NORMAL/VISUAL mode
      ---@type table
      toggler = {
        ---line-comment toggle
        line = '<C-_>',
        ---block-comment toggle
        block = '<Leader><C-_>',
      },

      ---LHS of line and block comment operator-mode mapping in NORMAL/VISUAL mode
      ---@type table
      opleader = {
        ---line-comment opfunc mapping
        line = 'gc',
        -- -block-comment opfunc mapping
        block = 'gb',
      },

      ---Pre-hook, called before commenting the line
      ---@type function|nil
      pre_hook = require('ts_context_commentstring.integrations.comment_nvim').create_pre_hook(),

      ---Post-hook, called after commenting is done
    }
  end
}

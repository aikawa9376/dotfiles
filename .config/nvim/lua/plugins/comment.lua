return {
  "numToStr/Comment.nvim",
  keys = {
    { "<C-/>", mode = { "n" } },
    { "<C-/>", "<ESC><CMD>lua require(\"Comment.api\").toggle.linewise(vim.fn.visualmode())<CR>", mode = { "x" }, silent = true },
    { "<Leader><C-/>", "<ESC><CMD>lua require(\"Comment.api\").toggle.blockwise(vim.fn.visualmode())<CR>", mode = { "x" }, silent = true },
  },
  config = function ()
    ---@diagnostic disable-next-line: missing-fields
    require('Comment').setup({
      mappings = {
        basic = true,
        extra = false,
      },
      toggler = {
        line = '<C-/>',
        block = '<Leader><C-/>',
      },
      opleader = {
        line = 'gc',
        block = 'gb',
      },
      pre_hook = require('ts_context_commentstring.integrations.comment_nvim').create_pre_hook(),
    })
  end
}

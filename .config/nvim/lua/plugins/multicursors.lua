return {
  "smoka7/multicursors.nvim",
  keys = {
    { "<C-n>", "<Cmd>MCstart<CR>", mode = { "n" }, silent = true },
    { "<C-n>", "<Cmd>MCvisual<CR>", mode = { "x" }, silent = true },
    { "<Leader>vc", "<Cmd>MCunderCursor<CR>", mode = { "n" }, silent = true },
  },
  opts = {
    hint_config = false,
    normal_keys = {
      -- to change default lhs of key mapping change the key
      ["j"] = {
        method = function()
          vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('j', true, true, true), 'n', false)
        end,
        opts = {}
      },
      ["k"] = {
        method = function()
          vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('k', true, true, true), 'n', false)
        end,
        opts = {}
      },
    }
  }
}

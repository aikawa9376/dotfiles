return {
  "rhysd/migemo-search.vim",
  keys = {
    {
      "<C-Space>",
      function ()
        if vim.fn.executable('cmigemo') == 1 then
          vim.cmd([[call migemosearch_replace_search_word()]])
        else
          vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-Space>", true, false, true), "n", true)
        end
      end,
      mode = { "c" },
      silent = true,
    }
  },
}

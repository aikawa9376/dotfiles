return {
  "rhysd/migemo-search.vim",
  event = "VeryLazy",
  init = function ()
    if vim.fn.executable('cmigemo') == 1 then
      vim.api.nvim_set_keymap('c', '<C-Space>', 'v:lua.migemosearch_replace_search_word()', { noremap = true, expr = true, silent = true })
    end
  end
}

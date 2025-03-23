return {
  "tpope/vim-fugitive",
  cmd = {
    "Git", "Gdiff", "Gwrite", "Gdiffsplit",
    "Gedit", "GitAddCommit", "GitAddAmend"
  },
  keys = {
  { "<Leader>gs", "<cmd>Git<CR>", silent = true },
  { "<Leader>gd", "<cmd>Gdiffsplit<CR>", silent = true },
  { "<Leader>ga", "<cmd>Gwrite<CR>", silent = true },
  { "<Leader>gb", "<cmd>Git blame -w --date=format:'%Y-%m-%d %H:%M'<CR>", silent = true },
  { "<Leader>gp", "<cmd>Git! push<CR>", silent = true },
  { "<Leader>gr", "<cmd>Git! rm --cached %<CR>", silent = true },
  { "<Leader>gm", "<cmd>Git! commit -m 'update'<CR>", silent = true },
  { "<Leader>gM", "<cmd>GitAddCommit update<CR>", silent = true },
  { "<Leader>gU", "<cmd>GitAddAmend<CR>", silent = true },
  }
}

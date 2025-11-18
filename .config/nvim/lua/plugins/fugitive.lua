return {
  "tpope/vim-fugitive",
  cmd = {
    "G", "Git", "Gdiff", "Gwrite", "Gread", "Gdiffsplit",
    "Gedit", "Gcd", "Gclog", "GeditHeadAtFile", "Gvsplit", "GitPush"
  },
  dependencies = "fugitive-extension",
  keys = {
    { "<Leader>gs", "<cmd>Git<CR><Plug>fugitive:gU", silent = true },
    { "<Leader>gg", "<cmd>GeditHeadAtFile<CR>", silent = true },
    { "<Leader>gb", "<cmd>Git blame -w --date=format:'%Y-%m-%d %H:%M'<CR>", silent = true },
    { "<Leader>gr", "<cmd>Git! rm --cached %<CR>", silent = true },
    { "<Leader>gM", "<cmd>Git! commit -m 'tmp'<CR>", silent = true },
    { "<Leader>gA", "<cmd>Gwrite<CR>", silent = true },
    { "<Leader>gp", "<cmd>GitPush<CR>", silent = true },
    { "g<space>l", "<cmd>G log --oneline<CR>", silent = true },
    { "g<space>d", "<cmd>G diff<CR>", silent = true },
    { "g<space>r", "<cmd>G reflog<CR>", silent = true },
    { "g<space>s", "<cmd>G show<CR>", silent = true },
    { "g<space>b", "<cmd>G branch -vv --all<CR>", silent = true },
  },
}

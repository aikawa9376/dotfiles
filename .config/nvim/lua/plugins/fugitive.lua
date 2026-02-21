return {
  "tpope/vim-fugitive",
  cmd = {
    "G", "Git", "Gdiff", "Gwrite", "Gread", "Gdiffsplit", "Gstash",
    "Gedit", "Gcd", "Gclog", "GeditHeadAtFile", "Gvsplit", "GitPush",
    "Gworktree", "Gbranch", "FugitiveLog"
  },
  dependencies = "fugitive-extension",
  keys = {
    { "<Leader>gs", "<cmd>Git<CR><Plug>fugitive:gU", silent = true },
    { "<Leader>gg", "<cmd>GeditHeadAtFile<CR>", silent = true },
    { "<Leader>gb", "<cmd>Git blame -w --date=format:'%Y-%m-%d %H:%M'<CR>", silent = true },
    { "<Leader>gr", "<cmd>Git! rm --cached %<CR>", silent = true },
    { "<Leader>gM", "<cmd>Git! commit -m 'tmp'<CR>", silent = true },
    { "<Leader>gA", "<cmd>Gwrite<CR>", silent = true },
    { "g<space>p", "<cmd>GitPush<CR>", silent = true },
    { "g<space>l", "<cmd>FugitiveLog<CR>", silent = true },
    { "g<space>d", "<cmd>G diff<CR>", silent = true },
    { "g<space>r", "<cmd>Greflog<CR>", silent = true },
    { "g<space>s", "<cmd>G show<CR>", silent = true },
    { "g<space>b", "<cmd>Gbranch<CR>", silent = true },
    { "g<space>L", function() vim.cmd(
      'FugitiveLog -- ' .. vim.fn.expand('%')
    ) end, silent = true, desc = "Log for current file" },
  },
}

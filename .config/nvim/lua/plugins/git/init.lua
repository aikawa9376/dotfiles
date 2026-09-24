return {
  "git",
  dir = vim.fn.stdpath("config") .. "/lua/plugins/git",
  main = "git",
  config = true,
  cmd = {
    "G", "Git", "Gdiff", "Gwrite", "Gread", "Gdiffsplit", "Gstash",
    "Gedit", "Gcd", "Gclog", "GeditHeadAtFile", "Gvsplit", "GitPush",
    "Gworktree", "Gbranch", "FugitiveLog", "GitHeatmap", "GitBlame", "GitStatus",
    "GitCommit", "Greflog", "Glog", "Gllog", "Glcd", "Gtabedit", "Gsplit", "Gvdiffsplit",
    "Ghdiffsplit", "Gremove", "Gdelete", "Gmove", "Grename", "Gwq", "Gblame", "Ggraph",
    "GgraphBackend", "GCherryPick", "GworktreeSync", "UndoFugitive", "RedoFugitive", "DiffDim"
  },
  keys = {
    { "<Leader>gb", function() require('git.features.blame').toggle() end, silent = true, desc = "Toggle Git blame panel" },
    { "<Leader>gs", function() require('git.features.status').open({ focus = 'unstaged', split = true }) end, silent = true },
    { "<Leader>gg", "<cmd>GeditHeadAtFile<CR>", silent = true },
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

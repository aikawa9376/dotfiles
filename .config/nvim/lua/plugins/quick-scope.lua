return {
  "unblevable/quick-scope",
  event = "BufReadPre",
  init = function ()
    vim.g.qs_hi_priority = 20
    vim.g.qs_ignorecase = 1
    vim.g.qs_filetype_blacklist = {
      'neo-tree', 'help', 'git', 'harpoon', 'DiffviewFiles', 'gitstatus', 'gitcommitview',
      'DressingSelect', 'mason', 'gitblame', 'gitbranch', 'gitlog', 'gitreflog',
      'gitstash', 'gitworktree', 'gitactionmenu', 'qf', 'fzf', 'noice', 'lazygit', 'Avante', 'bigfile'
    }
  end
}

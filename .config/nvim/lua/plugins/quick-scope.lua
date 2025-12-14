return {
  "unblevable/quick-scope",
  event = "BufReadPre",
  init = function ()
    vim.g.qs_hi_priority = 20
    vim.g.qs_ignorecase = 1
    vim.g.qs_filetype_blacklist = {
      'neo-tree', 'help', 'fugitive', 'harpoon', 'DiffviewFiles',
      'DressingSelect', 'mason', 'fugitiveblame', 'fugitivebranch', 'git',
      'fugitivelog', 'qf', 'fzf', 'noice', 'lazygit', 'Avante'
    }
  end
}

return {
  "unblevable/quick-scope",
  event = "VeryLazy",
  init = function ()
    vim.g.qs_hi_priority = 20
    vim.g.qs_ignorecase = 1
    vim.g.qs_filetype_blacklist = {
      'neo-tree', 'help', 'fugitive', 'harpoon', 'DiffviewFiles',
      'DressingSelect', 'mason', 'fugitiveblame',
      'vista', 'qf', 'fzf', 'noice', 'lazygit'
    }
  end
}

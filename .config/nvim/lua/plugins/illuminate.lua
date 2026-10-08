return {
  "RRethy/vim-illuminate",
  event = "BufReadPre",
  config = function ()
    require('illuminate').configure({
      filetypes_denylist = {
        'git',
        'gitstatus',
        'gitcommitview',
        'gitblame',
        'gitbranch',
        'gitlog',
        'gitreflog',
        'gitstash',
        'gitworktree',
        'gitactionmenu',
        'harpoon',
        'lazyagent_acp',
        'bigfile',
      },
    })
  end
}

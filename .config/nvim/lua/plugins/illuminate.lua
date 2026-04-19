return {
  "RRethy/vim-illuminate",
  event = "BufReadPre",
  config = function ()
    require('illuminate').configure({
      filetypes_denylist = {
        'fugitive',
        'harpoon',
        'lazyagent_acp',
      },
    })
  end
}

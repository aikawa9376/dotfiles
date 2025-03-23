return {
  "RRethy/vim-illuminate",
  event = "VeryLazy",
  config = function ()
    require('illuminate').configure({
      filetypes_denylist = {
        'fugitive',
        'harpoon',
      },
    })
  end
}

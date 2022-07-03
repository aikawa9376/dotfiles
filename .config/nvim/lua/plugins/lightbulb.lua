vim.cmd [[ autocmd CursorHold,CursorHoldI * lua LightBulbFunction() ]]
vim.api.nvim_command('highlight LightBulbVirtualText guifg=#ECBE7B guibg=None')

LightBulbFunction = function()
  require'nvim-lightbulb'.update_lightbulb {
    sign = {
      enabled = false,
    },
    virtual_text = {
      enabled = true,
      -- Text to show at virtual text
      text = " ",
    },
  }
end

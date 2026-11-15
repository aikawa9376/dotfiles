if vim.g.git_app == 1 or vim.g.git_app == true then
  require('config.git_app').setup()
  return
end

require('config.open')
require('config.command')
require('config.option')
require('config.keymap')
require('config.colorScheme')
require('config.ui_select')
require('config.lazy')

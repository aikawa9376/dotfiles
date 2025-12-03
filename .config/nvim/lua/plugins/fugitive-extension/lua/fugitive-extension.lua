local M = {}

function M.setup()
  local group = vim.api.nvim_create_augroup('fugitive_custom', { clear = true })

  require('features.status').setup(group)
  require('features.blame').setup(group)
  require('features.commit').setup(group)
  require('features.blob').setup(group)
  require('features.stash').setup(group)
  require('features.branch').setup(group)
  require('features.log').setup(group)
  require('features.commands').setup()
end

return M
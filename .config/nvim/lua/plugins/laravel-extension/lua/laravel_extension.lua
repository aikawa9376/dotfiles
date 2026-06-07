local M = {}

function M.setup()
  local group = vim.api.nvim_create_augroup("laravel_extension", { clear = true })

  require("laravel_extension.features.component").setup(group)
  require("laravel_extension.features.view").setup(group)
  require("laravel_extension.features.livewire").setup(group)
  require("laravel_extension.features.definition").setup(group)
end

return M

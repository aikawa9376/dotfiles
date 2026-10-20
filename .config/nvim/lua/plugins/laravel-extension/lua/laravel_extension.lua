local M = {}

function M.setup()
  local group = vim.api.nvim_create_augroup("laravel_extension", { clear = true })

  require("laravel_extension.features.component").setup(group)
  require("laravel_extension.features.view").setup()
  require("laravel_extension.features.livewire").setup()
  require("laravel_extension.features.definition").setup(group)
  require("laravel_extension.features.references").setup(group)
  require("laravel_extension.features.routes").setup()
  require("laravel_extension.features.rename").setup(group)
end

return M

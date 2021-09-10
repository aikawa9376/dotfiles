-- completion
local capabilities = vim.lsp.protocol.make_client_capabilities()
capabilities = require('cmp_nvim_lsp').update_capabilities(capabilities)

local function setup_servers()
  require'plugins.lsp.configs.installs'
  require'lspinstall'.setup()

  local servers = require'lspinstall'.installed_servers()
  for _, server in pairs(servers) do
    require'lspconfig'[server].setup (
      init_setup({capabilities = capabilities}, server)
    )
  end
end

function init_setup(params, server)
  local settings = require'plugins.lsp.configs.settings'
  if settings[server] then
    for k,v in pairs(settings[server]) do
      params[k] = v
    end
  end
  return params
end

setup_servers()

-- Automatically reload after `:LspInstall <server>` so we don't have to restart neovim
require'lspinstall'.post_install_hook = function ()
  setup_servers() -- reload installed servers
  vim.cmd("bufdo e") -- this triggers the FileType autocmd that starts the server
end

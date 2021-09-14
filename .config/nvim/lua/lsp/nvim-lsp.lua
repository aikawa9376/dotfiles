-- completion
local capabilities = vim.lsp.protocol.make_client_capabilities()
local settings = require'lsp.configs.settings'
capabilities = require('cmp_nvim_lsp').update_capabilities(capabilities)

local function setup_servers()
  require'lsp.configs.installs'
  require'lspinstall'.setup()

  local servers = require'lspinstall'.installed_servers()
  for _, server in pairs(servers) do
    require'lspconfig'[server].setup (
      init_setup({
        capabilities = capabilities,
        on_attach = settings.default
      }, server)
    )
  end
end

function init_setup(params, server)
  local update_setting = settings.configs
  if update_setting[server] then
    for k,v in pairs(update_setting[server]) do
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

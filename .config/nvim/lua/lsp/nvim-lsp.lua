-- completion
local capabilities = vim.lsp.protocol.make_client_capabilities()
local settings = require'lsp.configs.settings'
capabilities = require('cmp_nvim_lsp').update_capabilities(capabilities)

local function init_setup(params, server)
  local update_setting = settings.configs
  if update_setting[server] then
    for k,v in pairs(update_setting[server]) do
      params[k] = v
    end
  end
  return params
end

local function setup_servers()
  require'lsp.configs.installs'
  local lsp_installer_servers = require'nvim-lsp-installer.servers'.get_installed_servers()

  for _, server in pairs(lsp_installer_servers) do
    server:on_ready(function ()
      server:setup(
        init_setup({
          capabilities = capabilities,
          on_attach = settings.default
        }, server.name)
      )
    end)
  end
end

setup_servers()

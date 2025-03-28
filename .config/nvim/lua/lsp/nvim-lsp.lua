-- completion
local nvim_lsp = require("lspconfig")
local capabilities = vim.lsp.protocol.make_client_capabilities()
-- capabilities = require('blink.cmp').get_lsp_capabilities(capabilities)
capabilities = require("cmp_nvim_lsp").default_capabilities(capabilities)
local settings = require("lsp.configs.settings")

require("mason").setup()

local function init_setup(params, server)
  local update_setting = settings.configs
  if update_setting[server] then
    for k, v in pairs(update_setting[server]) do
      params[k] = v
    end
  end
  return params
end

local function setup_servers()
  local lsp_installer = require("mason-lspconfig")

  lsp_installer.setup_handlers({
    function(server)
      if server == "ts_ls" then
        require("typescript-tools").setup(
          init_setup({
            capabilities = capabilities,
            on_attach = settings.default,
          }, server)
        )
      elseif server == "rust_analyzer" then
        require("rust-tools").setup(
          init_setup({
            capabilities = capabilities,
            on_attach = settings.default,
          }, server)
        )
      else
        nvim_lsp[server].setup(
          init_setup({
            capabilities = capabilities,
            on_attach = settings.default,
          }, server)
        )
      end
    end,
  })
end

setup_servers()

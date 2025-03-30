-- completion
local nvim_lsp = require("lspconfig")
local capabilities = vim.lsp.protocol.make_client_capabilities()

-- Try to load 'blink.cmp' module
-- local blink_cmp_loaded, blink_cmp = pcall(require, 'blink.cmp')
-- if blink_cmp_loaded then
--   capabilities = blink_cmp.get_lsp_capabilities(capabilities)
-- else
--   local cmp_nvim_lsp_loaded, cmp_nvim_lsp = pcall(require, 'cmp_nvim_lsp')
--   if cmp_nvim_lsp_loaded then
--     capabilities = cmp_nvim_lsp.default_capabilities(capabilities)
--   end
-- end

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

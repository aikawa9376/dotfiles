-- completion
local capabilities = vim.lsp.protocol.make_client_capabilities()
local settings = require 'lsp.configs.settings'
capabilities = require 'cmp_nvim_lsp'.update_capabilities(capabilities)

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
  local lsp_installer = require("nvim-lsp-installer")

  lsp_installer.on_server_ready(function(server)
    if server.name == "rust_analyzer" then
      local opts = init_setup({
        capabilities = capabilities,
        on_attach = settings.default
      }, "rust_analyzer")

      require("rust-tools").setup {
        server = vim.tbl_deep_extend("force", server:get_default_options(), opts),
        tools = {
          hover_with_actions = true,
          inlay_hints = {
            show_variable_name = true,
          },
          hover_actions = {
            border = {
              {"", "FloatBorder"}, {"", "FloatBorder"},
              {"", "FloatBorder"}, {"", "FloatBorder"},
              {"", "FloatBorder"}, {"", "FloatBorder"},
              {"", "FloatBorder"}, {"", "FloatBorder"}
            },
          },
        }
      }
      server:attach_buffers()
    else
      server:setup(
        init_setup({
          capabilities = capabilities,
          on_attach = settings.default
        }, server.name)
      )
    end
  end)
end

setup_servers()

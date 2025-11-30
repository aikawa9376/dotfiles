---@type vim.lsp.Config
return {
  settings = {
    Lua = {
      hint = {
        enable = true,
        arrayIndex = "Disable",
        semicolon = "Disable"
      },
      diagnostics = {
        globals = { "vim" },
      },
      -- very slow and very use resource
      codeLens = {
        enable = false,
      },
      runtime = {
        version = "LuaJIT",
        path = vim.split(package.path, ";"),
      },
    },
  },
  on_attach = function(client, bufnr)
    client.server_capabilities.documentFormattingProvider = false
    require('lsp.default').settings(client, bufnr)
  end,
}

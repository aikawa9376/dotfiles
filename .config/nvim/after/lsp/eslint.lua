---@type vim.lsp.Config
return {
  settings = {
    format = { enable = true },
  },
  on_attach = function(client, bufnr)
    client.server_capabilities.documentFormattingProvider = true
    require('lsp.default').settings(client, bufnr)
  end,
}

---@type vim.lsp.Config
return {
  on_attach = function(client, bufnr)
    client.server_capabilities.documentFormattingProvider = false
    require('lsp.default').settings(client, bufnr)
  end,
}

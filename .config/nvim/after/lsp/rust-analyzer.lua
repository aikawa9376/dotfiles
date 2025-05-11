---@type vim.lsp.Config
return {
  settings = {
    ["rust-analyzer"] = {
      completion = {
        autoimport = {
          enabled = true,
        },
      },
      lens = {
        references = true,
        methodReferences = true,
      },
      ["cargo-watch"] = {
        enabled = true,
      },
      diagnostics = {
        enableExperimental = true,
      },
    },
  },
  on_attach = function(client, bufnr)
    require('lsp.default').settings(client, bufnr)
  end,
}

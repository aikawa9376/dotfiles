---@type vim.lsp.Config
return {
  tools = {
    inlay_hints = {
      auto = true,
      show_variable_name = true,
    },
  },
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
  server = {
    on_attach = function(client, bufnr)
      require('lsp.default').settings(client, bufnr)
    end,
  },

}

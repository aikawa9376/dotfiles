local prettier_args = { "--no-semi", "--single-quote", "--trailing-comma", "none", '--tab-width', vim.o.tabstop }
if not vim.o.expandtab then
  table.insert(prettier_args, '--use-tabs')
end

require("null-ls").setup({
  debug = true,
  sources = {
    require("null-ls").builtins.formatting.prettier.with({
      extra_args = prettier_args
    }),
    require("null-ls").builtins.formatting.blade_formatter,
    require("null-ls").builtins.formatting.sql_formatter,
    -- require("typescript.extensions.null-ls.code-actions"),
  },
  on_attach = function(client, bufnr)
    if client.server_capabilities.documentFormattingProvider then
      require "lsp-format".on_attach(client)
    end
  end,
})

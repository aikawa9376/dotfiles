local prettier_args = { "--no-semi", "--single-quote", "--trailing-comma", "none", "--tab-width", vim.o.tabstop }
if not vim.o.expandtab then
  table.insert(prettier_args, "--use-tabs")
end

local null_ls = require('null-ls')

null_ls.setup({
  debug = false,
  sources = {
    -- require("null-ls").builtins.formatting.prettier.with({
    --   extra_args = prettier_args,
    -- }),
    -- require("null-ls").builtins.formatting.blade_formatter,
    -- require("null-ls").builtins.formatting.sql_formatter,
    -- require("null-ls").builtins.formatting.stylua,
    -- require("null-ls").builtins.code_actions.refactoring
    -- require("typescript.extensions.null-ls.code-actions"),
    -- require("null-ls").builtins.diagnostics.phpcs,
    -- require("null-ls").builtins.diagnostics.phpstan.with({
    --   temp_dir = "/tmp",
    --   timeout = 10000,
    --   method = null_ls.methods.DIAGNOSTICS_ON_SAVE,
    --   args = { "analyze", "--memory-limit", "512M", "--error-format", "json", "--no-progress", "$FILENAME" }
    -- }),
  },
  on_attach = function(client, bufnr)
    if client.server_capabilities.documentFormattingProvider then
      require("lsp-format").on_attach(client)
    end
  end,
})

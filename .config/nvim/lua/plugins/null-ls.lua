return {
  "nvimtools/none-ls.nvim",
  event = "VeryLazy",
  config = function ()
    local prettier_args = { "--no-semi", "--single-quote", "--trailing-comma", "none", "--tab-width", vim.o.tabstop }
    if not vim.o.expandtab then
      table.insert(prettier_args, "--use-tabs")
    end

    require("null-ls").setup({
      debug = true,
      sources = {
        -- require("null-ls").builtins.formatting.prettier.with({
          --   extra_args = prettier_args,
          -- }),
          -- require("null-ls").builtins.formatting.blade_formatter,
          -- require("null-ls").builtins.formatting.sql_formatter,
          -- require("null-ls").builtins.formatting.stylua,
          -- require("null-ls").builtins.code_actions.refactoring
          -- require("typescript.extensions.null-ls.code-actions"),
          require("null-ls").builtins.formatting.phpcsfixer.with({
            cmd = "PHP_CS_FIXER_IGNORE_ENV=1 php-cs-fixer",
            args = {
              "--quiet",
              "--no-interaction",
              "fix",
              "$FILENAME",
            },
          }),
          -- require("null-ls").builtins.diagnostics.phpstan.with({
          --   temp_dir = "/tmp",
          --   timeout = 10000,
          --   method = require("null-ls").methods.DIAGNOSTICS_ON_SAVE,
          --   args = { "analyze", "--memory-limit", "512M", "--error-format", "json", "--no-progress", "$FILENAME" }
          -- }),
        },
        on_attach = function(client, bufnr)
          if client.server_capabilities.documentFormattingProvider then
            require("lsp-format").on_attach(client)
          end
        end,
      })
  end
}

local M = {}

M.configs = {
  html = {
    settings = {
      html = {
        autoClosingTags = false,
      },
    },
    on_attach = function(client, bufnr)
      client.server_capabilities.documentFormattingProvider = false
      M.default(client, bufnr)
    end,
  },
  ts_ls = {
    settings = {
      typescript = {
        inlayHints = {
          includeInlayParameterNameHints = "all",
          includeInlayParameterNameHintsWhenArgumentMatchesName = true,
          includeInlayFunctionParameterTypeHints = true,
          includeInlayVariableTypeHints = true,
          includeInlayPropertyDeclarationTypeHints = true,
          includeInlayFunctionLikeReturnTypeHints = true,
          includeInlayEnumMemberValueHints = true,
        },
      },
      javascript = {
        inlayHints = {
          includeInlayParameterNameHints = "all",
          includeInlayParameterNameHintsWhenArgumentMatchesName = true,
          includeInlayFunctionParameterTypeHints = true,
          includeInlayVariableTypeHints = true,
          includeInlayPropertyDeclarationTypeHints = true,
          includeInlayFunctionLikeReturnTypeHints = true,
          includeInlayEnumMemberValueHints = true,
        },
      },
      tsserver_file_preferences = {
        includeInlayParameterNameHints = "all",
        includeInlayParameterNameHintsWhenArgumentMatchesName = true,
        includeInlayFunctionParameterTypeHints = true,
        includeInlayVariableTypeHints = true,
        includeInlayVariableTypeHintsWhenTypeMatchesName = false,
        includeInlayPropertyDeclarationTypeHints = true,
        includeInlayFunctionLikeReturnTypeHints = true,
        includeInlayEnumMemberValueHints = true,
      }
    },
    go_to_source_definition = {
      fallback = true, -- fall back to standard LSP definition on failure
    },
    on_attach = function(client, bufnr)
      client.server_capabilities.documentFormattingProvider = false
      M.default(client, bufnr)
    end,
  },
  rust_analyzer = {
    tools = {
      inlay_hints = {
        auto = true,
        show_variable_name = true,
      },
      hover_actions = {
        border = {
          { "", "FloatBorder" },
          { "", "FloatBorder" },
          { "", "FloatBorder" },
          { "", "FloatBorder" },
          { "", "FloatBorder" },
          { "", "FloatBorder" },
          { "", "FloatBorder" },
          { "", "FloatBorder" },
        },
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
        M.default(client, bufnr)
      end,
    },
  },
  lua_ls = {
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
        runtime = {
          version = "LuaJIT",
          path = vim.split(package.path, ";"),
        },
      },
    },
    on_attach = function(client, bufnr)
      client.server_capabilities.documentFormattingProvider = false
      M.default(client, bufnr)
    end,
  },
  eslint = {
    settings = {
      format = { enable = true },
    },
    on_attach = function(client, bufnr)
      M.default(client, bufnr)
      client.server_capabilities.documentFormattingProvider = true
    end,
  },

  stylelint_lsp = {
    settings = {
      stylelintplus = {
        autoFixOnSave = true,
        autoFixOnFormat = true,
      },
    },
    filetypes = { "css", "less", "scss", "sugarss", "wxss" },
  },
  angularls = {
    filetypes = { "html", "typescript" },
  },
}

M.default = function(client, bufnr)
  local function buf_set_keymap(...)
    vim.api.nvim_buf_set_keymap(bufnr, ...)
  end

  local function buf_set_option(name, value)
    vim.api.nvim_set_option_value(name, value, { buf = bufnr })
  end

  -- Enable completion triggered by <c-x><c-o>
  buf_set_option("omnifunc", "v:lua.vim.lsp.omnifunc")

  -- Mappings.
  local opts = { noremap = true, silent = true }
  buf_set_keymap("n", "gr", "m`:FzfLua lsp_references<CR>", opts)
  buf_set_keymap("n", "gR", "m`:FzfLua lsp_finder<CR>", opts)
  buf_set_keymap("n", "gd", "m`:FzfLua lsp_definitions<CR>", opts)
  buf_set_keymap("n", "gsd", "m`:vsplit | FzfLua lsp_definitions<CR>", opts)
  buf_set_keymap("n", "gD", "m`:FzfLua lsp_declarations<CR>", opts)
  buf_set_keymap("n", "gi", "m`:FzfLua lsp_implementations<CR>", opts)
  buf_set_keymap("n", "gy", "m`:FzfLua lsp_typedefs<CR>", opts)
  buf_set_keymap("n", "gk", "<cmd>lua vim.lsp.buf.hover({ border = 'rounded', focusable = false })<CR>", opts)
  buf_set_keymap("n", "<leader>rn", "<cmd>lua vim.lsp.buf.rename()<CR>", opts)
  buf_set_keymap("n", "<Leader>ca", ":FzfLua lsp_code_actions<CR>", opts)
  buf_set_keymap("n", "<Leader>cl", "<cmd>lua vim.lsp.codelens.run()<CR>", opts)
  buf_set_keymap(
    "n",
    "gq",
    "<cmd>lua vim.diagnostic.open_float(nil, { border = 'rounded', scope = 'cursor',  focusable = true })<cr>",
    opts
  )

  -- Commands.
  vim.cmd([[command! DiagnosticPrevious lua vim.diagnostic.goto_prev()]])
  vim.cmd([[command! DiagnosticNext lua vim.diagnostic.goto_next()]])
  vim.cmd([[command! DiagnosticQf lua vim.diagnostic.setloclist()]])
  vim.cmd([[command! AddWorkspaceFolder vim.lsp.buf.add_workspace_folder()]])
  vim.cmd([[command! RemoveWorkspaceFolder vim.lsp.buf.remove_workspace_folder()]])
  vim.cmd([[command! ShowWorkspaceFolder lua print(vim.inspect(vim.lsp.buf.list_workspace_folders()))]])
  vim.cmd([[command! IncomingCall FzfLua lsp_incoming_calls]])
  vim.cmd([[command! OutGoingCall FzfLua lsp_outgoing_calls]])
  vim.cmd([[command! -bang -nargs=? WorkspaceSymbol FzfLua lsp_live_workspace_symbols]])

  -- features
  -- if not vim.g.auto_format_disabled and client.server_capabilities.documentFormattingProvider then
  --   require("lsp-format").on_attach(client, bufnr)
  -- end

  if client.server_capabilities.codeLensProvider then
    vim.lsp.codelens.refresh()
    vim.api.nvim_create_autocmd({ "BufEnter", "CursorHold", "InsertLeave" }, {
      buffer = bufnr,
      callback = vim.lsp.codelens.refresh,
    })
  end

  if client.capabilities.textDocument.publishDiagnostics then
    -- diagnostic settings
    vim.diagnostic.config({
      virtual_text = false,
      float = {
        border = "rounded",
        focusable = false
      },
      signs = {
        priority = 100,
        text = {
          [vim.diagnostic.severity.E] = "",
          [vim.diagnostic.severity.W] = "",
          [vim.diagnostic.severity.I] = "",
          [vim.diagnostic.severity.N] = ""
        },
        numhl = {
          [vim.diagnostic.severity.E] = "DiagnosticSignError",
          [vim.diagnostic.severity.W] = "DiagnosticSignWarn",
          [vim.diagnostic.severity.I] = "DiagnosticSignInfo",
          [vim.diagnostic.severity.N] = "DiagnosticSignHint"
        }
      },
    })
  end

  -- use blink.cmp
  -- if client.server_capabilities.signatureHelpProvider then
  --   require("lsp_signature").on_attach({
  --     bind = true, -- This is mandatory, otherwise border config won't get registered.
  --     hint_enable = false,
  --     handler_opts = {
  --       border = "rounded",
  --     },
  --   }, bufnr)
  -- end

  if client.server_capabilities.inlayHintProvider then
    vim.lsp.inlay_hint.enable(true, { bufnr = bufnr })
  end
end

return M

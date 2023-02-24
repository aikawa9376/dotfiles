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
  tsserver = {
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
    },
    go_to_source_definition = {
      fallback = true, -- fall back to standard LSP definition on failure
    },
    on_attach = function(client, bufnr)
      require("lsp-inlayhints").on_attach(client, bufnr)
      client.server_capabilities.documentFormattingProvider = false
      M.default(client, bufnr)
    end,
  },
  rust_analyzer = {
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
      M.default(client, bufnr)
    end,
  },
  lua_ls = {
    settings = {
      Lua = {
        hint = {
          enable = true,
        },
        diagnostics = {
          globals = { "vim" },
        },
        runtime = {
          version = "LuaJIT",
          path = vim.split(package.path, ";"),
        },
        workspace = {
          library = {
            [vim.fn.expand("$VIMRUNTIME/lua")] = true,
            [vim.fn.expand("$VIMRUNTIME/lua/vim/lsp")] = true,
          },
        },
      },
    },
    on_attach = function(client, bufnr)
      require("lsp-inlayhints").on_attach(client, bufnr)
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

  local function buf_set_option(...)
    vim.api.nvim_buf_set_option(bufnr, ...)
  end

  local win_style = { border = "rounded", focusable = false, silent = true }

  -- Enable completion triggered by <c-x><c-o>
  buf_set_option("omnifunc", "v:lua.vim.lsp.omnifunc")

  -- Mappings.
  local opts = { noremap = true, silent = true }
  buf_set_keymap("n", "gr", "m`<cmd>References<CR>", opts)
  buf_set_keymap("n", "gd", "m`<cmd>Definition<CR>", opts)
  buf_set_keymap("n", "gsd", "m`<cmd>vsplit | Definition<CR>", opts)
  buf_set_keymap("n", "gD", "m`<cmd>Declaration<CR>", opts)
  buf_set_keymap("n", "gi", "m`<cmd>Implementation<CR>", opts)
  buf_set_keymap("n", "gy", "m`<cmd>TypeDefinition<CR>", opts)
  buf_set_keymap("n", "gk", "<cmd>lua vim.lsp.buf.hover()<CR>", opts)
  buf_set_keymap("n", "<leader>rn", "<cmd>lua vim.lsp.buf.rename()<CR>", opts)
  buf_set_keymap("n", "<space>ca", "<cmd>lua vim.lsp.buf.code_action()<CR>", opts)
  buf_set_keymap("n", "<space>cl", "<cmd>lua vim.lsp.codelens.run()<CR>", opts)
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

  vim.cmd([[command! IncomingCall lua require"lsp.configs.callhierarchy".incoming_calls()]])
  vim.cmd([[command! OutGoingCall lua require"lsp.configs.callhierarchy".outgoing_calls()]])
  vim.cmd(
    [[command! -bang -nargs=? WorkspaceSymbol lua require("lsp.configs.workspacesymbol").workspace_symbol(<q-args>)]]
  )

  -- Autocmds.
  vim.cmd([[
    augroup LspDefaults
      autocmd!
      " autocmd CursorHold * lua vim.diagnostic.open_float(nil, { border = 'rounded', scope = 'cursor',  focusable = false })
    augroup END
    ]])
  if not vim.g.auto_format_disabled and client.server_capabilities.documentFormattingProvider then
    require("lsp-format").on_attach(client)
    -- vim.cmd [[
    --   augroup LspFormat
    --     autocmd!
    --     autocmd BufWritePre <buffer> lua vim.lsp.buf.format()
    --   augroup END
    -- ]] -- sync? insert_leave?
  end
  if client.server_capabilities.codeLensProvideren then
    vim.cmd([[
      augroup LspCodeLens
        autocmd!
        autocmd InsertLeave,BufWritePost <buffer> lua vim.lsp.codelens.refresh()
      augroup END
    ]])
  end
  if client.server_capabilities.documentHighlightProvider then
    -- require("illuminate").on_attach(client)
  end

  vim.lsp.handlers["textDocument/hover"] = vim.lsp.with(vim.lsp.handlers.hover, { border = "rounded" })

  -- diagnostic settings
  local signs = { Error = " ", Warn = " ", Hint = " ", Info = " " }

  for type, icon in pairs(signs) do
    local hl = "DiagnosticSign" .. type
    vim.fn.sign_define(hl, { text = "", texthl = "", numhl = hl })
  end

  vim.diagnostic.config({
    float = {
      source = "always",
    },
    virtual_text = false,
  })

  require("lsp.configs.fzf").setup()

  require("lsp_signature").on_attach({
    bind = true, -- This is mandatory, otherwise border config won't get registered.
    hint_enable = false,
    handler_opts = {
      border = "rounded",
    },
  }, bufnr)

  -- if client.server_capabilities.inlayHintProvider then
  --   require("lsp-inlayhints").on_attach(client, bufnr)
  -- end

  -- show capabilities
  -- require('lsp.utils').get_capabilities()
end

return M

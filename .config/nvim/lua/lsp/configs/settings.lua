local M = {}

M.configs = {
  html =  {
    settings = {
      html = {
        autoClosingTags = false
      }
    },
    -- update on_attach
    -- on_attach =  function(client, bufnr)
    --   M.default(client, bufnr)
    -- end,
  },
  rust =  {
    settings = {
      ['rust-analyzer'] = {
        completion = {
          autoimport = {
            enabled = true
          }
        },
        lens = {
          references = true,
          methodReferences = true,
        },
        ['cargo-watch'] = {
          enabled = true
        },
        diagnostics = {
          enableExperimental = true
        }
      }
    },
  },
  lua = {
    settings = {
      Lua = {
        diagnostics = {
          globals = {'vim'}
        },
        runtime = {
          version = "LuaJIT",
          path = vim.split(package.path, ";")
        },
        workspace = {
          library = {
            [vim.fn.expand("$VIMRUNTIME/lua")] = true,
            [vim.fn.expand("$VIMRUNTIME/lua/vim/lsp")] = true
          }
        }
      }
    },
  },
}

M.default = function(client, bufnr)
  local function buf_set_keymap(...) vim.api.nvim_buf_set_keymap(bufnr, ...) end
  local function buf_set_option(...) vim.api.nvim_buf_set_option(bufnr, ...) end
  local win_sytle = { border = "none",  focusable = false, silent = true }

  -- Enable completion triggered by <c-x><c-o>
  buf_set_option('omnifunc', 'v:lua.vim.lsp.omnifunc')

  -- Mappings.
  local opts = { noremap=true, silent=true }
  buf_set_keymap('n', 'gr', '<cmd>References<CR>', opts)
  buf_set_keymap('n', 'gd', '<cmd>Definition<CR>', opts)
  buf_set_keymap('n', 'gD', '<cmd>Declaration<CR>', opts)
  buf_set_keymap('n', 'gi', '<cmd>Implementation<CR>', opts)
  buf_set_keymap('n', 'gy', '<cmd>TypeDefinition<CR>', opts)
  buf_set_keymap('n', 'gk', '<cmd>lua vim.lsp.buf.hover()<CR>', opts)
  buf_set_keymap('n', '<leader>rn', '<cmd>lua require("lsp.configs.rename").rename()<CR>', opts)
  buf_set_keymap('n', '<space>ca', '<cmd>lua require"lsp.configs.codeaction".code_action()<CR>', opts)
  buf_set_keymap('n', '<space>cl', '<cmd>lua require"lsp.configs.codelens".run()<CR>', opts)

  -- Commands.
  vim.cmd [[command! Format lua vim.lsp.buf.formatting()]]
  vim.cmd [[command! DiagnosticPrevious lua vim.diagnostic.goto_prev()]]
  vim.cmd [[command! DiagnosticNext lua vim.diagnostic.goto_next()]]
  vim.cmd [[command! DiagnosticQf lua vim.diagnostic.setloclist()]]
  vim.cmd [[command! AddWorkspaceFolder vim.lsp.buf.add_workspace_folder()]]
  vim.cmd [[command! RemoveWorkspaceFolder vim.lsp.buf.remove_workspace_folder()]]
  vim.cmd [[command! ShowWorkspaceFolder lua print(vim.inspect(vim.lsp.buf.list_workspace_folders()))]]

  vim.cmd [[command! IncomingCall lua require"lsp.configs.callhierarchy".incoming_calls()]]
  vim.cmd [[command! OutGoingCall lua require"lsp.configs.callhierarchy".outgoing_calls()]]
  vim.cmd [[command! -bang -nargs=? WorkspaceSymbol lua require("lsp.configs.workspacesymbol").workspace_symbol(<q-args>)]]

  -- Autocmds.
  vim.cmd [[autocmd MyAutoCmd BufWritePre <buffer> lua vim.lsp.buf.formatting_seq_sync()]] -- sync? insert_leave?
  vim.cmd [[autocmd MyAutoCmd CursorHold * lua vim.lsp.diagnostic.show_position_diagnostics({ border = "none",  focusable = false })]]
  vim.cmd [[autocmd MyAutoCmd CursorHoldI * silent! lua vim.lsp.buf.signature_help()]]
  if client.resolved_capabilities['code_lens'] then
    vim.cmd [[autocmd MyAutoCmd InsertLeave,BufWritePost <buffer> lua require"lsp.configs.codelens".refresh()]]
  end

  vim.lsp.handlers["textDocument/hover"] =  vim.lsp.with(vim.lsp.handlers.hover,  win_sytle )
  vim.lsp.handlers["textDocument/signatureHelp"] =  vim.lsp.with(vim.lsp.handlers.signature_help,  win_sytle )

  -- diagnostic settings
  local signs = { Error = " ", Warn = " ", Hint = " ", Info = " " }

  for type, icon in pairs(signs) do
    local hl = "DiagnosticSign" .. type
    vim.fn.sign_define(hl, { text = '', texthl = '', numhl = hl })
  end

  vim.lsp.handlers["textDocument/publishDiagnostics"] = vim.lsp.with(
    vim.lsp.diagnostic.on_publish_diagnostics, {
      virtual_text = false,
      underline = true,
      signs = true,
    }
  )
  require('lsp.configs.fzf').setup()

  -- show capabilities
  -- require('lsp.utils').get_capabilities()
end

return M

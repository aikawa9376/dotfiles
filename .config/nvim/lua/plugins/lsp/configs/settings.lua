local configs = {
  html =  {
    settings = {
      html = {
        autoClosingTags = false
      }
    },
    on_attach =  function(client, bufnr)
      defalt(client, bufnr)
    end,
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
    on_attach =  function(client, bufnr)
      defalt(client, bufnr)
    end,
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
    on_attach =  function(client, bufnr)
      defalt(client, bufnr)
    end,
  },
}

function defalt(client, bufnr)
  local function buf_set_keymap(...) vim.api.nvim_buf_set_keymap(bufnr, ...) end
  local function buf_set_option(...) vim.api.nvim_buf_set_option(bufnr, ...) end

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
  buf_set_keymap('n', '<C-k>', '<cmd>lua vim.lsp.buf.signature_help()<CR>', opts)
  buf_set_keymap('n', '<space>rn', '<cmd>lua vim.lsp.buf.rename()<CR>', opts)
  buf_set_keymap('n', '<space>ca', '<cmd>lua vim.lsp.buf.code_action()<CR>', opts)

  -- Commands.
  vim.cmd [[command! Format lua vim.lsp.buf.formatting()]]
  vim.cmd [[command! DiagnosticPrevious lua vim.lsp.diagnostic.goto_prev()]]
  vim.cmd [[command! DiagnosticNext lua vim.lsp.diagnostic.goto_next()]]
  vim.cmd [[command! DiagnosticQf lua vim.lsp.diagnostic.set_loclist()]]
  vim.cmd [[command! AddWorkspaceFolder vim.lsp.buf.add_workspace_folder()]]
  vim.cmd [[command! RemoveWorkspaceFolder vim.lsp.buf.remove_workspace_folder()]]
  vim.cmd [[command! ShowWorkspaceFolder lua print(vim.inspect(vim.lsp.buf.list_workspace_folders()))]]

  -- Autocmds.
  vim.cmd [[autocmd MyAutoCmd BufWritePost <buffer> lua vim.lsp.buf.formatting()]]
  vim.cmd [[autocmd MyAutoCmd CursorHold,CursorHoldI * lua vim.lsp.diagnostic.show_line_diagnostics({ focusable = false })]]
  -- TODO focusable false not work
  -- vim.cmd [[autocmd MyAutoCmd CursorHoldI * lua vim.lsp.buf.signature_help({ focusable = false })]]
  if client.resolved_capabilities['code_lens'] then
    vim.cmd [[autocmd MyAutoCmd InsertLeave * lua vim.lsp.codelens.refresh()]]
  end

  -- show capabilities
  -- require('plugins.lsp.utils').get_capabilities()
end

return configs

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
  buf_set_keymap('n', '<leader>rn', '<cmd>lua Rename.rename()<CR>', opts)
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
  vim.cmd [[autocmd MyAutoCmd BufWritePre <buffer> lua vim.lsp.buf.formatting_seq_sync()]] -- sync? insert_leave?
  vim.cmd [[autocmd MyAutoCmd CursorHold * lua vim.lsp.diagnostic.show_line_diagnostics({ border = "none",  focusable = false })]]
  vim.cmd [[autocmd MyAutoCmd CursorHoldI * silent! lua vim.lsp.buf.signature_help()]]
  if client.resolved_capabilities['code_lens'] then
    vim.cmd [[autocmd MyAutoCmd InsertLeave,BufWritePost * lua vim.lsp.codelens.refresh()]]
  end

  vim.lsp.handlers["textDocument/hover"] =  vim.lsp.with(vim.lsp.handlers.hover,  win_sytle )
  vim.lsp.handlers["textDocument/signatureHelp"] =  vim.lsp.with(vim.lsp.handlers.signature_help,  win_sytle )

  -- rename settings
  local function dorename(win)
    local new_name = vim.trim(vim.fn.getline('.'))
    vim.api.nvim_win_close(win, true)
    vim.lsp.buf.rename(new_name)
  end

  local function rename()
    local opts = {
      relative = 'cursor', row = 1,
      col = 0, width = 30,
      height = 1, style = 'minimal'
    }
    local cword = vim.fn.expand('<cword>')
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, true, opts)
    local fmt =  '<cmd>lua Rename.dorename(%d)<CR>'
    vim.api.nvim_win_set_option(win, 'winhighlight', 'Normal:NormalFloat')

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {cword})
    vim.api.nvim_buf_set_keymap(buf, 'i', '<CR>', string.format(fmt, win), {silent=true})
    vim.api.nvim_buf_set_keymap(buf, 'n', '<ESC>', ':lua vim.api.nvim_win_close(win, true)<CR>' , {silent=true})
    vim.api.nvim_win_set_cursor(win, {1, #cword})
  end

  _G.Rename = {
    rename = rename,
    dorename = dorename
  }

  -- diagnostic settings
  local signs = { Error = " ", Warning = " ", Hint = " ", Information = " " }

  for type, icon in pairs(signs) do
    local hl = "LspDiagnosticsSign" .. type
    vim.fn.sign_define(hl, { text = '', texthl = '', numhl = hl })
  end

  vim.lsp.handlers["textDocument/publishDiagnostics"] = vim.lsp.with(
    vim.lsp.diagnostic.on_publish_diagnostics, {
      virtual_text = false,
      underline = true,
      signs = true,
    }
  )

  -- show capabilities
  -- require('plugins.lsp.utils').get_capabilities()
end

return M

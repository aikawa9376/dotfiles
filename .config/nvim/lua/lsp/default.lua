local M = {}

M.settings = function(client, bufnr)
  local function buf_set_keymap(...)
    vim.api.nvim_buf_set_keymap(bufnr, ...)
  end

  local function buf_set_option(name, value)
    vim.api.nvim_set_option_value(name, value, { buf = bufnr })
  end

  -- Enable completion triggered by <c-x><c-o>
  buf_set_option("omnifunc", "v:lua.vim.lsp.omnifunc")

  -- disable default lsp keybindings
  vim.keymap.set("n", "grr", "<Nop>", { buffer = bufnr, silent = true })
  vim.keymap.set("n", "grn", "<Nop>", { buffer = bufnr, silent = true })
  vim.keymap.set("n", "gra", "<Nop>", { buffer = bufnr, silent = true })
  vim.keymap.set("n", "gri", "<Nop>", { buffer = bufnr, silent = true })

  -- Mappings.
  local opts = { noremap = true, silent = true, nowait = true }
  buf_set_keymap("n", "gr", "m`:FzfLua lsp_references<CR>", opts)
  buf_set_keymap("n", "gR", "m`:FzfLua lsp_finder<CR>", opts)
  -- buf_set_keymap("n", "gd", "m`:FzfLua lsp_definitions<CR>", opts)
  buf_set_keymap("n", "gd", "m`:lua require'plugins.fzf-lua_util'.fzf_laravel()<CR>", opts)
  buf_set_keymap("n", "gsd", "m`:vsplit | FzfLua lsp_definitions<CR>", opts)
  buf_set_keymap("n", "gD", "m`:FzfLua lsp_declarations<CR>", opts)
  buf_set_keymap("n", "gi", "m`:FzfLua lsp_implementations<CR>", opts)
  buf_set_keymap("n", "gy", "m`:FzfLua lsp_typedefs<CR>", opts)
  buf_set_keymap("n", "gk", "<cmd>lua vim.lsp.buf.hover()<CR>", opts)
  buf_set_keymap("n", "<leader>rn", "<cmd>lua vim.lsp.buf.rename()<CR>", opts)
  buf_set_keymap("n", "<Leader>ca", ":FzfLua lsp_code_actions<CR>", opts)
  buf_set_keymap("n", "<Leader>cl", "<cmd>lua vim.lsp.codelens.run()<CR>", opts)
  buf_set_keymap(
    "n",
    "gq",
    "<cmd>lua vim.diagnostic.open_float(nil, { scope = 'cursor',  focusable = true })<cr>",
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

  -- use blink.cmp
  -- if client.server_capabilities.signatureHelpProvider then
  --   require("lsp_signature").on_attach({
  --     bind = true, -- This is mandatory, otherwise border config won't get registered.
  --     hint_enable = false,
  --     handler_opts = {
  --       border = "single",
  --     },
  --   }, bufnr)
  -- end

  if client.server_capabilities.inlayHintProvider then
    vim.lsp.inlay_hint.enable(true, { bufnr = bufnr })
  end

  if client.server_capabilities.colorProvider then
    vim.lsp.document_color.enable(false, bufnr, { style = "foreground" })
  end
end

return M

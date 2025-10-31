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
  local keyopts = { noremap = true, silent = true, nowait = true }
  buf_set_keymap("n", "gr", "m`:FzfLua lsp_references<CR>", keyopts)
  buf_set_keymap("n", "gR", "m`:FzfLua lsp_finder<CR>", keyopts)
  -- buf_set_keymap("n", "gd", "m`:FzfLua lsp_definitions<CR>", keyopts)
  buf_set_keymap("n", "gd", "m`:lua require'plugins.fzf-lua_util'.fzf_laravel()<CR>", keyopts)
  buf_set_keymap("n", "gsd", "m`:vsplit | FzfLua lsp_definitions<CR>", keyopts)
  buf_set_keymap("n", "gD", "m`:FzfLua lsp_declarations<CR>", keyopts)
  buf_set_keymap("n", "gi", "m`:FzfLua lsp_implementations<CR>", keyopts)
  buf_set_keymap("n", "gy", "m`:FzfLua lsp_typedefs<CR>", keyopts)
  buf_set_keymap("n", "gk", "<cmd>lua vim.lsp.buf.hover()<CR>", keyopts)
  buf_set_keymap("n", "<leader>rn", "<cmd>lua vim.lsp.buf.rename()<CR>", keyopts)
  buf_set_keymap("n", "<Leader>ca", ":FzfLua lsp_code_actions<CR>", keyopts)
  buf_set_keymap("n", "<Leader>cl", "<cmd>lua vim.lsp.codelens.run()<CR>", keyopts)
  buf_set_keymap(
    "n",
    "gq",
    "<cmd>lua vim.diagnostic.open_float(nil, { scope = 'cursor',  focusable = true })<cr>",
    keyopts
  )

  -- Commands.
  vim.api.nvim_create_user_command("DiagnosticPrevious", function() vim.diagnostic.jump({ count = -1 }) end, {})
  vim.api.nvim_create_user_command("DiagnosticNext", function() vim.diagnostic.jump({ count = 1 }) end, {})
  vim.api.nvim_create_user_command("DiagnosticQf", function() vim.diagnostic.setloclist() end, {})
  vim.api.nvim_create_user_command("AddWorkspaceFolder", function() vim.lsp.buf.add_workspace_folder() end, {})
  vim.api.nvim_create_user_command("RemoveWorkspaceFolder", function() vim.lsp.buf.remove_workspace_folder() end, {})
  vim.api.nvim_create_user_command("ShowWorkspaceFolder", function() print(vim.inspect(vim.lsp.buf.list_workspace_folders())) end, {})
  vim.api.nvim_create_user_command("IncomingCall", function() vim.cmd("FzfLua lsp_incoming_calls") end, {})
  vim.api.nvim_create_user_command("OutGoingCall", function() vim.cmd("FzfLua lsp_outgoing_calls") end, {})
  vim.api.nvim_create_user_command("WorkspaceSymbol",
    function(opts) vim.cmd("FzfLua lsp_live_workspace_symbols " .. opts.args or "" .. opts.bang and "!" or "") end,
    { bang = true, nargs = "?" }
  )
  vim.api.nvim_create_user_command("InlayToggle", function()
    local buf = vim.api.nvim_get_current_buf()
    local enabled = vim.lsp.inlay_hint.is_enabled({ buf = buf })
    vim.lsp.inlay_hint.enable(not enabled, { buf = buf })
  end, {})

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
    -- Temporary processing
    vim.cmd('InlayToggle')
  end

  if client.server_capabilities.colorProvider then
    vim.lsp.document_color.enable(false, bufnr, { style = "foreground" })
  end

  -- diagnostic settings
  require"lsp.diagnostic".settings()
end

return M

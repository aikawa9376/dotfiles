---@type vim.lsp.Config
return {
  settings = {
    stylelintplus = {
      autoFixOnSave = true,
      autoFixOnFormat = true,
    },
  },
  filetypes = { "css", "less", "scss", "sugarss", "wxss" },
}

return {
  "yioneko/nvim-vtsls",
  ft = { "javascript", "typescript", "typescriptreact", "typescript.tsx" },
  config = function ()
    require"vtsls".config({})
  end
}

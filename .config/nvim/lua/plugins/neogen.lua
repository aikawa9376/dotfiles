return {
  "danymat/neogen",
  cmd = "Neogen",
  opts = {
    snippet_engine = 'luasnip',
    languages = {
      lua = {
        template = {
          annotation_convention = "emmylua"
        }
      },
      typescriptreact = {
        template = {
          annotation_convention = "tsdoc"
        }
      },
    }
  }
}

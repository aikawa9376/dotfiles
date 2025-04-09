return {
  "hrsh7th/nvim-automa",
  keys = { '.' },
  config = function ()
    require('automa').setup({
      mapping = {
        ['.'] = {
          queries = {
            -- wide-range dot-repeat definition.
            require('automa').query_v1({ '!n(h,j,k,l)+' }),
          }
        },
      }
    })
  end
}

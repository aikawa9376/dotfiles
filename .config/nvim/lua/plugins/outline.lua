return {
  "hedyhli/outline.nvim",
  keys = {
    {'<leader>o', '<cmd>Outline<CR>', mode = { "n" }, silent = true }
  },
  opts = {
    outline_window = {
      width = 20,
      focus_on_open = false,
    },
    symbol_folding = {
      -- Depth past which nodes will be folded by default. Set to false to unfold all on open.
      autofold_depth = false,
      -- When to auto unfold nodes
      auto_unfold = {
        -- Auto unfold currently hovered symbol
        hovered = true,
        -- Auto fold when the root level only has this many nodes.
        -- Set true for 1 node, false for 0.
        only = true,
      },
      markers = { '', '' },
    },
  },
}

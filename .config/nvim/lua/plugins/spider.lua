return {
  "chrisgrieser/nvim-spider",
  keys = {
    { "w", "<cmd>lua require('spider').motion('w')<CR>", mode = { "n", "x" } },
    { "e", "<cmd>lua require('spider').motion('e')<CR>", mode = { "n", "x" } },
    { "b", "<cmd>lua require('spider').motion('b')<CR>", mode = { "n", "x" } },
  },
  opts = {
    subwordMovement = false,
  }
}

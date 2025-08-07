return {
  "andymass/vim-matchup",
  event = "BufRead",
  keys = {
    { "<C-Space>", "<Plug>(matchup-z%)", mode = { "n", "x" } },
  },
  init = function ()
    vim.g.matchup_matchparen_offscreen = { method = "status_manual" }
  end
}

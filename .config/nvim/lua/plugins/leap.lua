local labels = {
  "a",
  "b",
  "c",
  "d",
  "e",
  "f",
  "g",
  "h",
  "i",
  "j",
  "k",
  "l",
  "m",
  "n",
  "o",
  "p",
  "q",
  "r",
  "s",
  "t",
  "u",
  "v",
  "w",
  "x",
  "y",
  "z",
  ".",
  "'",
  "/",
}

local safe_labels = {
  "b",
  "e",
  "f",
  "g",
  "m",
  "n",
  "o",
  "p",
  "q",
  "r",
  "s",
  "t",
  "u",
  "w",
  "z",
  ".",
  "'",
  "/",
}

local leap = require("leap")
leap.opts.max_phase_one_targets = nil
leap.opts.highlight_unlabeled_phase_one_targets = false
leap.opts.max_highlighted_traversal_targets = 10
leap.opts.case_sensitive = false
leap.opts.equivalence_classes = { " \t\r\n" }
leap.opts.substitute_chars = {}
leap.opts.safe_labels = safe_labels
leap.opts.labels = labels
leap.opts.special_keys = {
  repeat_search = "<C-space>",
  next_phase_one_target = ";",
  next_target = { ";" },
  prev_target = { "," },
  next_group = "<space>",
  prev_group = "<tab>",
  multi_accept = ";",
  multi_revert = ",",
}

leap.opts.highlight_unlabeled_phase_one_targets = true
vim.api.nvim_set_hl(0, "LeapLabel", { fg = "#B9FA71", bold = true })
vim.api.nvim_set_hl(0, "LeapBackdrop", { fg = "#777777" })
vim.api.nvim_set_hl(0, "LeapMatch", {
  fg = "white", -- for light themes, set to 'black' or similar
  bold = true,
  nocombine = true,
})

vim.keymap.set({ "n", "x", "o" }, "<C-j>", "<Plug>(leap-forward-to)")
vim.keymap.set({ "n", "x", "o" }, "<C-k>", "<Plug>(leap-backward-to)")

require("flit").setup({
  keys = { f = "f", F = "F", t = "t", T = "T" },
  -- A string like "nv", "nvo", "o", etc.
  labeled_modes = "n,v",
  multiline = true,
  -- Like `leap`s similar argument (call-specific overrides).
  -- E.g.: opts = { equivalence_classes = {} }
  opts = {},
})

return {
  "kwkarlwang/bufjump.nvim",
  keys = {
    -- { "]j" },
    -- { "[j" },
    { "<M-i>" },
    { "<M-o>" }
  },
  opts = {
    -- forward_key = "]o",
    -- backward_key = "[o",
    forward_same_buf_key = "<M-i>",
    backward_same_buf_key = "<M-o>",
    on_success = nil
  }
}

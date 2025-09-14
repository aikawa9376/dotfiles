return {
  "kwkarlwang/bufjump.nvim",
  keys = {
    -- { "]j" },
    -- { "[j" },
    { "<M-i>" },
    { "<M-o>" }
  },
  opts = {
    -- forward_key = "]j",
    -- backward_key = "[j",
    forward_same_buf_key = "<M-i>",
    backward_same_buf_key = "<M-o>",
    on_success = nil
  }
}

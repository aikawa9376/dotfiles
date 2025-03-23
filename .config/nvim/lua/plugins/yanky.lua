return {
  "gbprod/yanky.nvim",
  keys = {
    { "y", "m`mvmr<Plug>(YankyYank)", mode = { "n", "x" } },
    { "=p", "<Plug>(YankyPutAfterFilterJoined)" },
    { "=P", "<Plug>(YankyPutBeforeFilterJoined)" }
  },
  opts = {
    ring = {
      history_length = 100,
      storage = "shada",
      storage_path = vim.fn.stdpath("data") .. "/databases/yanky.db", -- Only for sqlite storage
      sync_with_numbered_registers = true,
      cancel_event = "update",
      ignore_registers = { "_" },
      update_register_on_cycle = false,
      permanent_wrapper = nil,
    },
    picker = {
      select = {
        action = nil, -- nil to use default put action
      },
    },
    system_clipboard = {
      sync_with_ring = true,
      clipboard_register = nil,
    },
    highlight = {
      on_put = false,
      on_yank = true,
      timer = 500,
    },
    preserve_cursor_position = {
      enabled = true,
    },
    textobj = {
      enabled = true,
    },
  }
}

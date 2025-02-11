require'yanky'.setup({
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
    on_yank = false,
    timer = 500,
  },
  preserve_cursor_position = {
    enabled = true,
  },
  textobj = {
   enabled = true,
  },
})

vim.keymap.set({"n","x"}, "y", "m`mvmr<Plug>(YankyYank)")
vim.keymap.set("n", "=p", "<Plug>(YankyPutAfterFilterJoined)")
vim.keymap.set("n", "=P", "<Plug>(YankyPutBeforeFilterJoined)")

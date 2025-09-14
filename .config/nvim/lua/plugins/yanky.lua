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
      on_yank = false,
      timer = 500,
    },
    preserve_cursor_position = {
      enabled = true,
    },
    textobj = {
      enabled = true,
    },
  },
  init = function ()
    -- 空文字の場合レジスタに入れない
    vim.api.nvim_create_autocmd("TextYankPost", {
      callback = function()
        local reg = vim.v.register  -- 現在のレジスタ
        local yanked_text = vim.fn.getreg(reg)  -- レジスタの内容

        if yanked_text:match("^%s*$") then
          local prev_yank = require("yanky.history").first()

          if prev_yank and prev_yank.regcontents then
            vim.fn.setreg("+", prev_yank.regcontents)
          end
        else
          -- require("yanky.history").push({
          --   regcontents = yanked_text,
          --   regtype = "y",
          -- })
        end
      end
    })
  end
}

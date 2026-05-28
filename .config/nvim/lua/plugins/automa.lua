return {
  "hrsh7th/nvim-automa",
  keys = {
    { ".", mode = "n", desc = "Repeat edit with automa" },
  },
  cmd = { "AutomaToggleDebugger" },
  config = function()
    local automa = require("automa")

    automa.setup({
      mapping = {
        ["."] = {
          queries = {
            -- Broad automa-first repeat. Native dot remains only as fallback.
            automa.query_v1({ "n#" }),
            automa.query_v1({ "n(i,a,I,A,o,O,s,S)", "i*" }),
            automa.query_v1({ "n(i,a,I,A,o,O,s,S)", "R*" }),
            automa.query_v1({ "n", "v*" }),
            automa.query_v1({ "n", "V*" }),
            -- `ciqtest`, `ciwfoo`, etc. operator-pending -> insert.
            automa.query_v1({ "n", "no+", "n#" }),
            automa.query_v1({ "n", "no+", "i*" }),
            automa.query_v1({ "n", "no+", "R*" }),
            -- `di\"itest`, `dawibar`, etc. operator-pending -> normal insert -> insert.
            automa.query_v1({ "n", "no+", "n(i,a,I,A,o,O,s,S)", "i*" }),
            automa.query_v1({ "n", "no+", "n(i,a,I,A,o,O,s,S)", "R*" }),
            -- Last resort: keep replaying until a clear motion boundary appears.
            automa.query_v1({ "!n(h,j,k,l,w,b,e,0,^,$,<C-u>,<C-d>,<C-b>,<C-f>,<PageUp>,<PageDown>)+" }),
          },
        },
      },
    })

    vim.keymap.set("n", ".", function()
      local typed = automa.fetch(".")
      if typed == "" then
        vim.cmd("normal! .")
        return
      end
      vim.api.nvim_feedkeys(typed, "m", false)
    end, {
      silent = true,
      remap = false,
      desc = "Repeat edit with automa",
    })

    vim.api.nvim_create_user_command("AutomaToggleDebugger", function()
      automa.toggle_debug_panel()
    end, {
      desc = "Toggle automa debugger",
    })
  end,
}

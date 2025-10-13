return {
  "L3MON4D3/LuaSnip",
  lazy = true,
  build = "make install_jsregexp",
  keys = {
    { "<C-Space>", mode = { "i", "s" } },
    { "<M-j>", "<Plug>luasnip-jump-next", mode = { "i", "s" } },
    { "<M-k>", "<Plug>luasnip-jump-prev", mode = { "i", "s" } },
    { "<M-e>", "<Plug>luasnip-next-choice", mode = { "i", "s" } },
    { "<C-Space>", "<Plug>luasnip-expand-or-jump", mode = { "s" } },
    { "p", "p", mode = { "s" } },
  },
  config = function ()
    local ls = require("luasnip")

    -- Every unspecified option will be set to the default.
    ls.config.set_config({
      history = true,
      -- Update more often, :h events for more info.
      updateevents = "TextChanged,TextChangedI",
      ext_opts = {
        [require("luasnip.util.types").choiceNode] = {
          active = {
            virt_text = { { "choiceNode", "Comment" } },
          },
        },
      },
      delete_check_events = "TextChanged",
      region_check_events = "InsertEnter",
      enable_autosnippets = true,
      ext_base_prio = 300,
      ext_prio_increase = 1,
    })

    require("luasnip.loaders.from_lua").load({ paths = "./lua/snippets" })
    require("luasnip.loaders.from_vscode").lazy_load()
    -- require("luasnip.loaders.from_snipmate").load()

    ls.filetype_set("cpp", { "c" })
    ls.filetype_extend("lua", { "c" })
    ls.filetype_extend("typescriptreact", { "html", "javascript" })
    ls.filetype_extend("typescript", { "javascript" })
  end
}

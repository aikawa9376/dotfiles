return {
  "L3MON4D3/LuaSnip",
  lazy = true,
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
    -- some shorthands...
    local s = ls.snippet
    local sn = ls.snippet_node
    local t = ls.text_node
    local i = ls.insert_node
    local f = ls.function_node
    local c = ls.choice_node
    local d = ls.dynamic_node
    local l = require("luasnip.extras").lambda
    local r = require("luasnip.extras").rep
    local p = require("luasnip.extras").partial
    local m = require("luasnip.extras").match
    local n = require("luasnip.extras").nonempty
    local dl = require("luasnip.extras").dynamic_lambda
    local types = require("luasnip.util.types")

    -- Every unspecified option will be set to the default.
    ls.config.set_config({
      history = true,
      -- Update more often, :h events for more info.
      updateevents = "TextChanged,TextChangedI",
      ext_opts = {
        [types.choiceNode] = {
          active = {
            virt_text = { { "choiceNode", "Comment" } },
          },
        },
      },
      delete_check_events = "TextChanged",
      region_check_events = "InsertEnter",
      enable_autosnippets = true,
      -- treesitter-hl has 100, use something higher (default is 200).
      ext_base_prio = 300,
      -- minimal increase in priority.
      ext_prio_increase = 1,
    })

    -- 'recursive' dynamic snippet. Expands to some text followed by itself.
    local rec_ls
    rec_ls = function()
      return sn(
        nil,
        c(1, {
          -- Order is important, sn(...) first would cause infinite loop of expansion.
          t(""),
          sn(nil, { t({ "", "\t\\item " }), i(1), d(2, rec_ls, {}) }),
        })
      )
    end

    -- Returns a snippet_node wrapped around an insert_node whose initial
    -- text value is set to the current date in the desired format.
    local date_input = function(args, state, fmt)
      local fmt = fmt or "%Y-%m-%d"
      return sn(nil, i(1, os.date(fmt)))
    end

    ls.add_snippets(nil, {
      -- When trying to expand a snippet, luasnip first searches the tables for
      -- eah filetype specified in 'filetype' followed by 'all'.
      -- If ie. the filetype is 'lua.c'
      --     - luasnip.lua
      --     - luasnip.c
      --     - luasnip.all
      -- are searched in that order.
      all = {
        -- Use a dynamic_node to interpolate the output of a
        -- function (see date_input above) into the initial
        -- value of an insert_node.
        s("novel", {
          t("It was a dark and stormy night on "),
          d(1, date_input, {}, "%A, %B %d of %Y"),
          t(" and the clocks were striking thirteen."),
        }),
      },
      scss = require('snippets.scss'),
      toml = require('snippets.toml'),
      lua = require('snippets.lua'),
      php = require('snippets.php'),
      blade = require('snippets.blade'),
      javascript = require('snippets.javascript')
    })

    -- autotriggered snippets have to be defined in a separate table, luasnip.autosnippets.
    ls.autosnippets = {
      all = {
        s("autotrigger", {
          t("autosnippet"),
        }),
      },
    }

    --[[
    -- Beside defining your own snippets you can also load snippets from "vscode-like" packages
    -- that expose snippets in json files, for example <https://github.com/rafamadriz/friendly-snippets>.
    -- Mind that this will extend  `ls.snippets` so you need to do it after your own snippets or you
    -- will need to extend the table yourself instead of setting a new one.
    ]]

    require("luasnip.loaders.from_vscode").lazy_load()
    -- require("luasnip.loaders.from_snipmate").load()

    -- filetype hack
    -- in a lua file: search lua-, then c-, then all-snippets.
    ls.filetype_extend("lua", { "c" })
    -- in a cpp file: search c-snippets, then all-snippets only (no cpp-snippets!!).
    ls.filetype_set("cpp", { "c" })
    ls.filetype_extend("typescriptreact", { "html", "javascript" })
    ls.filetype_extend("typescript", { "javascript" })
  end
}

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

local blade = {
  -- rec_ls is self-referencing. That makes this snippet 'infinite' eg. have as many
  -- \item as necessary by utilizing a choiceNode.
  s("php", {
    t({ "@php", "" }),
    t("\t"), i(1, "here"),
    t({ "", "@endphp" }),
  }),
  s("if", {
    t({ "@if (" }), i(1, "here"), t({ ")", "" }),
    t("\t"), i(2, "here"),
    t({ "", "@endif" }),
  }),
  s("fore", {
    t({ "@foreach (" }), i(1, "$key"), t({ " as " }), i(2, "$value"), t({ ")", "" }),
    t("\t"), i(3, "here"),
    t({ "", "@endforeach" }),
  }),
}

return blade

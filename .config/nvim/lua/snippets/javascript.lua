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

local javascript = {
  s("af", {
    t("const "), i(1), t(" = ("), i(2), t({") => {", ""}),
    t("\t"), i(3),
    t({"", "}"}),
  }),
  s("cf", {
    t("("), i(1), t({") => {", ""}),
    t("\t"), i(2),
    t({"", "}"}),
  }),
  s("ci", {
    t("("), i(1), t(") => {"),
    t("\t"), i(2), t("}"),
  }),
  s("cls", {
    t("className={styles"), i(1), t("}"),
  }),
  s("cli", {
    t("className={`${styles"), i(1), t("}`}"),
  }),
}

return javascript

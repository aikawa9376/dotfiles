local ls = require("luasnip")

local s = ls.snippet
local sn = ls.snippet_node
local t = ls.text_node
local i = ls.insert_node
local d = ls.dynamic_node

local date_input = function(_, _, fmt)
  local real_fmt = fmt or "%Y-%m-%d"
  return sn(nil, i(1, os.date(real_fmt)))
end

local lua = {
  s("novel", {
    t("It was a dark and stormy night on "),
    d(1, date_input, {}, "%A, %B %d of %Y"),
    t(" and the clocks were striking thirteen."),
  }),
}

return lua

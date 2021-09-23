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
local conds = require("luasnip.extras.conditions")

local is_url = function(args, state)
  local register = vim.api.nvim_eval('@*')
  if string.match(register, '.-%/.-') then
    return i(1, register)
  else
    return i(1, 'here')
  end
end

local lua = {
  s("plug", {
    t({"[[plugins]]", ""}),
    t("repo = '"),
    d(1, is_url, {}),
    t("'"),
  }),
  s('hook_add', {
    t({"hook_add = '''", ""}),
    i(1),
    t({"", "''"})
  }),
  s('hook_source', {
    t({"hook_source = '''", ""}),
    i(1),
    t({"", "''"})
  })
}

return lua

local original_select = vim.ui.select
local wrapper_select
local loading = false

local function ensure_fzf_ui_select()
  if vim.ui.select ~= wrapper_select then
    return true
  end

  if not package.loaded["fzf-lua"] then
    local ok_lazy, lazy = pcall(require, "lazy")
    if not ok_lazy then
      return false
    end

    local ok_load = pcall(lazy.load, { plugins = { "fzf-lua" } })
    if not ok_load then
      return false
    end
  end

  local ok_util, util = pcall(require, "plugins.fzf-lua_util")
  if not ok_util or type(util.register_ui_select) ~= "function" then
    return false
  end

  local ok_register = pcall(util.register_ui_select)
  if not ok_register then
    return false
  end

  return vim.ui.select ~= wrapper_select
end

wrapper_select = function(items, opts, on_choice)
  if loading then
    return original_select(items, opts, on_choice)
  end

  loading = true
  local ok = ensure_fzf_ui_select()
  loading = false

  if ok and vim.ui.select ~= wrapper_select then
    return vim.ui.select(items, opts, on_choice)
  end

  return original_select(items, opts, on_choice)
end

vim.ui.select = wrapper_select

return wrapper_select

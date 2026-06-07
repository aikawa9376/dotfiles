local utils = require("laravel_extension.utils")

local M = {}

local function fallback_definition()
  local ok_nav, navigate = pcall(require, "laravel.navigate")
  if ok_nav and type(navigate.is_laravel_navigation_context) == "function" then
    local ok_context, is_context = pcall(navigate.is_laravel_navigation_context)
    if ok_context and is_context and type(navigate.goto_laravel_string) == "function" then
      local ok_goto, result = pcall(navigate.goto_laravel_string)
      if ok_goto and result ~= false then
        return true
      end
    end
  end

  if vim.lsp and vim.lsp.buf and vim.lsp.buf.definition then
    vim.lsp.buf.definition()
    return true
  end

  vim.cmd("normal! gd")
  return true
end

function M.goto_definition()
  local livewire = require("laravel_extension.features.livewire")
  if livewire.goto_livewire_at_cursor({ notify = false }) then
    return true
  end

  local component = require("laravel_extension.features.component")
  if component.goto_component_at_cursor({ notify = false }) then
    return true
  end

  local view = require("laravel_extension.features.view")
  if view.goto_view_at_cursor({ notify = false, fallback_to_laravel = false }) then
    return true
  end

  return fallback_definition()
end

function M.setup(group)
  group = group or vim.api.nvim_create_augroup("laravel_extension_definition", { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = { "php", "blade" },
    callback = function(ev)
      if not utils.project_root(ev.buf) then
        return
      end

      vim.keymap.set("n", "df", M.goto_definition, {
        buffer = ev.buf,
        silent = true,
        desc = "Laravel: Follow definition",
      })
    end,
  })
end

return M

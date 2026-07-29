local M = {}

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local definition = require("laravel_extension.features.definition")
  local original_navigate = package.loaded["laravel.navigate"]
  local original_bufnr = vim.api.nvim_get_current_buf()
  local navigation_calls = 0
  package.loaded["laravel.navigate"] = {
    is_laravel_navigation_context = function() return true end,
    goto_laravel_string = function()
      navigation_calls = navigation_calls + 1
      return true
    end,
  }

  local line = "$viewerUsecase->render('dashboard');"
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, bufnr)
  vim.bo[bufnr].filetype = "php"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })

  vim.api.nvim_win_set_cursor(0, { 1, assert(line:find("viewerUsecase", 1, true)) - 1 })
  assert_equal(definition.goto_laravel_nvim_string(), false, "PHP identifier does not trigger Blade navigation")
  assert_equal(navigation_calls, 0, "Laravel navigation skipped on PHP identifier")

  vim.api.nvim_win_set_cursor(0, { 1, assert(line:find("dashboard", 1, true)) - 1 })
  assert_equal(definition.goto_laravel_nvim_string(), true, "quoted Laravel target allows navigation")
  assert_equal(navigation_calls, 1, "Laravel navigation runs on quoted target")

  package.loaded["laravel.navigate"] = original_navigate
  if vim.api.nvim_buf_is_valid(original_bufnr) then vim.api.nvim_win_set_buf(0, original_bufnr) end
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

return M

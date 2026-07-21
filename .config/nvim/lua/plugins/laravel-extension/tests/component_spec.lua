local M = {}

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local component = require("laravel_extension.features.component")
  local root = vim.fn.tempname() .. "-laravel-component-references"
  local class_dir = root .. "/app/View/Components/Hoge"
  local view_dir = root .. "/resources/views/pages"
  vim.fn.mkdir(class_dir, "p")
  vim.fn.mkdir(view_dir, "p")
  vim.fn.writefile({ "#!/usr/bin/env php" }, root .. "/artisan")

  local class_path = class_dir .. "/Fuge.php"
  local view_path = view_dir .. "/show.blade.php"
  vim.fn.writefile({
    "<?php",
    "class Fuge extends Component {",
    "    public function render(): View {}",
    "}",
  }, class_path)
  vim.fn.writefile({
    "<section>",
    "    <x-hoge.fuge />",
    "    <x-hoge.fuge></x-hoge.fuge>",
    "    <x-hoge.fuged />",
    "</section>",
  }, view_path)

  assert_equal(component.component_name_from_class_path(class_path, root), "hoge.fuge", "nested class path to tag")
  assert_equal(component.component_name_from_class_path(root .. "/app/Models/Fuge.php", root), nil, "non-component path")

  vim.cmd("edit " .. vim.fn.fnameescape(class_path))
  vim.bo.filetype = "php"
  vim.api.nvim_win_set_cursor(0, { 2, 7 })
  assert_equal(component.component_class_at_cursor(0, root), "hoge.fuge", "cursor on component class name")

  local selected_items, selected_opts
  local lsp_item = {
    kind = "php",
    path = class_path,
    row = 2,
    col = 7,
    text = "class Fuge extends Component {",
  }
  local handled = component.goto_references_at_cursor({
    root = root,
    request_lsp_references = function(_, _, callback) callback({ lsp_item }) end,
    picker = function(items, opts)
      selected_items, selected_opts = items, opts
    end,
  })
  assert_equal(handled, true, "component class references handled")
  assert(vim.wait(2000, function() return selected_items ~= nil end, 10), "component reference search completes")
  assert(selected_items and selected_opts, "component reference picker state")
  assert_equal(#selected_items, 4, "php reference and three blade tag occurrences")
  assert_equal(selected_items[1].kind, "php", "php reference retained")
  assert_equal(selected_items[2].kind, "blade", "blade opening tag added")
  assert_equal(selected_items[3].kind, "blade", "second blade opening tag added")
  assert_equal(selected_items[4].kind, "blade", "blade closing tag added")
  assert_equal(selected_items[2].path, view_path, "blade reference path")
  assert_equal(selected_items[2].row, 2, "blade reference row")
  assert(selected_opts.prompt:find("<x%-hoge%.fuge>"), "component tag in picker prompt")

  vim.api.nvim_win_set_cursor(0, { 3, 22 })
  assert_equal(component.component_class_at_cursor(0, root), nil, "method cursor is not component class reference")
  assert_equal(component.goto_references_at_cursor({ root = root }), false, "method gr falls back to normal LSP references")

  vim.cmd("enew")
  vim.fn.delete(root, "rf")
end

return M

local M = {}

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local definition = require("laravel_extension.features.definition")
  local root = vim.fn.tempname() .. "-laravel-definition"
  vim.fn.mkdir(root, "p")
  local source_path = root .. "/Consumer.php"
  local interface_path = root .. "/Repository.php"
  local implementation_path = root .. "/DatabaseRepository.php"
  vim.fn.writefile({ "<?php", "$repository->find(1);" }, source_path)
  vim.fn.writefile({
    "<?php",
    "interface Repository {",
    "    public function find(int $id): object;",
    "}",
  }, interface_path)
  vim.fn.writefile({
    "<?php",
    "final class DatabaseRepository implements Repository {",
    "    public function find(int $id): object {}",
    "}",
  }, implementation_path)

  vim.cmd("edit " .. vim.fn.fnameescape(source_path))
  vim.bo.filetype = "php"
  local interface_location = {
    location = {
      uri = vim.uri_from_fname(interface_path),
      range = { start = { line = 2, character = 20 }, ["end"] = { line = 2, character = 24 } },
    },
    encoding = "utf-16",
  }
  local implementation_location = {
    uri = vim.uri_from_fname(implementation_path),
    range = { start = { line = 2, character = 20 }, ["end"] = { line = 2, character = 24 } },
  }
  assert_equal(definition.is_interface_location(interface_location), true, "interface method location")

  local original_get_clients = vim.lsp.get_clients
  local original_select = vim.ui.select
  local original_show_document = vim.lsp.util.show_document
  local selected_items, selected_opts, opened
  local requested = {}
  local client = {
    offset_encoding = "utf-16",
    definition_result = interface_location.location,
    implementation_result = { implementation_location },
  }
  function client:supports_method(method)
    return method == "textDocument/definition" or method == "textDocument/implementation"
  end
  function client:request(method, _, callback)
    requested[#requested + 1] = method
    callback(nil, method == "textDocument/definition" and self.definition_result or self.implementation_result)
    return true
  end

  vim.lsp.get_clients = function() return { client } end
  vim.ui.select = function(items, opts, on_choice)
    selected_items, selected_opts = items, opts
    on_choice(items[2])
  end
  vim.lsp.util.show_document = function(location)
    opened = location
    return true
  end

  assert_equal(definition.goto_lsp_definition_with_implementations(), true, "definition request starts")
  assert(vim.wait(1000, function() return opened ~= nil end, 10), "implementation picker completes")
  assert_equal(#selected_items, 2, "interface and implementation choices")
  assert_equal(selected_items[1].kind, "interface", "interface choice kind")
  assert_equal(selected_items[2].kind, "implementation", "implementation choice kind")
  assert(selected_opts.format_item(selected_items[1]):find("%[interface%]"), "interface picker label")
  assert(selected_opts.format_item(selected_items[2]):find("%[implementation%]"), "implementation picker label")
  assert_equal(opened.uri, implementation_location.uri, "selected implementation opens")

  selected_items, selected_opts, opened, requested = nil, nil, nil, {}
  client.definition_result = implementation_location
  assert_equal(definition.goto_lsp_definition_with_implementations(), true, "class definition request starts")
  assert(vim.wait(1000, function() return opened ~= nil end, 10), "class definition opens")
  assert_equal(selected_items, nil, "class definition skips picker")
  assert_equal(requested, { "textDocument/definition" }, "class definition skips implementation request")

  vim.lsp.get_clients = original_get_clients
  vim.ui.select = original_select
  vim.lsp.util.show_document = original_show_document
  vim.cmd("enew")
  vim.fn.delete(root, "rf")
end

return M

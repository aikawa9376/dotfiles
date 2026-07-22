local M = {}

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function location(path, lines, line_number, needle, init)
  local start = assert(lines[line_number + 1]:find(needle, init or 1, true), "test needle not found") - 1
  return {
    uri = vim.uri_from_fname(path),
    range = {
      start = { line = line_number, character = start },
      ["end"] = { line = line_number, character = start + #needle },
    },
  }
end

function M.run()
  local definition = require("laravel_extension.features.definition")
  local root = vim.fn.tempname() .. "-laravel-definition"
  vim.fn.mkdir(root, "p")
  vim.fn.writefile({ "#!/usr/bin/env php" }, root .. "/artisan")

  local source_path = root .. "/Consumer.php"
  local interface_path = root .. "/Repository.php"
  local implementation_path = root .. "/DatabaseRepository.php"
  local abstract_path = root .. "/BaseService.php"
  local child_path = root .. "/ConcreteService.php"
  local regular_path = root .. "/RegularService.php"
  local source_lines = { "<?php", "$repository->find(1);" }
  local interface_lines = {
    "<?php",
    "interface Repository {",
    "    public function find(int $id): object;",
    "}",
  }
  local implementation_lines = {
    "<?php",
    "final class DatabaseRepository implements Repository {",
    "    public function find(int $id): object {}",
    "}",
  }
  local abstract_lines = {
    "<?php",
    "abstract class BaseService {",
    "    abstract public function execute(): void;",
    "}",
  }
  local child_lines = {
    "<?php",
    "final class ConcreteService extends BaseService {",
    "    public function execute(): void {}",
    "}",
  }
  local regular_lines = {
    "<?php",
    "final class RegularService {",
    "    public function execute(): void {}",
    "}",
  }
  vim.fn.writefile(source_lines, source_path)
  vim.fn.writefile(interface_lines, interface_path)
  vim.fn.writefile(implementation_lines, implementation_path)
  vim.fn.writefile(abstract_lines, abstract_path)
  vim.fn.writefile(child_lines, child_path)
  vim.fn.writefile(regular_lines, regular_path)

  vim.cmd("edit " .. vim.fn.fnameescape(source_path))
  vim.bo.filetype = "php"
  local interface_definition = location(interface_path, interface_lines, 2, "find")
  local interface_reference = location(implementation_path, implementation_lines, 1, "Repository", 30)
  local unrelated_reference = location(source_path, source_lines, 1, "find")
  local abstract_definition = location(abstract_path, abstract_lines, 2, "execute")
  local abstract_reference = location(child_path, child_lines, 1, "BaseService")
  local regular_definition = location(regular_path, regular_lines, 2, "execute")
  assert_equal(definition.is_interface_location({ location = interface_definition }), true, "interface method location")

  local original_get_clients = vim.lsp.get_clients
  local original_show_document = vim.lsp.util.show_document
  local original_picker = definition.pick_locations
  ---@type table[]?
  local selected_items
  ---@type table?
  local selected_opts
  ---@type table?
  local opened
  local requested = {}
  local client = {
    offset_encoding = "utf-16",
    definition_result = interface_definition,
    reference_result = { interface_reference, unrelated_reference },
  }
  function client:supports_method(method)
    return method == "textDocument/definition" or method == "textDocument/references"
  end
  function client:request(method, params, callback)
    requested[#requested + 1] = { method = method, params = params }
    callback(nil, method == "textDocument/definition" and self.definition_result or self.reference_result)
    return true
  end

  ---@diagnostic disable-next-line: duplicate-set-field
  vim.lsp.get_clients = function() return { client } end
  definition.pick_locations = function(items, opts)
    selected_items, selected_opts = items, opts
  end
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.lsp.util.show_document = function(target)
    opened = target
    return true
  end

  assert_equal(definition.goto_lsp_definition_with_implementations(), true, "definition request starts")
  assert(vim.wait(1000, function() return selected_items ~= nil end, 10), "interface implementation picker completes")
  assert(selected_items and selected_opts, "interface picker state")
  assert_equal(#selected_items, 2, "interface and implementation choices")
  assert_equal(selected_items[1].kind, "interface", "interface choice kind")
  assert_equal(selected_items[2].kind, "implementation", "implementation choice kind")
  assert_equal(selected_opts.cwd, root, "definition picker uses Laravel project root")
  assert(selected_opts.prompt:find("interface"), "interface picker prompt")
  assert_equal(selected_items[2].location.uri, vim.uri_from_fname(implementation_path), "implementation class location")
  assert_equal(selected_items[2].location.range.start.line, 1, "implementation points at class declaration")
  assert_equal(vim.tbl_map(function(request) return request.method end, requested), {
    "textDocument/definition",
    "textDocument/references",
  }, "interface uses free references request")
  assert_equal(requested[2].params.textDocument.uri, vim.uri_from_fname(interface_path), "references target interface file")
  assert_equal(requested[2].params.context.includeDeclaration, false, "references exclude target declaration")

  selected_items, selected_opts, opened, requested = nil, nil, nil, {}
  client.definition_result = abstract_definition
  client.reference_result = { abstract_reference }
  assert_equal(definition.goto_lsp_definition_with_implementations(), true, "abstract definition request starts")
  assert(vim.wait(1000, function() return selected_items ~= nil end, 10), "abstract implementation picker completes")
  assert(selected_items and selected_opts, "abstract picker state")
  assert_equal(#selected_items, 2, "abstract and subclass choices")
  assert_equal(selected_items[1].kind, "abstract", "abstract choice kind")
  assert_equal(selected_items[2].kind, "implementation", "subclass choice kind")
  assert(selected_opts.prompt:find("abstract class"), "abstract picker prompt")
  assert_equal(selected_items[2].location.uri, vim.uri_from_fname(child_path), "subclass location")
  assert_equal(vim.tbl_map(function(request) return request.method end, requested), {
    "textDocument/definition",
    "textDocument/references",
  }, "abstract class uses references request")

  selected_items, selected_opts, opened, requested = nil, nil, nil, {}
  client.definition_result = regular_definition
  client.reference_result = {}
  assert_equal(definition.goto_lsp_definition_with_implementations(), true, "regular definition request starts")
  assert(vim.wait(1000, function() return opened ~= nil end, 10), "regular class definition opens")
  assert_equal(selected_items, nil, "regular class skips picker")
  assert_equal(vim.tbl_map(function(request) return request.method end, requested), {
    "textDocument/definition",
  }, "regular class skips references request")

  vim.lsp.get_clients = original_get_clients
  vim.lsp.util.show_document = original_show_document
  definition.pick_locations = original_picker
  vim.cmd("enew")
  vim.fn.delete(root, "rf")
end

return M

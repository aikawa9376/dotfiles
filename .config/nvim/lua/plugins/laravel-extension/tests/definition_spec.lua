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

local function item_for_path(items, path)
  local uri = vim.uri_from_fname(path)
  return vim.iter(items or {}):find(function(item) return item.location and item.location.uri == uri end)
end

function M.run()
  local definition = require("laravel_extension.features.definition")
  local root = vim.fn.tempname() .. "-laravel-definition"
  vim.fn.mkdir(root, "p")
  vim.fn.writefile({ "#!/usr/bin/env php" }, root .. "/artisan")

  local source_path = root .. "/Consumer.php"
  local interface_path = root .. "/Repository.php"
  local implementation_path = root .. "/DatabaseRepository.php"
  local aliased_path = root .. "/CachedRepository.php"
  local abstract_path = root .. "/BaseService.php"
  local child_path = root .. "/ConcreteService.php"
  local regular_path = root .. "/RegularService.php"
  local source_lines = { "<?php", "$repository->find(1);" }
  local interface_lines = {
    "<?php",
    "namespace App\\Contracts;",
    "interface Repository {",
    "    public function find(int $id): object;",
    "}",
  }
  local implementation_lines = {
    "<?php",
    "namespace App\\Repositories;",
    "use App\\Contracts\\Repository;",
    "final class DatabaseRepository implements Repository {",
    "    public function find(int $id): object {}",
    "}",
  }
  local aliased_lines = {
    "<?php",
    "namespace App\\Repositories;",
    "use App\\Contracts\\Repository as Repo;",
    "final class CachedRepository implements Repo {",
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
  vim.fn.writefile(aliased_lines, aliased_path)
  vim.fn.writefile(abstract_lines, abstract_path)
  vim.fn.writefile(child_lines, child_path)
  vim.fn.writefile(regular_lines, regular_path)

  vim.cmd("edit " .. vim.fn.fnameescape(source_path))
  vim.bo.filetype = "php"
  local interface_definition = location(interface_path, interface_lines, 3, "find")
  local abstract_definition = location(abstract_path, abstract_lines, 2, "execute")
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
  }
  function client:supports_method(method)
    return method == "textDocument/definition"
  end
  function client:request(method, params, callback)
    requested[#requested + 1] = { method = method, params = params }
    callback(nil, self.definition_result)
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
  assert_equal(#selected_items, 3, "interface and direct or aliased implementation choices")
  assert_equal(selected_items[1].kind, "interface", "interface choice kind")
  assert_equal(selected_opts.cwd, root, "definition picker uses Laravel project root")
  assert(selected_opts.prompt:find("interface"), "interface picker prompt")
  local implementation = assert(item_for_path(selected_items, implementation_path), "direct implementation found")
  local aliased = assert(item_for_path(selected_items, aliased_path), "aliased implementation found")
  assert_equal(implementation.kind, "implementation", "implementation choice kind")
  assert_equal(implementation.location.range.start.line, 4, "implementation points at method declaration")
  assert_equal(aliased.location.range.start.line, 4, "aliased implementation points at method declaration")
  assert_equal(vim.tbl_map(function(request) return request.method end, requested), {
    "textDocument/definition",
  }, "interface implementation scan avoids LSP references")

  selected_items, selected_opts, opened, requested = nil, nil, nil, {}
  client.definition_result = abstract_definition
  assert_equal(definition.goto_lsp_definition_with_implementations(), true, "abstract definition request starts")
  assert(vim.wait(1000, function() return selected_items ~= nil end, 10), "abstract implementation picker completes")
  assert(selected_items and selected_opts, "abstract picker state")
  assert_equal(#selected_items, 2, "abstract and subclass choices")
  assert_equal(selected_items[1].kind, "abstract", "abstract choice kind")
  assert_equal(selected_items[2].kind, "implementation", "subclass choice kind")
  assert(selected_opts.prompt:find("abstract class"), "abstract picker prompt")
  local subclass = assert(item_for_path(selected_items, child_path), "subclass found")
  assert_equal(subclass.location.range.start.line, 2, "subclass points at method declaration")
  assert_equal(vim.tbl_map(function(request) return request.method end, requested), {
    "textDocument/definition",
  }, "abstract implementation scan avoids LSP references")

  selected_items, selected_opts, opened, requested = nil, nil, nil, {}
  client.definition_result = regular_definition
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

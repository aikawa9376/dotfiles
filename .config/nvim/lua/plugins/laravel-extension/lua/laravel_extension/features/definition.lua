local utils = require("laravel_extension.utils")

local M = {}

local function normalize_location(location)
  if type(location) ~= "table" then return nil end
  local uri = location.uri or location.targetUri
  local range = location.range or location.targetSelectionRange or location.targetRange
  if not uri or type(range) ~= "table" or type(range.start) ~= "table" then return nil end
  return { uri = uri, range = range }
end

local function location_key(location)
  local start = location.range.start
  return table.concat({ location.uri, start.line or 0, start.character or 0 }, ":")
end

local function append_locations(target, seen, result, encoding)
  if type(result) ~= "table" then return end
  local locations = (result.uri or result.targetUri) and { result } or result
  for _, raw in ipairs(locations) do
    local location = normalize_location(raw)
    if location then
      local key = location_key(location)
      if not seen[key] then
        seen[key] = true
        target[#target + 1] = { location = location, encoding = encoding or "utf-16" }
      end
    end
  end
end

local function supporting_clients(bufnr, method)
  local clients = {}
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    local ok, supported = pcall(client.supports_method, client, method, bufnr)
    if ok and supported then clients[#clients + 1] = client end
  end
  return clients
end

local function request_locations_with_params(bufnr, method, make_params, callback)
  local clients = supporting_clients(bufnr, method)
  if #clients == 0 then return false end

  local pending = #clients
  local locations, seen = {}, {}
  local function complete_one()
    pending = pending - 1
    if pending == 0 then callback(locations) end
  end

  for _, client in ipairs(clients) do
    local encoding = client.offset_encoding or "utf-16"
    local params = make_params(client, encoding)
    local ok, accepted = pcall(client.request, client, method, params, function(err, result)
      if not err then append_locations(locations, seen, result, encoding) end
      complete_one()
    end, bufnr)
    if not ok or accepted == false then complete_one() end
  end
  return true
end

local function request_locations(bufnr, winid, method, callback)
  return request_locations_with_params(bufnr, method, function(_, encoding)
    return vim.lsp.util.make_position_params(winid, encoding)
  end, callback)
end

local function location_buffer(item)
  local path = vim.uri_to_fname(item.location.uri)
  local bufnr = vim.fn.bufnr(path)
  if bufnr < 0 then bufnr = vim.fn.bufadd(path) end
  if bufnr >= 0 and not vim.api.nvim_buf_is_loaded(bufnr) then pcall(vim.fn.bufload, bufnr) end
  return bufnr, path
end

local function parsed_node_at(bufnr, row, col)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "php")
  if not ok or type(parser) ~= "table" or type(parser.parse) ~= "function" then return nil end
  local parsed, trees = pcall(parser.parse, parser)
  if not parsed or type(trees) ~= "table" then return nil end
  local root = trees[1] and trees[1]:root() or nil
  return root and root:named_descendant_for_range(row, col, row, col) or nil
end

local function interface_node_at(bufnr, row, col)
  local node = parsed_node_at(bufnr, row, col)
  while node do
    if node:type() == "interface_declaration" then return true end
    node = node:parent()
  end
  return false
end

local function node_location(uri, node)
  local start_row, start_col, end_row, end_col = node:range()
  return {
    uri = uri,
    range = {
      start = { line = start_row, character = start_col },
      ["end"] = { line = end_row, character = end_col },
    },
  }
end

local function declaration_name_node(node)
  local names = node and node:field("name") or {}
  return names and names[1] or nil
end

local function is_abstract_class(node)
  if not node or node:type() ~= "class_declaration" then return false end
  for child in node:iter_children() do
    if child:type() == "abstract_modifier" then return true end
  end
  return false
end

local function node_name(node, source)
  local name = declaration_name_node(node)
  return name and vim.treesitter.get_node_text(name, source) or nil, name
end

local function php_namespace(source)
  return source:match("%f[%a]namespace%s+([%w_\\]+)%s*[;{]") or ""
end

local function implementation_target(item)
  if not item or not item.location then return nil end
  local bufnr = location_buffer(item)
  if not bufnr or bufnr < 0 or not vim.api.nvim_buf_is_loaded(bufnr) then return nil end
  local start = item.location.range.start
  local node = parsed_node_at(bufnr, tonumber(start.line) or 0, tonumber(start.character) or 0)
  local source = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  local member_name
  while node do
    local node_type = node:type()
    if node_type == "method_declaration" and not member_name then
      member_name = node_name(node, bufnr)
    end
    local kind = node_type == "interface_declaration" and "interface"
      or (is_abstract_class(node) and "abstract")
      or nil
    if kind then
      local name = declaration_name_node(node)
      if not name then return nil end
      local type_name = vim.treesitter.get_node_text(name, bufnr)
      local namespace = php_namespace(source)
      return {
        kind = kind,
        location = node_location(item.location.uri, name),
        type_name = type_name,
        fqcn = namespace ~= "" and (namespace .. "\\" .. type_name) or type_name,
        member_name = member_name,
      }
    end
    if node_type == "class_declaration" then return nil end
    node = node:parent()
  end
  return nil
end

local function php_aliases(source)
  local aliases = {}
  for imported, alias in source:gmatch("%f[%a]use%s+([%w_\\]+)%s+as%s+([%w_]+)%s*;") do
    aliases[alias:lower()] = imported:gsub("^\\", "")
  end
  for imported in source:gmatch("%f[%a]use%s+([%w_\\]+)%s*;") do
    local alias = imported:match("([^\\]+)$")
    if alias then aliases[alias:lower()] = imported:gsub("^\\", "") end
  end
  return aliases
end

local function resolve_type_name(name, namespace, aliases)
  name = tostring(name or ""):gsub("%s+", "")
  local absolute = name:sub(1, 1) == "\\"
  name = name:gsub("^\\", "")
  if absolute then return name end
  local first, rest = name:match("^([^\\]+)\\(.+)$")
  local imported = aliases[(first or name):lower()]
  if imported then return rest and (imported .. "\\" .. rest) or imported end
  return namespace ~= "" and (namespace .. "\\" .. name) or name
end

local function class_implements_target(node, source, target, namespace, aliases)
  for child in node:iter_children() do
    if child:type() == "base_clause" or child:type() == "class_interface_clause" then
      for relation in child:iter_children() do
        if relation:named() then
          local resolved = resolve_type_name(vim.treesitter.get_node_text(relation, source), namespace, aliases)
          if resolved:lower() == target.fqcn:lower() then return true end
        end
      end
    end
  end
  return false
end

local function implementation_name_node(class, source, member_name)
  if member_name then
    local bodies = class:field("body")
    local body = bodies and bodies[1] or nil
    if body then
      for child in body:iter_children() do
        if child:type() == "method_declaration" then
          local name, name_node = node_name(child, source)
          if name and name:lower() == member_name:lower() then return name_node end
        end
      end
    end
  end
  return declaration_name_node(class)
end

local function implementations_in_source(path, source, target)
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, "php")
  if not ok or not parser then return {} end
  local parsed, trees = pcall(parser.parse, parser)
  local root = parsed and trees and trees[1] and trees[1]:root() or nil
  if not root then return {} end

  local namespace = php_namespace(source)
  local aliases = php_aliases(source)
  local uri = vim.uri_from_fname(path)
  local items = {}
  local function visit(node)
    if node:type() == "class_declaration" and class_implements_target(node, source, target, namespace, aliases) then
      local name = implementation_name_node(node, source, target.member_name)
      if name then
        items[#items + 1] = { location = node_location(uri, name), encoding = "utf-8", kind = "implementation" }
      end
      return
    end
    for child in node:iter_children() do
      if child:named() then visit(child) end
    end
  end
  visit(root)
  return items
end

local function regex_escape(text)
  return tostring(text or ""):gsub("([\\%^%$%.|%?%*%+%(%)%[%]{}])", "\\%1")
end

local function find_implementations(root, target, callback)
  local type_name = regex_escape(target.type_name)
  local pattern = "(?s)(?:\\b(?:implements|extends)\\b[^{;]*\\b"
    .. type_name
    .. "\\b|\\buse\\s+[^;]*\\b"
    .. type_name
    .. "\\b[^;]*;)"
  vim.system({
    "rg",
    "--files-with-matches",
    "--multiline",
    "--pcre2",
    "--glob",
    "*.php",
    "--glob",
    "!vendor/**",
    "--glob",
    "!storage/**",
    "--",
    pattern,
    root,
  }, { text = true }, function(result)
    local paths = vim.split(tostring(result.stdout or ""), "\n", { trimempty = true })
    local items, seen, index = {}, {}, 1
    local function process_batch()
      local last = math.min(#paths, index + 24)
      for position = index, last do
        local path = paths[position]
        local ok, lines = pcall(vim.fn.readfile, path)
        if ok then
          for _, item in ipairs(implementations_in_source(path, table.concat(lines, "\n"), target)) do
            local key = location_key(item.location)
            if not seen[key] then
              seen[key] = true
              items[#items + 1] = item
            end
          end
        end
      end
      index = last + 1
      if index <= #paths then
        vim.schedule(process_batch)
      else
        callback(items)
      end
    end
    vim.schedule(process_batch)
  end)
end

local function interface_text_at(bufnr, row)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, row + 1, false)
  local declaration
  for _, line in ipairs(lines) do
    local kind = line:match("%f[%a](interface)%f[%A]")
      or line:match("%f[%a](class)%f[%A]")
      or line:match("%f[%a](trait)%f[%A]")
      or line:match("%f[%a](enum)%f[%A]")
    if kind then declaration = kind end
  end
  return declaration == "interface"
end

function M.is_interface_location(item)
  if not item or not item.location then return false end
  local bufnr = location_buffer(item)
  if not bufnr or bufnr < 0 or not vim.api.nvim_buf_is_loaded(bufnr) then return false end
  local start = item.location.range.start
  local row, col = tonumber(start.line) or 0, tonumber(start.character) or 0
  return interface_node_at(bufnr, row, col) or interface_text_at(bufnr, row)
end

local function open_location(item)
  vim.lsp.util.show_document(item.location, item.encoding or "utf-16", { focus = true })
end

function M.pick_locations(items, opts)
  require("laravel_extension.fzf_picker").select(items, opts)
end

local function choose_locations(definitions, implementations, target_kind, cwd)
  implementations = implementations or {}
  local definition_keys = {}
  for _, item in ipairs(definitions) do definition_keys[location_key(item.location)] = true end
  implementations = vim.tbl_filter(function(item)
    return not definition_keys[location_key(item.location)]
  end, implementations)
  if #implementations == 0 and #definitions == 1 then
    open_location(definitions[1])
    return
  end

  local items = {}
  for _, item in ipairs(definitions) do
    item.kind = target_kind or (M.is_interface_location(item) and "interface" or "definition")
    items[#items + 1] = item
  end
  for _, item in ipairs(implementations) do
    item.kind = "implementation"
    items[#items + 1] = item
  end
  M.pick_locations(items, {
    cwd = cwd,
    prompt = #implementations > 0
        and string.format("Select %s or implementation:", target_kind == "abstract" and "abstract class" or "interface")
      or "Select definition:",
  })
end

function M.goto_lsp_definition_with_implementations()
  local bufnr = vim.api.nvim_get_current_buf()
  local winid = vim.api.nvim_get_current_win()
  local cwd = utils.project_root(bufnr) or vim.fn.getcwd()
  return request_locations(bufnr, winid, "textDocument/definition", function(definitions)
    vim.schedule(function()
      if #definitions == 0 then
        vim.notify("No LSP definition available", vim.log.levels.WARN)
        return
      end
      local target
      for _, definition in ipairs(definitions) do
        target = implementation_target(definition)
        if target then break end
      end
      if not target then
        choose_locations(definitions, nil, nil, cwd)
        return
      end
      find_implementations(cwd, target, function(implementations)
        choose_locations(definitions, implementations, target.kind, cwd)
      end)
    end)
  end)
end

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

  if M.goto_lsp_definition_with_implementations() then return true end

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

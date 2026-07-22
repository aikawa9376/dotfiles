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

local function implementation_target(item)
  if not item or not item.location then return nil end
  local bufnr = location_buffer(item)
  if not bufnr or bufnr < 0 or not vim.api.nvim_buf_is_loaded(bufnr) then return nil end
  local start = item.location.range.start
  local node = parsed_node_at(bufnr, tonumber(start.line) or 0, tonumber(start.character) or 0)
  while node do
    local node_type = node:type()
    local kind = node_type == "interface_declaration" and "interface"
      or (is_abstract_class(node) and "abstract")
      or nil
    if kind then
      local name = declaration_name_node(node)
      if not name then return nil end
      return { kind = kind, location = node_location(item.location.uri, name) }
    end
    if node_type == "class_declaration" then return nil end
    node = node:parent()
  end
  return nil
end

local function implementation_class(item)
  if not item or not item.location then return nil end
  local bufnr = location_buffer(item)
  if not bufnr or bufnr < 0 or not vim.api.nvim_buf_is_loaded(bufnr) then return nil end
  local start = item.location.range.start
  local node = parsed_node_at(bufnr, tonumber(start.line) or 0, tonumber(start.character) or 0)
  local is_inheritance = false
  while node do
    local node_type = node:type()
    if node_type == "base_clause" or node_type == "class_interface_clause" then
      is_inheritance = true
    elseif node_type == "class_declaration" then
      if not is_inheritance then return nil end
      local name = declaration_name_node(node)
      if not name then return nil end
      return {
        location = node_location(item.location.uri, name),
        encoding = item.encoding,
        kind = "implementation",
      }
    end
    node = node:parent()
  end
  return nil
end

local function implementation_classes(references)
  local classes, seen = {}, {}
  for _, reference in ipairs(references or {}) do
    local class = implementation_class(reference)
    if class then
      local key = location_key(class.location)
      if not seen[key] then
        seen[key] = true
        classes[#classes + 1] = class
      end
    end
  end
  return classes
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
      if not request_locations_with_params(bufnr, "textDocument/references", function()
        return {
          textDocument = { uri = target.location.uri },
          position = vim.deepcopy(target.location.range.start),
          context = { includeDeclaration = false },
        }
      end, function(references)
        vim.schedule(function()
          choose_locations(definitions, implementation_classes(references), target.kind, cwd)
        end)
      end) then
        choose_locations(definitions, nil, target.kind, cwd)
      end
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

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

local function request_locations(bufnr, winid, method, callback)
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
    local params = vim.lsp.util.make_position_params(winid, encoding)
    local ok, accepted = pcall(client.request, client, method, params, function(err, result)
      if not err then append_locations(locations, seen, result, encoding) end
      complete_one()
    end, bufnr)
    if not ok or accepted == false then complete_one() end
  end
  return true
end

local function location_buffer(item)
  local path = vim.uri_to_fname(item.location.uri)
  local bufnr = vim.fn.bufnr(path)
  if bufnr < 0 then bufnr = vim.fn.bufadd(path) end
  if bufnr >= 0 and not vim.api.nvim_buf_is_loaded(bufnr) then pcall(vim.fn.bufload, bufnr) end
  return bufnr, path
end

local function interface_node_at(bufnr, row, col)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "php")
  if not ok or type(parser) ~= "table" or type(parser.parse) ~= "function" then return false end
  local parsed, trees = pcall(parser.parse, parser)
  if not parsed or type(trees) ~= "table" then return false end
  local root = trees[1] and trees[1]:root() or nil
  local node = root and root:named_descendant_for_range(row, col, row, col) or nil
  while node do
    if node:type() == "interface_declaration" then return true end
    node = node:parent()
  end
  return false
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

local function location_label(item)
  local bufnr, path = location_buffer(item)
  local start = item.location.range.start
  local row = (tonumber(start.line) or 0) + 1
  local line = bufnr and vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  line = vim.trim(tostring(line or "")):gsub("%s+", " ")
  if #line > 72 then line = line:sub(1, 69) .. "…" end
  local relative = vim.fn.fnamemodify(path, ":~:.")
  return string.format("[%s] %s:%d%s", item.kind, relative, row, line ~= "" and " · " .. line or "")
end

local function open_location(item)
  vim.lsp.util.show_document(item.location, item.encoding or "utf-16", { focus = true })
end

local function choose_locations(definitions, implementations)
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
    item.kind = M.is_interface_location(item) and "interface" or "definition"
    items[#items + 1] = item
  end
  for _, item in ipairs(implementations) do
    item.kind = "implementation"
    items[#items + 1] = item
  end
  vim.ui.select(items, {
    prompt = #implementations > 0 and "Select interface or implementation:" or "Select definition:",
    kind = "laravel_interface_implementation",
    format_item = location_label,
  }, function(choice)
    if choice then open_location(choice) end
  end)
end

function M.goto_lsp_definition_with_implementations()
  local bufnr = vim.api.nvim_get_current_buf()
  local winid = vim.api.nvim_get_current_win()
  return request_locations(bufnr, winid, "textDocument/definition", function(definitions)
    vim.schedule(function()
      if #definitions == 0 then
        vim.notify("No LSP definition available", vim.log.levels.WARN)
        return
      end
      local has_interface = vim.iter(definitions):any(M.is_interface_location)
      if not has_interface then
        choose_locations(definitions)
        return
      end
      if not request_locations(bufnr, winid, "textDocument/implementation", function(implementations)
        vim.schedule(function() choose_locations(definitions, implementations) end)
      end) then
        choose_locations(definitions)
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

local M = {}

local function trim(text)
  return tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function project_root(bufnr)
  local state = rawget(_G, "laravel_nvim")
  if state and type(state.project_root) == "string" and state.project_root ~= "" then
    return state.project_root
  end

  bufnr = bufnr or 0
  local root = vim.fs.root(bufnr, { "artisan", "composer.json" })
  if root and vim.fn.filereadable(root .. "/artisan") == 1 then
    return root
  end

  return nil
end

local function path_exists(path)
  return type(path) == "string" and vim.fn.filereadable(path) == 1
end

local function open_path(path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
end

local function split(text, sep)
  local parts = {}
  sep = sep or "."
  for part in tostring(text or ""):gmatch("[^" .. vim.pesc(sep) .. "]+") do
    parts[#parts + 1] = part
  end
  return parts
end

local function studly(segment)
  local result = {}
  segment = tostring(segment or ""):gsub("[_%-%s]+", " ")
  for part in segment:gmatch("%S+") do
    result[#result + 1] = part:sub(1, 1):upper() .. part:sub(2)
  end
  return table.concat(result, "")
end

local function kebab(segment)
  return tostring(segment or "")
    :gsub("([%u]+)([%u][%l])", "%1-%2")
    :gsub("([%l%d])([%u])", "%1-%2")
    :gsub("[_%s]+", "-")
    :lower()
end

local function normalize_path(path)
  if type(path) ~= "string" or path == "" then return "" end
  return vim.fn.fnamemodify(path, ":p"):gsub("/$", "")
end

function M.component_name_from_class_path(path, root)
  root = root or project_root(0)
  if not root then return nil end
  root = normalize_path(root)
  path = normalize_path(path)
  local class_root = root ~= "" and (root .. "/app/View/Components/") or ""
  if class_root == "" or path:sub(1, #class_root) ~= class_root or not path:match("%.php$") then
    return nil
  end

  local relative = path:sub(#class_root + 1):gsub("%.php$", "")
  local parts = vim.split(relative, "/", { plain = true, trimempty = true })
  for index, part in ipairs(parts) do
    parts[index] = kebab(part)
  end
  return #parts > 0 and table.concat(parts, ".") or nil
end

local function node_at_cursor(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "php")
  if not ok or not parser then return nil end
  local parsed, trees = pcall(parser.parse, parser)
  if not parsed or not trees or not trees[1] then return nil end
  local cursor = vim.api.nvim_win_get_cursor(0)
  return trees[1]:root():named_descendant_for_range(cursor[1] - 1, cursor[2], cursor[1] - 1, cursor[2])
end

function M.component_class_at_cursor(bufnr, root)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local name = M.component_name_from_class_path(vim.api.nvim_buf_get_name(bufnr), root)
  if not name then return nil end

  local node = node_at_cursor(bufnr)
  if not node or node:type() ~= "name" then return nil end
  local parent = node:parent()
  if not parent or parent:type() ~= "class_declaration" then return nil end
  local class_names = parent:field("name")
  if not class_names or class_names[1] ~= node then return nil end
  return name
end

local function location_key(location)
  local range = location.range or location.targetSelectionRange or location.targetRange
  local uri = location.uri or location.targetUri
  local start = range and range.start or {}
  return table.concat({ uri or "", start.line or 0, start.character or 0 }, ":")
end

local function location_item(location, encoding)
  local uri = location.uri or location.targetUri
  local range = location.range or location.targetSelectionRange or location.targetRange
  if not uri or not range or not range.start then return nil end
  local path = vim.uri_to_fname(uri)
  local row = (tonumber(range.start.line) or 0) + 1
  local col = (tonumber(range.start.character) or 0) + 1
  local line = vim.fn.readfile(path, "", row)[row] or ""
  return {
    kind = "php",
    path = path,
    row = row,
    col = col,
    text = trim(line):gsub("%s+", " "),
    location = { uri = uri, range = range },
    encoding = encoding or "utf-16",
  }
end

local function request_lsp_references(bufnr, winid, callback)
  local clients = vim.tbl_filter(function(client)
    local ok, supported = pcall(client.supports_method, client, "textDocument/references", bufnr)
    return ok and supported
  end, vim.lsp.get_clients({ bufnr = bufnr }))
  if #clients == 0 then
    callback({})
    return
  end

  local pending = #clients
  local items, seen = {}, {}
  local function complete()
    pending = pending - 1
    if pending == 0 then callback(items) end
  end
  for _, client in ipairs(clients) do
    local encoding = client.offset_encoding or "utf-16"
    local params = vim.lsp.util.make_position_params(winid, encoding)
    ---@diagnostic disable-next-line: inject-field
    params.context = { includeDeclaration = true }
    local ok, accepted = pcall(client.request, client, "textDocument/references", params, function(err, result)
      if not err then
        for _, location in ipairs(type(result) == "table" and result or {}) do
          local key = location_key(location)
          if not seen[key] then
            local item = location_item(location, encoding)
            if item then
              seen[key] = true
              items[#items + 1] = item
            end
          end
        end
      end
      complete()
    end, bufnr)
    if not ok or accepted == false then complete() end
  end
end

local function regex_escape(text)
  return tostring(text or ""):gsub("([\\%^%$%.|%?%*%+%(%)%[%]{}])", "\\%1")
end

local function find_blade_references(root, component_name, callback)
  local pattern = "<\\s*/?\\s*x-" .. regex_escape(component_name) .. "(?=[\\s/>])"
  vim.system({
    "rg",
    "--json",
    "--pcre2",
    "--glob",
    "*.blade.php",
    "--glob",
    "!vendor/**",
    pattern,
    root,
  }, { text = true }, function(result)
    local items, seen = {}, {}
    for line in tostring(result.stdout or ""):gmatch("[^\n]+") do
      local ok, event = pcall(vim.json.decode, line)
      ---@type any
      local data = ok and event.type == "match" and event.data or nil
      local path = data and data.path and data.path.text or nil
      local row = data and tonumber(data.line_number) or nil
      if path and row then
        for _, match in ipairs(data.submatches or {}) do
          local col = (tonumber(match.start) or 0) + 1
          local key = table.concat({ path, row, col }, ":")
          if not seen[key] then
            seen[key] = true
            items[#items + 1] = {
              kind = "blade",
              path = path,
              row = row,
              col = col,
              text = trim(data.lines and data.lines.text or ""):gsub("%s+", " "),
            }
          end
        end
      end
    end
    vim.schedule(function() callback(items) end)
  end)
end

local function reference_label(item)
  local path = vim.fn.fnamemodify(item.path, ":~:.")
  local suffix = item.text ~= "" and " · " .. item.text or ""
  return string.format("[%s] %s:%d:%d%s", item.kind, path, item.row, item.col, suffix)
end

local function open_reference(item)
  if item.location then
    vim.lsp.util.show_document(item.location, item.encoding or "utf-16", { focus = true })
    return
  end
  vim.cmd("edit " .. vim.fn.fnameescape(item.path))
  pcall(vim.api.nvim_win_set_cursor, 0, { item.row, math.max(0, item.col - 1) })
end

function M.goto_references_at_cursor(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local root = opts.root or project_root(bufnr)
  local component_name = root and M.component_class_at_cursor(bufnr, root) or nil
  if not component_name then return false end

  local pending = 2
  local lsp_items, blade_items = {}, {}
  local function finish()
    pending = pending - 1
    if pending > 0 then return end
    local items = vim.list_extend(lsp_items, blade_items)
    if #items == 0 then
      vim.notify("No references found for <x-" .. component_name .. ">", vim.log.levels.INFO)
      return
    end
    local select = opts.select or vim.ui.select
    select(items, {
      prompt = "References for <x-" .. component_name .. ">:",
      kind = "laravel_component_references",
      format_item = reference_label,
    }, function(choice)
      if choice then (opts.open or open_reference)(choice) end
    end)
  end

  local request_references = opts.request_lsp_references or request_lsp_references
  request_references(bufnr, vim.api.nvim_get_current_win(), function(items)
    lsp_items = items or {}
    finish()
  end)
  local search_blade = opts.find_blade_references or find_blade_references
  search_blade(root, component_name, function(items)
    blade_items = items or {}
    finish()
  end)
  return true
end

local function normalize_name(name)
  name = trim(name)

  local tag_name = name:match("<%s*/?%s*x%-([%w_%.%-:]+)")
  if tag_name then
    name = tag_name
  end

  name = name:gsub("^x%-", "")
  name = name:match("^([%w_%.%-:]+)") or name
  return trim(name)
end

local function component_parts(name)
  name = normalize_name(name):gsub("/", ".")
  return split(name, ".")
end

local function class_component_path(root, name)
  local parts = component_parts(name)
  if vim.tbl_isempty(parts) then
    return nil
  end

  for index, part in ipairs(parts) do
    parts[index] = studly(part)
  end

  return root .. "/app/View/Components/" .. table.concat(parts, "/") .. ".php"
end

local function view_component_paths(root, name)
  local view_rel = normalize_name(name):gsub("%.", "/")
  return {
    root .. "/resources/views/components/" .. view_rel .. ".blade.php",
    root .. "/resources/views/components/" .. view_rel .. "/index.blade.php",
  }
end

local function vendor_component_paths(root, package, name)
  local view_rel = normalize_name(name):gsub("%.", "/")
  return {
    root .. "/resources/views/vendor/" .. package .. "/" .. view_rel .. ".blade.php",
    root .. "/resources/views/vendor/" .. package .. "/components/" .. view_rel .. ".blade.php",
    root .. "/resources/views/vendor/" .. package .. "/html/" .. view_rel .. ".blade.php",
  }
end

function M.resolve_component(name, root)
  name = normalize_name(name)
  if name == "" then
    return nil
  end

  root = root or project_root(0)
  if not root then
    return nil
  end

  local package, package_component = name:match("^([%w_-]+)::(.+)$")
  local candidates = {}

  if package and package_component then
    candidates = vendor_component_paths(root, package, package_component)
  else
    candidates[#candidates + 1] = class_component_path(root, name)
    vim.list_extend(candidates, view_component_paths(root, name))
  end

  for _, candidate in ipairs(candidates) do
    if path_exists(candidate) then
      return candidate
    end
  end

  return nil, candidates
end

function M.component_at_cursor()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1]
  local col = cursor[2] + 1
  local bufnr = vim.api.nvim_get_current_buf()
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local start_line = math.max(1, row - 5)
  local end_line = math.min(line_count, row + 5)
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)

  local cursor_offset = 0
  for lnum = start_line, row - 1 do
    cursor_offset = cursor_offset + #lines[lnum - start_line + 1] + 1
  end
  cursor_offset = cursor_offset + col

  local text = table.concat(lines, "\n")
  local search_from = 1
  while true do
    local start_pos, end_pos, _, name = text:find("<%s*(/?)%s*x%-([%w_%.%-:]+)", search_from)
    if not start_pos then
      break
    end

    local tag_end = text:find(">", end_pos + 1) or end_pos
    if cursor_offset >= start_pos and cursor_offset <= tag_end then
      return normalize_name(name)
    end

    search_from = end_pos + 1
  end

  return nil
end

function M.find_components(root)
  root = root or project_root(0)
  if not root then
    return {}
  end

  local components = {}
  local seen = {}

  local function add(name, path, kind)
    if not name or name == "" or not path or seen[name .. "\n" .. kind] then
      return
    end

    seen[name .. "\n" .. kind] = true
    components[#components + 1] = {
      name = name,
      path = path,
      kind = kind,
    }
  end

  local function scan_classes(dir, prefix)
    if vim.fn.isdirectory(dir) ~= 1 then
      return
    end

    for _, item in ipairs(vim.fn.readdir(dir) or {}) do
      local path = dir .. "/" .. item
      if vim.fn.isdirectory(path) == 1 then
        scan_classes(path, prefix .. kebab(item) .. ".")
      elseif item:match("%.php$") then
        add(prefix .. kebab(item:gsub("%.php$", "")), path, "class")
      end
    end
  end

  local function scan_views(dir, prefix)
    if vim.fn.isdirectory(dir) ~= 1 then
      return
    end

    for _, item in ipairs(vim.fn.readdir(dir) or {}) do
      local path = dir .. "/" .. item
      if vim.fn.isdirectory(path) == 1 then
        scan_views(path, prefix .. item .. ".")
      elseif item:match("%.blade%.php$") then
        local name = item:gsub("%.blade%.php$", "")
        if name == "index" then
          add(prefix:gsub("%.$", ""), path, "view")
        else
          add(prefix .. name, path, "view")
        end
      end
    end
  end

  scan_classes(root .. "/app/View/Components", "")
  scan_views(root .. "/resources/views/components", "")

  table.sort(components, function(a, b)
    if a.name ~= b.name then
      return a.name < b.name
    end
    return a.kind < b.kind
  end)

  return components
end

function M.goto_component(name, opts)
  opts = opts or {}
  name = normalize_name(name)
  if name == "" then
    if opts.notify ~= false then
      vim.notify("No Laravel component name provided", vim.log.levels.WARN)
    end
    return false
  end

  local path, candidates = M.resolve_component(name)
  if path then
    open_path(path)
    return true
  end

  if opts.notify ~= false then
    local message = "Laravel component not found: " .. name
    if candidates and #candidates > 0 then
      message = message .. "\nTried:\n  " .. table.concat(candidates, "\n  ")
    end
    vim.notify(message, vim.log.levels.WARN)
  end

  return false
end

function M.goto_component_at_cursor(opts)
  local name = M.component_at_cursor()
  if not name then
    return false
  end
  return M.goto_component(name, opts)
end

local function select_component()
  local components = M.find_components()
  if #components == 0 then
    vim.notify("No Laravel components found", vim.log.levels.WARN)
    return
  end

  local items = {}
  local by_label = {}
  for _, component in ipairs(components) do
    local label = component.name .. " (" .. component.kind .. ")"
    items[#items + 1] = label
    by_label[label] = component
  end

  local ok_ui, ui = pcall(require, "laravel.ui")
  local select = ok_ui and ui.select or vim.ui.select
  select(items, {
    prompt = "Select Laravel component:",
    kind = "laravel_component",
  }, function(choice)
    local component = by_label[choice]
    if component then
      open_path(component.path)
    end
  end)
end

local function complete_components(arg_lead)
  local matches = {}
  for _, component in ipairs(M.find_components()) do
    if component.name:find(arg_lead, 1, true) == 1 then
      matches[#matches + 1] = component.name
    end
  end
  return matches
end

function M.setup(group)
  group = group or vim.api.nvim_create_augroup("laravel_extension_component", { clear = true })

  vim.api.nvim_create_user_command("LaravelComponent", function(opts)
    if opts.args ~= "" then
      M.goto_component(opts.args)
      return
    end

    if M.goto_component_at_cursor({ notify = false }) then
      return
    end

    select_component()
  end, {
    nargs = "?",
    complete = complete_components,
    desc = "Navigate to a Laravel Blade component",
  })
end

return M

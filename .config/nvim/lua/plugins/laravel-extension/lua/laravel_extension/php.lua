local I = require("laravel_extension.index")
local S = require("laravel_extension.syntax")
local M = { documents = {} }

function M.document(path, source)
  source = source or I.read(path)
  if not source then return end
  if M.documents[path] and M.documents[path].source == source then return M.documents[path] end
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, "php")
  if not ok then return end
  local parsed, trees = pcall(parser.parse, parser)
  if not parsed or not trees or not trees[1] then return end
  local doc = { path = path, source = source, root = trees[1]:root(), namespace = "", aliases = {} }
  local function walk(node)
    local kind, text = node:type(), vim.treesitter.get_node_text(node, source)
    if kind == "namespace_definition" then
      doc.namespace = text:match("namespace%s+([%w_\\]+)") or ""
    elseif kind == "namespace_use_declaration" then
      local prefix, group = text:match("use%s+([%w_\\]+)\\{(.-)}")
      local body = group or text:gsub("^use%s+", ""):gsub(";%s*$", "")
      if not body:match("^function%s") and not body:match("^const%s") then
        for item in body:gmatch("[^,]+") do
          local fqcn, alias = vim.trim(item):match("^([%w_\\]+)%s+as%s+([%w_]+)$")
          fqcn = fqcn or vim.trim(item)
          fqcn = prefix and (prefix .. "\\" .. fqcn) or fqcn
          alias = alias or fqcn:match("([^\\]+)$")
          if alias then doc.aliases[alias] = fqcn:gsub("^\\", "") end
        end
      end
    elseif kind == "class_declaration" then
      doc.class = node
      local name = node:field("name")[1]
      doc.name = name and vim.treesitter.get_node_text(name, source)
      doc.fqcn = doc.namespace ~= "" and (doc.namespace .. "\\" .. (doc.name or "")) or doc.name
      return
    end
    for child in node:iter_children() do if child:named() then walk(child) end end
  end
  walk(doc.root)
  M.documents[path] = doc
  return doc
end

function M.resolve_name(doc, name)
  if name:sub(1, 1) == "\\" then return name:sub(2) end
  local first, rest = name:match("^([^\\]+)(.*)$")
  if doc.aliases[first] then return doc.aliases[first] .. rest end
  return doc.namespace ~= "" and (doc.namespace .. "\\" .. name) or name
end

function M.class_path(root, fqcn)
  local map = { ["App\\"] = "app/" }
  local config = I.read(root .. "/composer.json")
  if config then
    local ok, json = pcall(vim.json.decode, config)
    if ok then
      for prefix, path in pairs(vim.tbl_get(json, "autoload", "psr-4") or {}) do map[prefix] = path end
    end
  end
  local prefixes = vim.tbl_keys(map)
  table.sort(prefixes, function(a, b) return #a > #b end)
  for _, prefix in ipairs(prefixes) do
    if fqcn:sub(1, #prefix) == prefix then
      for _, base in ipairs(type(map[prefix]) == "table" and map[prefix] or { map[prefix] }) do
        local path = vim.fs.normalize(root .. "/" .. base .. "/" .. fqcn:sub(#prefix + 1):gsub("\\", "/") .. ".php")
        if vim.fn.filereadable(path) == 1 then return path end
      end
    end
  end
end

local function visibility(text)
  return text:match("^%s*private%f[%W]") or text:match("^%s*protected%f[%W]")
    or text:match("%f[%w]private%s+") or text:match("%f[%w]protected%s+")
end

function M.members(path, root, seen)
  seen = seen or {}
  if seen[path] then return {} end
  seen[path] = true
  local doc = M.document(path)
  if not doc or not doc.class then return {} end
  local result, names = {}, {}
  local function add(node, name, kind, detail)
    if names[kind .. name] then return end
    names[kind .. name] = true
    local _, _, byte = node:start()
    local row, col = S.position(doc.source, byte + 1)
    result[#result + 1] = { name = name, kind = kind, path = path, row = row, col = col, detail = detail }
  end
  local body = doc.class:field("body")[1]
  if not body then return result end
  for child in body:iter_children() do
    local text = vim.treesitter.get_node_text(child, doc.source)
    if child:type() == "method_declaration" then
      local name_node = child:field("name")[1]
      local name = name_node and vim.treesitter.get_node_text(name_node, doc.source)
      if name == "__construct" then
        local params = child:field("parameters")[1]
        if params then
          for param in params:iter_children() do
            if param:named() then
              local value = vim.treesitter.get_node_text(param, doc.source)
              local variable = param:field("name")[1]
              local parameter = value:match("%$([%w_]+)")
              if parameter and not visibility(value) then
                add(variable or param, parameter, "prop", value)
                if value:match("%f[%w]public%s+") then add(variable or param, parameter, "property", value) end
              end
            end
          end
        end
      elseif name and not name:match("^__") and not visibility(text:match("^(.-){") or text) then
        add(name_node, name, "method", text:match("^(.-){") or name .. "()")
      end
    elseif child:type() == "property_declaration" and not visibility(text) and not text:match("%f[%w]static%s") then
      for element in child:iter_children() do
        if element:type() == "property_element" then
          local name = element:field("name")[1]
          if name then
            local value = vim.treesitter.get_node_text(name, doc.source):gsub("^%$", "")
            add(name, value, "property", text)
            add(name, value, "prop", text)
          end
        end
      end
    end
  end
  for child in doc.class:iter_children() do
    if child:type() == "base_clause" then
      local parent = vim.treesitter.get_node_text(child, doc.source):match("extends%s+([%w_\\]+)")
      local parent_path = parent and M.class_path(root, M.resolve_name(doc, parent))
      if parent_path then
        for _, member in ipairs(M.members(parent_path, root, seen)) do
          if not names[member.kind .. member.name] then result[#result + 1] = member end
        end
      end
    end
  end
  return result
end

function M.method_at_cursor(root, allow_body)
  local b = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(b)
  if path:sub(1, #(root .. "/app/Http/Controllers/")) ~= root .. "/app/Http/Controllers/" then return end
  local doc = M.document(path)
  if not doc or not doc.class then return end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local node = doc.root:named_descendant_for_range(cursor[1] - 1, cursor[2], cursor[1] - 1, cursor[2])
  local at = node
  while node do
    if node:type() == "method_declaration" then
      local name = node:field("name")[1]
      if name and (allow_body or at == name) then
        return { class = doc.fqcn, method = vim.treesitter.get_node_text(name, doc.source), path = path }
      end
    end
    node = node:parent()
  end
end

return M

local U = require("laravel_extension.utils")
local I = require("laravel_extension.index")
local S = require("laravel_extension.syntax")
local P = require("laravel_extension.php")
local M = {}
local actions = { click = true, submit = true, change = true, input = true, keydown = true,
  keyup = true, blur = true, focus = true, mouseenter = true, mouseleave = true, init = true, poll = true }

function M.component_props(name, root)
  local path = I.resolve("component", name, root)
  if not path then return {} end
  if not path:match("%.blade%.php$") then
    return vim.tbl_filter(function(m) return m.kind == "prop" end, P.members(path, root))
  end
  local text = I.read(path)
  if not text then return {} end
  local tokens, props, seen = S.tokens(text), {}, {}
  for i, token in ipairs(tokens) do
    if token.value == "props" and tokens[i - 1] and tokens[i - 1].value == "@"
        and tokens[i + 2] and tokens[i + 2].value == "[" then
      for _, arg in ipairs(S.args(tokens, i + 2)) do
        local key = tokens[arg[1]]
        if key and key.kind == "string" and not key.dynamic and not seen[key.value]
            and (arg[1] == arg[2] or (tokens[arg[1] + 1] or {}).value == "=>") then
          local row, col = S.position(text, key.start + 1)
          props[#props + 1] = { name = key.value, kind = "prop", path = path, row = row, col = col,
            detail = "@props " .. key.value }
          seen[key.value] = true
        end
      end
    end
  end
  return props
end

function M.livewire_owners(path, root)
  local name = I.view_name(path, root)
  if not name then return {} end
  local owners, seen = {}, {}
  local function add(p)
    if p and p:match("%.php$") and not p:match("%.blade%.php$") and not seen[p] then
      owners[#owners + 1], seen[p] = p, true
    end
  end
  local conventional = name:match("^livewire%.(.+)$")
  if conventional then add(I.resolve("livewire", conventional:gsub("%.index$", ""), root)) end
  for _, base in ipairs({ "app/Livewire", "app/Http/Livewire" }) do
    local dir = root .. "/" .. base
    if vim.fn.isdirectory(dir) == 1 then
      for file, kind in vim.fs.dir(dir, { depth = 20 }) do
        if kind == "file" and file:match("%.php$") then
          local p = dir .. "/" .. file
          local parsed = I.parsed(p)
          for _, ref in ipairs(parsed and parsed.refs or {}) do
            if ref.kind == "view" and I.resolve("view", ref.name, root) == path then add(p) end
          end
        end
      end
    end
  end
  return owners
end

function M.livewire_members(path, root)
  local result, seen = {}, {}
  for _, owner in ipairs(M.livewire_owners(path, root)) do
    for _, member in ipairs(P.members(owner, root)) do
      local key = member.path .. ":" .. member.kind .. ":" .. member.name
      if member.kind ~= "prop" and not seen[key] then result[#result + 1], seen[key] = member, true end
    end
  end
  return result
end

function M.context(text, offset)
  for _, tag in ipairs(S.html_tags(text)) do
    if not tag.closing and offset >= tag.attrs_start and offset <= tag.tag_end then
      for _, attr in ipairs(S.attributes(text, tag)) do
        if attr.value_start and offset >= attr.value_start and offset <= attr.value_end + 1 then
          local before = text:sub(attr.value_start, offset - 1)
          local wire_prefix = before:match("%$wire%.([%w_]*)$")
          if wire_prefix then return { kind = "wire", prefix = wire_prefix, start = offset - #wire_prefix } end
          local wire = attr.name:match("^wire:([%w_]+)")
          local kind = wire == "model" and "property" or (actions[wire] and "method")
          if kind then
            local prefix = before:match("^%s*([%w_]*)$") or before:match("^%s*%$wire%.([%w_]*)$")
            if prefix then return { kind = kind, prefix = prefix, start = offset - #prefix, tag = tag } end
          end
          return nil
        end
      end
      if tag.kind == "component" or tag.kind == "livewire" then
        local before = text:sub(tag.attrs_start, offset - 1)
        local prefix = before:match("[%s:]([%w_%-]*)$")
        if prefix then return { kind = "prop", prefix = prefix, start = offset - #prefix, tag = tag } end
      end
    end
  end
  local before = text:sub(1, offset - 1)
  local prefix = before:match("%$wire%.([%w_]*)$")
  if prefix then return { kind = "wire", prefix = prefix, start = offset - #prefix } end
end

function M.candidates(context, path, root)
  if context.kind == "prop" then
    if context.tag.kind == "component" then return M.component_props(context.tag.name, root) end
    local class = I.resolve("livewire", context.tag.name, root)
    return class and vim.tbl_filter(function(m) return m.kind == "property" end, P.members(class, root)) or {}
  end
  return vim.tbl_filter(function(m) return context.kind == "wire" or m.kind == context.kind end,
    M.livewire_members(path, root))
end

function M.completions(buf, text, offset)
  local root = U.project_root(buf)
  local context = root and M.context(text, offset)
  if not context then return {} end
  local path = vim.api.nvim_buf_get_name(buf)
  local items, seen, existing = {}, {}, {}
  if context.tag then
    for _, attr in ipairs(S.attributes(text, context.tag)) do
      if attr.start < context.start then existing[attr.name:gsub("^:", "")] = true end
    end
  end
  local row, col = S.position(text, context.start)
  local end_row, end_col = S.position(text, offset)
  for _, member in ipairs(M.candidates(context, path, root)) do
    local name = context.kind == "prop" and U.kebab(member.name) or member.name
    if not seen[name] and not existing[name] and name:sub(1, #context.prefix) == context.prefix then
      seen[name] = true
      items[#items + 1] = { label = name, kind = member.kind == "method" and 2 or 10,
        detail = vim.trim(member.detail or ""):gsub("%s+", " "), insertText = name,
        textEdit = { newText = name, range = { start = { line = row - 1, character = col - 1 },
          ["end"] = { line = end_row - 1, character = end_col - 1 } } },
        documentation = { kind = "markdown", value = "`" .. member.path .. ":" .. member.row .. "`" } }
    end
  end
  table.sort(items, function(a, b) return a.label < b.label end)
  return items
end

function M.goto_at_cursor()
  local b, cursor = vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)
  local root = U.project_root(b)
  if not root then return false end
  local path = vim.api.nvim_buf_get_name(b)
  local text = I.read(path)
  if not text then return false end
  local offset = S.offset(text, cursor[1], cursor[2])
  local word_end = offset
  while text:sub(word_end, word_end):match("[%w_%-]") do word_end = word_end + 1 end
  local context = M.context(text, word_end)
  if not context or context.prefix == "" then return false end
  local items = {}
  for _, member in ipairs(M.candidates(context, path, root)) do
    local name = context.kind == "prop" and U.kebab(member.name) or member.name
    if name == context.prefix then items[#items + 1] = member end
  end
  if #items == 0 then return false end
  if #items == 1 then
    U.open_path(items[1].path)
    vim.api.nvim_win_set_cursor(0, { items[1].row, items[1].col - 1 })
  else
    require("laravel_extension.fzf_picker").select(items, { cwd = root, prompt = "Livewire member > " })
  end
  return true
end

return M

local utils = require("laravel_extension.utils")

local M = {}

local function normalize_name(name)
  name = utils.trim(name)

  local tag_name = name:match("<%s*/?%s*livewire:([%w_%.%-:]+)")
  if tag_name then
    name = tag_name
  end

  name = name:gsub("^livewire:", "")
  name = name:match("^([%w_%.%-:]+)") or name
  return utils.trim(name)
end

local function class_path(root, base, name)
  local parts = {}
  for part in normalize_name(name):gsub("/", "."):gmatch("[^%.]+") do
    parts[#parts + 1] = utils.studly(part)
  end

  if vim.tbl_isempty(parts) then
    return nil
  end

  return root .. "/" .. base .. "/" .. table.concat(parts, "/") .. ".php"
end

local function candidate_paths(root, name)
  local view_rel = normalize_name(name):gsub("%.", "/")
  return {
    class_path(root, "app/Livewire", name),
    class_path(root, "app/Http/Livewire", name),
    root .. "/resources/views/livewire/" .. view_rel .. ".blade.php",
    root .. "/resources/views/livewire/" .. view_rel .. "/index.blade.php",
  }
end

function M.resolve_livewire(name, root)
  name = normalize_name(name)
  if name == "" then
    return nil
  end

  root = root or utils.project_root(0)
  if not root then
    return nil
  end

  local candidates = candidate_paths(root, name)
  for _, candidate in ipairs(candidates) do
    if utils.path_exists(candidate) then
      return candidate, candidates
    end
  end

  return nil, candidates
end

local function tag_at_cursor()
  local text, cursor_offset = utils.cursor_context(5)
  local search_from = 1

  while true do
    local start_pos, end_pos, name = text:find("<%s*/?%s*livewire:([%w_%.%-:]+)", search_from)
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

local function directive_at_cursor()
  local text, cursor_offset = utils.cursor_context(5)
  local search_from = 1

  while true do
    local start_pos, args_start = text:find("@livewire%s*%(", search_from)
    if not start_pos then
      break
    end

    local end_pos = text:find("%)", args_start + 1)
    if end_pos and cursor_offset >= start_pos and cursor_offset <= end_pos then
      local args = text:sub(args_start + 1, end_pos - 1)
      return utils.extract_quoted_strings(args)[1]
    end

    search_from = (end_pos or args_start) + 1
  end

  return nil
end

function M.livewire_at_cursor()
  return tag_at_cursor() or directive_at_cursor()
end

function M.find_livewire(root)
  root = root or utils.project_root(0)
  if not root then
    return {}
  end

  local components = {}
  local seen = {}

  local function add(name, path, kind)
    if name == "" or seen[name .. "\n" .. kind] then
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
        scan_classes(path, prefix .. utils.kebab(item) .. ".")
      elseif item:match("%.php$") then
        add(prefix .. utils.kebab(item:gsub("%.php$", "")), path, "class")
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

  scan_classes(root .. "/app/Livewire", "")
  scan_classes(root .. "/app/Http/Livewire", "")
  scan_views(root .. "/resources/views/livewire", "")

  table.sort(components, function(a, b)
    if a.name ~= b.name then
      return a.name < b.name
    end
    return a.kind < b.kind
  end)

  return components
end

function M.goto_livewire(name, opts)
  opts = opts or {}
  name = normalize_name(name)
  if name == "" then
    if opts.notify ~= false then
      vim.notify("No Livewire component name provided", vim.log.levels.WARN)
    end
    return false
  end

  local path, candidates = M.resolve_livewire(name)
  if path then
    utils.open_path(path)
    return true
  end

  if opts.notify ~= false then
    local message = "Livewire component not found: " .. name
    if candidates and #candidates > 0 then
      message = message .. "\nTried:\n  " .. table.concat(candidates, "\n  ")
    end
    vim.notify(message, vim.log.levels.WARN)
  end

  return false
end

function M.goto_livewire_at_cursor(opts)
  local name = M.livewire_at_cursor()
  if not name then
    return false
  end

  return M.goto_livewire(name, opts)
end

local function select_livewire()
  local components = M.find_livewire()
  if #components == 0 then
    vim.notify("No Livewire components found", vim.log.levels.WARN)
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
    prompt = "Select Livewire component:",
    kind = "laravel_livewire_component",
  }, function(choice)
    local component = by_label[choice]
    if component then
      utils.open_path(component.path)
    end
  end)
end

local function complete_livewire(arg_lead)
  local matches = {}
  for _, component in ipairs(M.find_livewire()) do
    if component.name:find(arg_lead, 1, true) == 1 then
      matches[#matches + 1] = component.name
    end
  end
  return matches
end

function M.setup()
  vim.api.nvim_create_user_command("LaravelLivewire", function(opts)
    if opts.args ~= "" then
      M.goto_livewire(opts.args)
      return
    end

    if M.goto_livewire_at_cursor({ notify = false }) then
      return
    end

    select_livewire()
  end, {
    nargs = "?",
    complete = complete_livewire,
    desc = "Navigate to a Laravel Livewire component",
  })
end

return M

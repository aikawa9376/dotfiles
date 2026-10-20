local U = require("laravel_extension.utils")
local S = require("laravel_extension.syntax")
local M = { cache = {} }

function M.read(path)
  local b = vim.fn.bufnr(path)
  if b >= 0 and vim.api.nvim_buf_is_loaded(b) then
    local sep = vim.bo[b].fileformat == "dos" and "\r\n" or "\n"
    local bom = vim.bo[b].bomb and "\239\187\191" or ""
    return bom .. table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), sep) .. (vim.bo[b].endofline and sep or "")
  end
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local text = f:read("*a")
  f:close()
  return text
end

function M.parsed(path, text)
  text = text or M.read(path)
  if not text then return end
  local cached = M.cache[path]
  if not cached or cached.text ~= text then
    cached = { path = path, text = text, refs = S.references(text, { blade = path:match("%.blade%.php$") ~= nil }) }
    if not path:match("%.blade%.php$") then
      cached.refs = vim.tbl_filter(function(r) return not r.tag_start end, cached.refs)
    end
    M.cache[path] = cached
  end
  return cached
end

function M.scan(root, callback)
  local cancelled = false
  local job = vim.system({ "rg", "--files", "--null", "--hidden", "--glob", "*.php", "--glob", "!vendor/**",
    "--glob", "!storage/**", "--glob", "!node_modules/**", "--glob", "!.git/**", "." },
    { text = true, cwd = root }, vim.schedule_wrap(function(result)
      if cancelled then return end
      if result.code ~= 0 and result.code ~= 1 then callback(nil, result.stderr); return end
      local paths, seen = {}, {}
      for relative in (result.stdout or ""):gmatch("[^%z]+") do
        local p = vim.fs.normalize(root .. "/" .. relative)
        paths[#paths + 1], seen[p] = p, true
      end
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        local p = vim.api.nvim_buf_get_name(b)
        if vim.api.nvim_buf_is_loaded(b) and p:sub(1, #root + 1) == root .. "/" and p:match("%.php$")
            and not p:match("/vendor/") and not p:match("/storage/") and not seen[p] then
          paths[#paths + 1], seen[p] = p, true
        end
      end
      table.sort(paths)
      local files, i = {}, 1
      local function batch()
        if cancelled then return end
        local started = vim.uv.hrtime()
        repeat
          local path = paths[i]
          if not path then callback(files); return end
          local parsed = M.parsed(path)
          if not parsed then callback(nil, "Cannot read " .. path); return end
          files[#files + 1], i = parsed, i + 1
        until (vim.uv.hrtime() - started) / 1e6 >= 8
        vim.schedule(batch)
      end
      batch()
    end))
  return function() cancelled = true; pcall(job.kill, job, 15) end
end

function M.view_name(path, root)
  local prefix = root .. "/resources/views/"
  if path:sub(1, #prefix) ~= prefix or not path:match("%.blade%.php$") then return end
  local relative = path:sub(#prefix + 1):gsub("%.blade%.php$", "")
  local vendor, view = relative:match("^vendor/([^/]+)/(.+)$")
  if vendor then return vendor .. "::" .. view:gsub("/", ".") end
  return (relative:gsub("/", "."))
end

function M.file_target(path, root)
  local name = M.view_name(path, root)
  if not name then return end
  local target = { path = path, root = root, name = name, kind = "view", identities = {} }
  target.identities[1] = { kind = "view", name = name }
  local relative = path:sub(#(root .. "/resources/views/") + 1):gsub("%.blade%.php$", "")
  local component = relative:match("^components/(.+)$")
  local livewire = relative:match("^livewire/(.+)$")
  local package, vendor = relative:match("^vendor/([^/]+)/components/(.+)$")
  if component or livewire or vendor then
    local alias = (component or livewire or vendor):gsub("/", ".")
    alias = alias:gsub("%.index$", "")
    alias = package and (package .. "::" .. alias) or alias
    local kind = livewire and "livewire" or "component"
    -- Class-backed tags keep their class name when only the render view moves.
    local class
    if kind == "component" and not package then
      local parts = vim.split(alias, ".", { plain = true })
      for i, part in ipairs(parts) do parts[i] = U.studly(part) end
      class = root .. "/app/View/Components/" .. table.concat(parts, "/") .. ".php"
    elseif livewire then
      local resolved = require("laravel_extension.features.livewire").resolve_livewire(alias, root)
      if resolved and not resolved:match("%.blade%.php$") then class = resolved end
    end
    if not class or not U.path_exists(class) then
      target.identities[#target.identities + 1] = { kind = kind, name = alias }
    end
  end
  return target
end

function M.resolve(kind, name, root)
  if kind == "view" then return U.resolve_view(name, root)
  elseif kind == "component" then return require("laravel_extension.features.component").resolve_component(name, root)
  elseif kind == "livewire" then return require("laravel_extension.features.livewire").resolve_livewire(name, root) end
end

function M.at_cursor(opts)
  opts = opts or {}
  local b = opts.buf or vim.api.nvim_get_current_buf()
  local root = opts.root or U.project_root(b)
  if not root then return end
  local path = vim.api.nvim_buf_get_name(b)
  local file = M.parsed(path, M.read(path))
  if not file then return end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local offset = S.offset(file.text, cursor[1], cursor[2])
  for _, ref in ipairs(file.refs) do
    if offset >= ref.start and offset <= ref.finish then
      local resolved = M.resolve(ref.kind, ref.name, root)
      if resolved then
        local target = M.file_target(resolved, root)
        if target then
          target.identities[#target.identities + 1] = { kind = ref.kind, name = ref.name }
          return target
        end
        return { path = resolved, root = root, kind = ref.kind, name = ref.name,
          identities = { { kind = ref.kind, name = ref.name } } }
      end
    end
  end
  return M.file_target(path, root)
end

function M.matches(ref, target)
  for _, id in ipairs(target.identities) do
    if id.kind == ref.kind and id.name == ref.name then return true end
    if id.kind == "view" and ref.kind == "view" then
      -- Resolve aliases (including namespace overrides) to a file identity.
      local path = M.resolve("view", ref.name, target.root)
      if path == target.path then return true end
    end
  end
  return false
end

function M.item(file, ref)
  local row, col = S.position(file.text, ref.start)
  local line = file.text:sub(ref.start):match("^[^\n]*") or ""
  local line_start = ref.start - col + 1
  line = file.text:sub(line_start):match("^[^\n]*") or line
  return { path = file.path, row = row, col = col, text = vim.trim(line), kind = ref.kind,
    start = ref.start, finish = ref.finish, name = ref.name }
end

function M.references(target, callback)
  return M.scan(target.root, function(files, err)
    if not files then callback(nil, err); return end
    local items = {}
    for _, file in ipairs(files) do
      for _, ref in ipairs(file.refs) do
        if M.matches(ref, target) then items[#items + 1] = M.item(file, ref) end
      end
    end
    callback(items, nil, files)
  end)
end

return M

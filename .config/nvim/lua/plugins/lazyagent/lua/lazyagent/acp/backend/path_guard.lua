local M = {}

local uv = vim.uv or vim.loop

local function normalize(path)
  local value = vim.fs.normalize(tostring(path or "")):gsub("/+$", "")
  return value == "" and "/" or value
end

local function is_absolute(path)
  return tostring(path or ""):sub(1, 1) == "/"
end

local function is_within(path, root)
  if root == "/" then
    return path:sub(1, 1) == "/"
  end
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function canonical_root(path, base)
  local expanded = vim.fn.expand(tostring(path or ""))
  if not is_absolute(expanded) and base then
    expanded = vim.fs.joinpath(base, expanded)
  end
  local absolute = normalize(vim.fn.fnamemodify(expanded, ":p"))
  return uv.fs_realpath(absolute)
end

local function canonical_missing(path)
  local current = normalize(path)
  local suffix = {}

  while current ~= "" do
    local real = uv.fs_realpath(current)
    if real then
      for idx = #suffix, 1, -1 do
        real = vim.fs.joinpath(real, suffix[idx])
      end
      return normalize(real)
    end

    local parent = vim.fs.dirname(current)
    if not parent or parent == current then
      break
    end
    suffix[#suffix + 1] = vim.fs.basename(current)
    current = parent
  end

  return nil
end

function M.new(opts)
  opts = opts or {}
  local cwd = canonical_root(opts.cwd or vim.fn.getcwd())
  if not cwd then
    return nil, "ACP filesystem cwd does not exist"
  end

  local roots = { cwd }
  local additional_directories = type(opts.additional_directories) == "table" and opts.additional_directories or {}
  for _, path in ipairs(additional_directories) do
    local root = canonical_root(path, cwd)
    if root and not vim.tbl_contains(roots, root) then
      roots[#roots + 1] = root
    end
  end

  return setmetatable({
    cwd = cwd,
    roots = roots,
  }, { __index = M })
end

function M:resolve(path, opts)
  opts = opts or {}
  if type(path) ~= "string" or path == "" then
    return nil, "path is required"
  end

  local expanded = vim.fn.expand(path)
  local candidate = normalize(is_absolute(expanded) and expanded or vim.fs.joinpath(self.cwd, expanded))
  local lexical_root
  for _, root in ipairs(self.roots) do
    if is_within(candidate, root) then
      lexical_root = root
      break
    end
  end
  if not lexical_root then
    return nil, "path is outside the ACP filesystem roots: " .. candidate
  end

  local canonical = uv.fs_realpath(candidate)
  if not canonical and opts.allow_missing == true then
    canonical = canonical_missing(candidate)
  end
  if not canonical then
    return nil, "path does not exist: " .. candidate
  end
  canonical = normalize(canonical)

  for _, root in ipairs(self.roots) do
    if is_within(canonical, root) then
      return canonical
    end
  end
  return nil, "path escapes the ACP filesystem roots through a symlink: " .. candidate
end

return M

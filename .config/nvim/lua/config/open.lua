local M = {}

local original_open = rawget(vim.ui, "_dotfiles_original_open") or vim.ui.open
vim.ui["_dotfiles_original_open"] = original_open

local function browser_value()
  return vim.g.nvim_browser or vim.env.NVIM_BROWSER or "vivaldi-stable"
end

local function normalize_command(value)
  if type(value) == "table" then
    local cmd = vim.deepcopy(value)
    return #cmd > 0 and cmd or nil
  end

  if type(value) ~= "string" or value == "" then
    return nil
  end

  return vim.split(value, " ", { plain = true, trimempty = true })
end

local function executable(cmd)
  return type(cmd) == "table" and type(cmd[1]) == "string" and vim.fn.executable(cmd[1]) == 1
end

local function fallback_open(path, opts)
  if original_open then
    return original_open(path, opts)
  end

  if vim.fn.executable("xdg-open") == 1 then
    return vim.system({ "xdg-open", path })
  end

  return nil, "no opener found"
end

function M.is_browser_url(path)
  return type(path) == "string" and path:match("^https?://") ~= nil
end

function M.browser_command()
  local cmd = normalize_command(browser_value())
  if executable(cmd) then
    return cmd
  end
  return nil
end

function M.open(path, opts)
  opts = opts or {}
  if opts.cmd or not M.is_browser_url(path) then
    return fallback_open(path, opts)
  end

  local cmd = M.browser_command()
  if not cmd then
    return fallback_open(path, opts)
  end

  local argv = vim.deepcopy(cmd)
  argv[#argv + 1] = path
  return vim.system(argv)
end

vim.ui.open = M.open

return M

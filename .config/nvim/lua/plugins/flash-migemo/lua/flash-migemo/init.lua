local M = {}

local rmigemo_cache = {}

local function flash_exact(pattern)
  return "\\V" .. pattern:gsub("\\", "\\\\")
end

local function rmigemo_command()
  local local_rmigemo = vim.fn.stdpath("config") .. "/bin/rmigemo"
  if vim.fn.executable(local_rmigemo) == 1 then
    return local_rmigemo
  end
  if vim.fn.executable("rmigemo") == 1 then
    return vim.fn.exepath("rmigemo")
  end
end

local function migemo_pattern(pattern)
  if pattern == "" or not pattern:match("[%w_-]") then
    return flash_exact(pattern)
  end

  local cached = rmigemo_cache[pattern]
  if cached then
    return cached
  end

  local command = rmigemo_command()
  if not command then
    return flash_exact(pattern)
  end

  local result = vim.fn.system({ command, "-q", "-w", pattern, "-e", "vim" })
  if vim.v.shell_error ~= 0 then
    return flash_exact(pattern)
  end

  local normalized = vim.trim(result)
  if normalized == "" then
    return flash_exact(pattern)
  end

  rmigemo_cache[pattern] = normalized
  return normalized
end

function M.setup()
  require("flash.config").search.mode = migemo_pattern
end

return M

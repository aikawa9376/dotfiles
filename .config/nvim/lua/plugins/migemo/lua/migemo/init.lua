local M = {}

local cache = {}

function M.command()
  local local_rmigemo = vim.fn.stdpath("config") .. "/bin/rmigemo"
  if vim.fn.executable(local_rmigemo) == 1 then
    return local_rmigemo
  end
  if vim.fn.executable("rmigemo") == 1 then
    return vim.fn.exepath("rmigemo")
  end
end

--- Convert romaji input to migemo regex pattern.
--- @param input string
--- @param engine string? "vim" (default) | "egrep" | "grep" | "emacs"
--- @return string|nil pattern, or nil if conversion failed
function M.pattern(input, engine)
  if input == "" or not input:match("[%w_-]") then
    return nil
  end
  engine = engine or "vim"
  local key = input .. "\0" .. engine
  if cache[key] then return cache[key] end

  local cmd = M.command()
  if not cmd then return nil end

  local result = vim.fn.system({ cmd, "-q", "-w", input, "-e", engine })
  if vim.v.shell_error ~= 0 then return nil end

  local normalized = vim.trim(result)
  if normalized == "" then return nil end

  cache[key] = normalized
  return normalized
end

local function flash_exact(pattern)
  return "\\V" .. pattern:gsub("\\", "\\\\")
end

--- Setup flash.nvim integration and keymaps.
function M.setup()
  require("flash.config").search.mode = function(pattern)
    return M.pattern(pattern, "vim") or flash_exact(pattern)
  end

  -- <A-m> in / and ? search: convert romaji to migemo pattern, execute, and skip history
  vim.keymap.set("c", "<A-m>", function()
    local cmd_type = vim.fn.getcmdtype()
    if cmd_type ~= "/" and cmd_type ~= "?" then return end
    local input = vim.fn.getcmdline()
    if input == "" then return end
    local result = M.pattern(input, "vim")
    if not result then return end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", true)
    vim.schedule(function()
      vim.cmd((cmd_type == "/" and "/" or "?") .. result)
      vim.fn.histdel("search", -1)
    end)
  end, { silent = true, desc = "Migemo search (no history)" })
end

return M

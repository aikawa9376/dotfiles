local utils = require("laravel_extension.utils")

local M = {}

local view_directives = {
  extends = 1,
  include = 1,
  includeIf = 1,
  includeFirst = 1,
  includeWhen = 2,
  includeUnless = 2,
  each = 1,
  component = 1,
  componentFirst = 1,
}

local function directive_at_cursor()
  local text, cursor_offset = utils.cursor_context(5)
  local search_from = 1

  while true do
    local start_pos, args_start, name = text:find("@([%a_][%w_]*)%s*%(", search_from)
    if not start_pos then
      break
    end

    local depth = 1
    local cursor = args_start + 1
    local quote = nil
    local end_pos = nil

    while cursor <= #text do
      local char = text:sub(cursor, cursor)
      if quote then
        if char == "\\" then
          cursor = cursor + 1
        elseif char == quote then
          quote = nil
        end
      elseif char == "'" or char == '"' then
        quote = char
      elseif char == "(" then
        depth = depth + 1
      elseif char == ")" then
        depth = depth - 1
        if depth == 0 then
          end_pos = cursor
          break
        end
      end
      cursor = cursor + 1
    end

    if end_pos and cursor_offset >= start_pos and cursor_offset <= end_pos then
      local arg_index = view_directives[name]
      if arg_index then
        local args = text:sub(args_start + 1, end_pos - 1)
        local strings = utils.extract_quoted_strings(args)
        return strings[arg_index] or strings[1], name
      end
    end

    search_from = math.max((end_pos or args_start) + 1, search_from + 1)
  end

  return nil
end

function M.view_at_cursor()
  return directive_at_cursor()
end

function M.goto_view(name, opts)
  opts = opts or {}
  name = utils.trim(name)
  if name == "" then
    if opts.notify ~= false then
      vim.notify("No Laravel view name provided", vim.log.levels.WARN)
    end
    return false
  end

  local path, candidates = utils.resolve_view(name)
  if path then
    utils.open_path(path)
    return true
  end

  if opts.fallback_to_laravel ~= false then
    local ok, blade = pcall(require, "laravel.blade")
    if ok and type(blade.goto_view) == "function" then
      blade.goto_view(name)
      return true
    end
  end

  if opts.notify ~= false then
    local message = "Laravel view not found: " .. name
    if candidates and #candidates > 0 then
      message = message .. "\nTried:\n  " .. table.concat(candidates, "\n  ")
    end
    vim.notify(message, vim.log.levels.WARN)
  end

  return false
end

function M.goto_view_at_cursor(opts)
  local name = M.view_at_cursor()
  if not name then
    return false
  end

  return M.goto_view(name, opts)
end

function M.setup()
  vim.api.nvim_create_user_command("LaravelBladeView", function(opts)
    if opts.args ~= "" then
      M.goto_view(opts.args)
      return
    end

    if not M.goto_view_at_cursor({ notify = false }) then
      vim.cmd("LaravelView")
    end
  end, {
    nargs = "?",
    desc = "Navigate to a Laravel Blade view",
  })
end

return M

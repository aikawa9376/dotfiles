local utils = require('blink.cmp.sources.cmdline.utils')
local M = {}

local set_commands = { set = true, setlocal = true, setglobal = true }
local excluded = { buffer = true, diff_buffer = true, shellcmd = true, environment = true, tag = true }

local function parse(line)
  -- Let Neovim handle ranges, modifiers, aliases, and command separators. This
  -- parses syntax only; it never executes the command or its completion function.
  for _ = 1, 16 do
    local ok, command = pcall(vim.api.nvim_parse_cmd, line, {})
    if not ok then return end
    if command.nextcmd == '' then return command end
    line = command.nextcmd
  end
end

function M.capture(ctx, completion_type, bufnr)
  local line = ctx.line:sub(1, ctx.pos.col)
  local command = completion_type ~= 'command' and parse(line) or nil
  local is_option = command and set_commands[command.cmd]
  if not is_option and (excluded[completion_type] or utils.is_path_completion(completion_type, line)) then return end
  if completion_type ~= 'command' and not command then return end
  return { line = line, completion_type = completion_type, bufnr = bufnr, command = command and command.cmd }
end

function M.item(context, item)
  return {
    command = context.completion_type == 'command' and item.label or context.command,
    bufnr = context.bufnr,
    context = context,
    label = item.label,
    textEdit = item.textEdit,
  }
end

local function option_info(word)
  local name = word:match('^([%w_]+)')
  if not name then return end
  local ok, info = pcall(vim.api.nvim_get_option_info2, name, {})
  if ok then return info end
  for _, prefix in ipairs({ 'inv', 'no' }) do
    if vim.startswith(name, prefix) then
      ok, info = pcall(vim.api.nvim_get_option_info2, name:sub(#prefix + 1), {})
      if ok and info.type == 'boolean' then return info end
    end
  end
end

function M.resolve(data)
  local context = data.context
  if not context or context.completion_type == 'command' then
    return { kind = 'command', command = data.command, title = ':' .. data.command }
  end
  local edit = data.textEdit
  local range = edit and (edit.insert or edit.range)
  if not range then return end
  local line = context.line:sub(1, range.start.character) .. edit.newText
    .. context.line:sub(range['end'].character + 1)
  local parsed = parse(line)
  if not parsed then return end
  local query = {
    kind = 'argument', command = parsed.cmd, arguments = parsed.args,
    title = ':' .. parsed.cmd .. ' ' .. table.concat(parsed.args, ' '), tags = {},
  }
  local completion_type = context.completion_type
  if set_commands[parsed.cmd] or completion_type == 'option' then
    local info = option_info(parsed.args[#parsed.args] or data.label)
    if not info then return end
    query.kind, query.tags = 'option', { "'" .. info.name .. "'" }
    query.title = "'" .. info.name .. "'"
    query.description = string.format('Type: %s · Short name: %s · Default: %s', info.type, info.shortname, vim.inspect(info.default))
  elseif completion_type == 'help' then
    query.kind, query.tags = 'help', { data.label }
    query.title = ':help ' .. data.label
  elseif completion_type == 'event' then
    query.tags = { data.label:match('([^,]+)$') }
  elseif completion_type == 'highlight' then
    query.tags = { 'hl-' .. data.label }
  elseif completion_type == 'function' or completion_type == 'expression' or completion_type == 'lua' then
    local name = data.label:gsub('%(.*$', ''):gsub('^vim%.fn%.', ''):gsub('^vim%.api%.', '')
    query.tags = { name .. '()', name }
  end
  return query
end

return M

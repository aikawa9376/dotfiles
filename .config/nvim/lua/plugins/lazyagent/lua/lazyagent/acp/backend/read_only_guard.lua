local M = {}

local git_commands = {
  blame = true,
  diff = true,
  ["diff-tree"] = true,
  grep = true,
  ["ls-files"] = true,
  log = true,
  ["merge-base"] = true,
  ["rev-parse"] = true,
  show = true,
  status = true,
}

local read_commands = {
  cat = true,
  git = true,
  head = true,
  ls = true,
  pwd = true,
  rg = true,
  tail = true,
  wc = true,
}

local function basename(command)
  return tostring(command or ""):match("([^/]+)$") or ""
end

local function is_expected_executable(command, name)
  if tostring(command or ""):find("/", 1, true) == nil then return true end
  local uv = vim.uv or vim.loop
  local supplied = uv.fs_realpath(tostring(command))
  local expected_path = vim.fn.exepath(name)
  local expected = expected_path ~= "" and uv.fs_realpath(expected_path) or nil
  return supplied ~= nil and supplied == expected
end

local function reason(session)
  local guards = type(session and session.read_only_guards) == "table" and session.read_only_guards or {}
  local owners = vim.tbl_keys(guards)
  table.sort(owners)
  if #owners == 0 then return nil end
  return tostring(guards[owners[1]] or "the ACP session is read-only")
end

local function git_subcommand(args)
  local index = 1
  while index <= #(args or {}) do
    local value = tostring(args[index])
    if value == "-C" then
      index = index + 2
    elseif value == "--no-pager" then
      index = index + 1
    elseif value:sub(1, 1) == "-" then
      return nil
    else
      return value
    end
  end
  return nil
end

local function unsafe_read_option(command, args)
  for _, raw in ipairs(args or {}) do
    local value = tostring(raw)
    if command == "git" and (value == "--ext-diff" or value == "--output" or value:match("^%-%-output=")) then
      return true
    end
    if command == "git" and (value == "--textconv" or value == "-O" or value == "--open-files-in-pager"
      or value:match("^%-%-open%-files%-in%-pager="))
    then
      return true
    end
    if command == "rg" and (value == "--pre" or value:match("^%-%-pre=")) then
      return true
    end
  end
  return false
end

function M.set(session, owner, enabled, guard_reason)
  if type(session) ~= "table" or type(owner) ~= "string" or owner == "" then
    return nil, "read-only guard requires a session and owner"
  end
  session.read_only_guards = session.read_only_guards or {}
  if enabled == true then
    session.read_only_guards[owner] = tostring(guard_reason or "the ACP session is read-only")
  else
    session.read_only_guards[owner] = nil
  end
  return true
end

function M.reason(session)
  return reason(session)
end

function M.write_error(session)
  local active_reason = reason(session)
  if not active_reason then return nil end
  return { code = -32000, message = "ACP write rejected: " .. active_reason }
end

function M.terminal_error(session, params)
  local active_reason = reason(session)
  if not active_reason then return nil end
  local command = basename(params and params.command)
  local args = params and params.args or {}
  local has_env = type(params and params.env) == "table" and next(params.env) ~= nil
  if read_commands[command] and is_expected_executable(params and params.command, command)
    and not has_env and not unsafe_read_option(command, args)
  then
    if command ~= "git" or git_commands[git_subcommand(args) or ""] then return nil end
  end
  return {
    code = -32000,
    message = string.format(
      "ACP terminal command `%s` rejected: %s; only known read-only commands are allowed",
      command ~= "" and command or "?",
      active_reason
    ),
  }
end

return M

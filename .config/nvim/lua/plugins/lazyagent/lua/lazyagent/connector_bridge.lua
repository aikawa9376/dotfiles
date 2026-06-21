local M = {}

local DEFAULT_TIMEOUT_MS = 30000
local DEFAULT_ROW_LIMIT = 200

local function json_encode(value)
  if vim.json and vim.json.encode then
    return vim.json.encode(value)
  end
  return vim.fn.json_encode(value)
end

local function require_connector()
  local ok_api, api = pcall(require, "connector.api")
  if not ok_api then
    error("connector.nvim is not available: " .. tostring(api))
  end
  return api
end

local function require_connector_module(name)
  local ok, mod = pcall(require, name)
  if not ok then
    error(name .. " is not available: " .. tostring(mod))
  end
  return mod
end

local function current_connection(api, connection_id)
  if connection_id and connection_id ~= "" then
    local conn = api.core.connection_get_params(connection_id)
    if not conn then
      error("connection not found: " .. tostring(connection_id))
    end
    return conn
  end

  local conn = api.core.get_current_connection()
  if not conn then
    error("no active connector.nvim connection selected")
  end
  return conn
end

local function public_connection(conn)
  if not conn then
    return nil
  end
  return {
    id = conn.id,
    name = conn.name,
    type = conn.type,
    database = conn.database,
    source_id = conn.source_id,
  }
end

local function call_is_done(call)
  local state = call and call.state or nil
  return state == "archived" or state == "failed" or state == "canceled"
end

local function wait_for_call(api, call, timeout_ms)
  if not call or not call.id then
    error("connector query did not start")
  end

  local handler = require("connector.api.state").handler()
  local final = handler:get_call(call.id) or call
  local dispose = handler:register_event_listener("call_state_changed", function(updated)
    if updated and updated.id == call.id then
      final = updated
    end
  end)

  timeout_ms = tonumber(timeout_ms) or DEFAULT_TIMEOUT_MS
  local ok = vim.wait(timeout_ms, function()
    final = handler:get_call(call.id) or final
    return call_is_done(final)
  end, 50, false)
  pcall(dispose)

  if not ok then
    pcall(api.core.call_cancel, call.id)
    error("connector query timed out after " .. tostring(timeout_ms) .. "ms")
  end
  if final.state == "failed" then
    error(final.error or "connector query failed")
  end
  if final.state == "canceled" then
    error("connector query was canceled")
  end
  return final
end

local function execute_query(api, opts)
  opts = opts or {}
  local query = vim.trim(opts.sql or opts.query or "")
  if query == "" then
    error("connector " .. tostring(opts.subcommand or "query") .. " requires SQL")
  end

  local util = require_connector_module("connector.util")
  local has_side_effects = util.query_has_side_effects(query)
  if opts.read_only == true and has_side_effects then
    error("refusing mutating SQL in connector query; use connector execute --write to allow it")
  end
  if opts.read_only ~= true and has_side_effects and opts.allow_write ~= true then
    error("refusing mutating SQL without --write/--allow-write")
  end

  local conn = current_connection(api, opts.connection_id)
  local handler = require("connector.api.state").handler()
  local started = handler:begin_connection_execute(conn.id, query)
  local final = wait_for_call(api, started, opts.timeout_ms)
  pcall(function()
    if api.ui and type(api.ui.result_set_call) == "function" then
      api.ui.result_set_call(final)
    end
  end)

  final.connection = public_connection(conn)
  final.side_effects = has_side_effects
  return final
end

local function result_summary(call, row_limit)
  row_limit = tonumber(row_limit) or DEFAULT_ROW_LIMIT
  local result = call and call.result or {}
  local rows = result.rows or {}
  local columns = {}
  for _, column in ipairs(result.columns or {}) do
    columns[#columns + 1] = {
      name = column.name,
      data_type = column.data_type,
      nullable = column.nullable,
      primary_key = column.primary_key,
    }
  end

  local sliced_rows = {}
  for index = 1, math.min(#rows, row_limit) do
    sliced_rows[#sliced_rows + 1] = rows[index]
  end

  return {
    call_id = call.id,
    state = call.state,
    connection = call.connection,
    query = call.query,
    side_effects = call.side_effects == true,
    columns = columns,
    rows = sliced_rows,
    row_count = #(rows or {}),
    returned_rows = #sliced_rows,
    truncated = #rows > #sliced_rows,
    message = result.message,
    completed_at = call.completed_at,
    time_taken_s = call.time_taken_s,
  }
end

local function format_call_stdout(call, opts)
  opts = opts or {}
  local format_name = opts.format or "table"
  local row_limit = tonumber(opts.limit) or DEFAULT_ROW_LIMIT

  if format_name == "json" then
    return json_encode(result_summary(call, row_limit)) .. "\n"
  end

  local format = require_connector_module("connector.format")
  local result = call.result or {}
  if format_name == "csv" then
    return format.to_csv(result, 0, row_limit) .. "\n"
  end
  if format_name == "table" then
    local lines = format.to_table_lines(result, 0, row_limit)
    if #(result.rows or {}) > row_limit then
      lines[#lines + 1] = string.format("... truncated: showing %d of %d rows", row_limit, #(result.rows or {}))
    end
    return table.concat(lines, "\n") .. "\n"
  end

  error("unsupported connector output format: " .. tostring(format_name))
end

local function connections_stdout(api, opts)
  opts = opts or {}
  local current = nil
  pcall(function()
    current = api.core.get_current_connection()
  end)

  local items = {}
  for _, source in ipairs(api.core.get_sources()) do
    local source_id = source:name()
    for _, conn in ipairs(api.core.source_get_connections(source_id) or {}) do
      items[#items + 1] = public_connection(conn)
    end
  end

  if opts.format == "json" then
    return json_encode({
      current = public_connection(current),
      connections = items,
    }) .. "\n"
  end

  local lines = {}
  for _, conn in ipairs(items) do
    local marker = current and conn.id == current.id and "*" or " "
    local parts = {
      marker,
      tostring(conn.id or ""),
      tostring(conn.name or ""),
      tostring(conn.type or ""),
      tostring(conn.database or ""),
    }
    lines[#lines + 1] = table.concat(parts, "\t")
  end
  if #lines == 0 then
    lines[#lines + 1] = "No connector.nvim connections"
  end
  return table.concat(lines, "\n") .. "\n"
end

local function context_stdout(api, opts)
  opts = opts or {}
  local context_api = api.context or require_connector_module("connector.api.context")
  local ctx
  if opts.winid and vim.api.nvim_win_is_valid(tonumber(opts.winid)) then
    ctx = context_api.context_for_window(tonumber(opts.winid), opts)
  else
    ctx = context_api.current_context(opts)
  end

  if opts.format == "json" then
    return json_encode(ctx or {}) .. "\n"
  end
  if not ctx then
    return "No connector.nvim context for current window\n"
  end
  return tostring(ctx.text or context_api.render_markdown(ctx) or "") .. "\n"
end

local function help_stdout()
  return table.concat({
    "Usage:",
    "  nvim-cli-bridge connector context [--json]",
    "  nvim-cli-bridge connector connections [--json]",
    "  nvim-cli-bridge connector query [--format table|json|csv] [--limit N] [--connection ID] SQL",
    "  nvim-cli-bridge connector execute --write [--format table|json|csv] [--limit N] [--connection ID] SQL",
    "",
    "Safety:",
    "  query refuses mutating SQL.",
    "  execute refuses mutating SQL unless --write or --allow-write is present.",
  }, "\n") .. "\n"
end

function M.run(args)
  args = args or {}
  local subcommand = args.subcommand or "help"
  if subcommand == "help" or subcommand == "-h" or subcommand == "--help" then
    return { stdout = help_stdout() }
  end

  local api = require_connector()
  if subcommand == "context" then
    return { stdout = context_stdout(api, args) }
  end
  if subcommand == "connections" then
    return { stdout = connections_stdout(api, args) }
  end
  if subcommand == "query" then
    args.read_only = true
    local call = execute_query(api, args)
    return { stdout = format_call_stdout(call, args) }
  end
  if subcommand == "execute" then
    args.read_only = false
    local call = execute_query(api, args)
    return { stdout = format_call_stdout(call, args) }
  end

  error("unsupported connector subcommand: " .. tostring(subcommand))
end

return M

local M = {}

local uv = vim.uv or vim.loop

local bridge = {
  dir = nil,
  token = nil,
  timer = nil,
  cleanup_registered = false,
}

local function json_encode(value)
  if vim.json and vim.json.encode then
    return vim.json.encode(value)
  end
  return vim.fn.json_encode(value)
end

local function json_decode(value)
  if vim.json and vim.json.decode then
    return vim.json.decode(value)
  end
  return vim.fn.json_decode(value)
end

local function join_path(...)
  local parts = { ... }
  return table.concat(parts, "/"):gsub("/+", "/")
end

local function write_json(path, value)
  local tmp = path .. ".tmp." .. tostring(vim.fn.getpid())
  local ok = pcall(vim.fn.writefile, { json_encode(value) }, tmp)
  if not ok then
    return false
  end
  return os.rename(tmp, path) == true
end

local function die(message, code)
  io.stderr:write(tostring(message or "nvim bridge request failed") .. "\n")
  os.exit(code or 1)
end

local function write_json_or_die(path, value)
  local tmp = path .. ".tmp." .. tostring(vim.fn.getpid())
  local ok, err = pcall(vim.fn.writefile, { json_encode(value) }, tmp)
  if not ok then
    die(err)
  end
  if not os.rename(tmp, path) then
    pcall(vim.fn.delete, tmp)
    die("failed to publish bridge request: " .. path)
  end
end

local function read_json(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil
  end
  local ok_decode, value = pcall(json_decode, table.concat(lines, "\n"))
  if not ok_decode then
    return nil
  end
  return value
end

local function normalize_path(path, cwd)
  path = tostring(path or "")
  if path == "" then
    return path
  end
  if path:sub(1, 1) ~= "/" then
    path = join_path(cwd or vim.fn.getcwd(), path)
  end
  return vim.fn.fnamemodify(path, ":p")
end

local function find_buffer_by_path(path)
  local target = vim.fn.fnamemodify(path, ":p")
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name ~= "" and vim.fn.fnamemodify(name, ":p") == target then
      return bufnr
    end
  end
  return nil
end

local function read_file_lines(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    error("failed to read " .. tostring(path))
  end
  return lines
end

local function read_one(path)
  local bufnr = find_buffer_by_path(path)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end
  return read_file_lines(path)
end

local function scan_files(dir, out)
  local handle = uv.fs_scandir(dir)
  if not handle then
    return
  end
  while true do
    local name, kind = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    local path = join_path(dir, name)
    if kind == "file" then
      out[#out + 1] = path
    elseif kind == "directory" then
      scan_files(path, out)
    end
  end
end

local function command_read(req)
  local path = normalize_path(req.args and req.args.path, req.cwd)
  if vim.fn.filereadable(path) == 1 then
    return { result = { path = path, content = read_one(path) } }
  end
  if vim.fn.isdirectory(path) ~= 1 then
    error("Path does not exist: " .. tostring(path))
  end

  local files = {}
  scan_files(path, files)
  table.sort(files)
  local result = {}
  for _, file in ipairs(files) do
    local ok, lines = pcall(read_one, file)
    if ok then
      result[#result + 1] = { path = file, content = lines }
    end
  end
  return { result = result }
end

local function command_write(req)
  local args = req.args or {}
  local path = normalize_path(args.path, req.cwd)
  local lines = type(args.lines) == "table" and args.lines or {}
  local bufnr = find_buffer_by_path(path)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    local start_line = tonumber(args.start) or 0
    local end_line = tonumber(args["end"]) or -1
    vim.api.nvim_buf_set_lines(bufnr, start_line, end_line, false, lines)
    return { stdout = "Success\n" }
  end

  if args.start ~= nil or args["end"] ~= nil then
    local current = vim.fn.filereadable(path) == 1 and read_file_lines(path) or {}
    local start_line = tonumber(args.start) or 0
    local end_line = tonumber(args["end"])
    if end_line == nil or end_line == -1 then
      end_line = #current
    end

    local next_lines = {}
    for i = 1, start_line do
      if current[i] ~= nil then
        next_lines[#next_lines + 1] = current[i]
      end
    end
    for _, line in ipairs(lines) do
      next_lines[#next_lines + 1] = line
    end
    for i = end_line + 1, #current do
      next_lines[#next_lines + 1] = current[i]
    end
    vim.fn.writefile(next_lines, path)
  else
    vim.fn.writefile(lines, path)
  end
  return { stdout = "Success\n" }
end

local function command_diagnostics(req)
  local args = req.args or {}
  local bufnr = nil
  if args.path and args.path ~= "" then
    local path = normalize_path(args.path, req.cwd)
    bufnr = find_buffer_by_path(path) or vim.fn.bufnr(path)
    if bufnr == -1 then
      bufnr = nil
    end
  end

  local diagnostics = vim.diagnostic.get(bufnr)
  local out = {}
  for _, item in ipairs(diagnostics or {}) do
    out[#out + 1] = {
      bufnr = item.bufnr,
      lnum = item.lnum,
      col = item.col,
      end_lnum = item.end_lnum,
      end_col = item.end_col,
      severity = item.severity,
      source = item.source,
      message = item.message,
      code = item.code,
    }
  end
  return { result = { diagnostics = out } }
end

local function command_cursor()
  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local bufnr = vim.api.nvim_get_current_buf()
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local start_line = math.max(cursor[1] - 5, 0)
  local end_line = math.min(cursor[1] + 5, line_count)
  return {
    result = {
      path = vim.api.nvim_buf_get_name(bufnr),
      line = cursor[1],
      col = cursor[2],
      context_lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line, false),
      start_line = start_line,
      end_line = end_line,
    },
  }
end

local function command_open(req)
  for _, file in ipairs((req.args and req.args.files) or {}) do
    vim.cmd.edit(vim.fn.fnameescape(normalize_path(file, req.cwd)))
  end
  return { stdout = "Success\n" }
end

local function command_close(req)
  for _, file in ipairs((req.args and req.args.files) or {}) do
    local bufnr = find_buffer_by_path(normalize_path(file, req.cwd))
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, {})
    end
  end
  return { stdout = "Success\n" }
end

local function command_qf_add(req)
  local items = {}
  for _, file in ipairs((req.args and req.args.files) or {}) do
    items[#items + 1] = { filename = normalize_path(file, req.cwd), lnum = 1 }
  end
  vim.fn.setqflist(items, "a")
  return { stdout = "Success\n" }
end

local function command_qf_remove(req)
  local remove = {}
  for _, file in ipairs((req.args and req.args.files) or {}) do
    remove[normalize_path(file, req.cwd)] = true
  end

  local next_qf = {}
  for _, item in ipairs(vim.fn.getqflist()) do
    local name = item.filename or vim.fn.bufname(item.bufnr)
    if not remove[normalize_path(name, req.cwd)] then
      next_qf[#next_qf + 1] = item
    end
  end
  vim.fn.setqflist(next_qf, "r")
  return { stdout = "Success\n" }
end

local function command_connector(req)
  return require("lazyagent.connector_bridge").run(req.args or {})
end

local handlers = {
  read = command_read,
  write = command_write,
  diagnostics = command_diagnostics,
  cursor = command_cursor,
  exec = function(req)
    vim.cmd(tostring(req.args and req.args.command or ""))
    return { stdout = "Success\n" }
  end,
  ping = function()
    return { stdout = "Connected\n" }
  end,
  open = command_open,
  close = command_close,
  ["qf-add"] = command_qf_add,
  ["qf-remove"] = command_qf_remove,
  connector = command_connector,
}

local function process_request(path)
  local request_id = vim.fn.fnamemodify(path, ":t:r")
  local response_path = join_path(bridge.dir, "responses", request_id .. ".json")
  local ok_read, lines = pcall(vim.fn.readfile, path)
  if not ok_read then
    return
  end

  local ok_decode, req = pcall(json_decode, table.concat(lines, "\n"))
  if not ok_decode or type(req) ~= "table" then
    write_json(response_path, { ok = false, error = "invalid bridge request" })
    pcall(vim.fn.delete, path)
    return
  end

  local ok, result = pcall(function()
    if req.token ~= bridge.token then
      error("invalid bridge token")
    end
    local handler = handlers[tostring(req.command or "")]
    if not handler then
      error("unsupported nvim-cli command: " .. tostring(req.command))
    end
    return handler(req)
  end)

  if ok then
    result = type(result) == "table" and result or { result = result }
    result.ok = true
    write_json(response_path, result)
  else
    write_json(response_path, { ok = false, error = tostring(result) })
  end
  pcall(vim.fn.delete, path)
end

local function process_requests()
  if not bridge.dir then
    return
  end
  local request_dir = join_path(bridge.dir, "requests")
  local paths = vim.fn.globpath(request_dir, "*.json", false, true)
  table.sort(paths)
  for _, path in ipairs(paths) do
    process_request(path)
  end
end

local function register_cleanup()
  if bridge.cleanup_registered then
    return
  end
  bridge.cleanup_registered = true
  local group = vim.api.nvim_create_augroup("LazyAgentNvimBridge", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      if bridge.timer then
        pcall(function() bridge.timer:stop() end)
        pcall(function() bridge.timer:close() end)
        bridge.timer = nil
      end
      if bridge.dir then
        pcall(vim.fn.delete, bridge.dir, "rf")
      end
    end,
    desc = "Clean lazyagent nvim bridge",
  })
end

function M.ensure_started()
  if bridge.timer and bridge.dir and bridge.token then
    return {
      dir = bridge.dir,
      token = bridge.token,
    }
  end

  local seed = table.concat({
    tostring(vim.fn.getpid()),
    tostring(uv.hrtime()),
    tostring(math.random()),
  }, ":")
  bridge.token = vim.fn.sha256(seed)
  bridge.dir = join_path("/tmp", "lazyagent-nvim-bridge-" .. tostring(vim.fn.getpid()) .. "-" .. bridge.token:sub(1, 10))

  vim.fn.mkdir(join_path(bridge.dir, "requests"), "p", 448)
  vim.fn.mkdir(join_path(bridge.dir, "responses"), "p", 448)
  pcall(vim.fn.setfperm, bridge.dir, "rwx------")
  pcall(vim.fn.setfperm, join_path(bridge.dir, "requests"), "rwx------")
  pcall(vim.fn.setfperm, join_path(bridge.dir, "responses"), "rwx------")

  bridge.timer = uv.new_timer()
  bridge.timer:start(100, 100, vim.schedule_wrap(process_requests))
  register_cleanup()

  return {
    dir = bridge.dir,
    token = bridge.token,
  }
end

function M.inject_env(env)
  env = env or {}
  local info = M.ensure_started()
  env.LAZYAGENT_NVIM_BRIDGE_DIR = info.dir
  env.LAZYAGENT_NVIM_BRIDGE_TOKEN = info.token
  return env
end

local function cli_args(raw)
  local out = {}
  for index = 1, #(raw or {}) do
    local value = raw[index]
    if value ~= "--client" and value ~= "--" then
      out[#out + 1] = value
    end
  end
  return out
end

local function parse_cli_command(args)
  local command = args[1]
  if command == nil or command == "" then
    return nil
  end

  if command == "read" then
    if args[2] == nil or args[3] ~= nil then
      die("read requires a path")
    end
    return command, { path = args[2] }
  end

  if command == "write" then
    local path = args[2]
    if not path then
      die("write requires a path")
    end
    local payload = { path = path, lines = {} }
    local index = 3
    while index <= #args do
      local item = args[index]
      if item == "--start" then
        if args[index + 1] == nil then
          die("write --start requires a value")
        end
        payload.start = tonumber(args[index + 1])
        index = index + 2
      elseif item == "--end" then
        if args[index + 1] == nil then
          die("write --end requires a value")
        end
        payload["end"] = tonumber(args[index + 1])
        index = index + 2
      else
        payload.lines[#payload.lines + 1] = item
        index = index + 1
      end
    end
    return command, payload
  end

  if command == "diagnostics" then
    return command, { path = args[2] }
  end

  if command == "cursor" or command == "ping" then
    return command, {}
  end

  if command == "exec" then
    if args[2] == nil then
      die("exec requires a command")
    end
    return command, { command = table.concat(args, " ", 2) }
  end

  if command == "open" or command == "close" or command == "qf-add" or command == "qf-remove" then
    local files = {}
    for index = 2, #args do
      files[#files + 1] = args[index]
    end
    return command, { files = files }
  end

  if command == "shell" then
    if args[2] == nil then
      die("shell requires a command")
    end
    return command, { command = table.concat(args, " ", 2) }
  end

  if command == "diff" then
    return command, {}
  end

  if command == "connector" then
    local subcommand = args[2] or "help"
    local payload = {
      subcommand = subcommand,
      format = "table",
      sql = "",
    }
    local sql_parts = {}
    local index = 3
    while index <= #args do
      local item = args[index]
      if item == "--format" then
        if args[index + 1] == nil then
          die("connector --format requires a value")
        end
        payload.format = args[index + 1]
        index = index + 2
      elseif item == "--json" then
        payload.format = "json"
        index = index + 1
      elseif item == "--csv" then
        payload.format = "csv"
        index = index + 1
      elseif item == "--table" then
        payload.format = "table"
        index = index + 1
      elseif item == "--limit" or item == "--row-limit" then
        if args[index + 1] == nil then
          die("connector " .. item .. " requires a value")
        end
        payload.limit = tonumber(args[index + 1])
        index = index + 2
      elseif item == "--timeout-ms" then
        if args[index + 1] == nil then
          die("connector --timeout-ms requires a value")
        end
        payload.timeout_ms = tonumber(args[index + 1])
        index = index + 2
      elseif item == "--connection" or item == "--connection-id" then
        if args[index + 1] == nil then
          die("connector " .. item .. " requires a value")
        end
        payload.connection_id = args[index + 1]
        index = index + 2
      elseif item == "--write" or item == "--allow-write" then
        payload.allow_write = true
        index = index + 1
      else
        sql_parts[#sql_parts + 1] = item
        index = index + 1
      end
    end
    payload.sql = table.concat(sql_parts, " ")
    return command, payload
  end

  return nil
end

local function run_shell(command)
  local output = vim.fn.system(command)
  io.write(output or "")
  os.exit(tonumber(vim.v.shell_error) or 0)
end

local function client_request_id()
  return table.concat({
    tostring(vim.fn.getpid()),
    tostring(uv.hrtime()),
    tostring(math.random(1000000, 9999999)),
  }, "-")
end

local function send_client_request(command, payload)
  local bridge_dir = os.getenv("LAZYAGENT_NVIM_BRIDGE_DIR")
  local token = os.getenv("LAZYAGENT_NVIM_BRIDGE_TOKEN")
  if not bridge_dir or bridge_dir == "" or not token or token == "" then
    die("LAZYAGENT_NVIM_BRIDGE_* is not set")
  end

  local id = client_request_id()
  local request_dir = join_path(bridge_dir, "requests")
  local response_dir = join_path(bridge_dir, "responses")
  local request_path = join_path(request_dir, id .. ".json")
  local response_path = join_path(response_dir, id .. ".json")

  vim.fn.mkdir(request_dir, "p")
  vim.fn.mkdir(response_dir, "p")
  write_json_or_die(request_path, {
    id = id,
    token = token,
    command = command,
    args = payload,
    cwd = vim.fn.getcwd(),
  })

  local response = nil
  local timeout_ms = tonumber(os.getenv("LAZYAGENT_NVIM_BRIDGE_TIMEOUT_MS")) or 15000
  vim.wait(timeout_ms, function()
    if vim.fn.filereadable(response_path) ~= 1 then
      return false
    end
    response = read_json(response_path)
    return response ~= nil
  end, 50, false)

  if not response then
    pcall(vim.fn.delete, request_path)
    die("timed out waiting for lazyagent nvim bridge")
  end

  pcall(vim.fn.delete, response_path)
  return response
end

local function print_client_response(response)
  if type(response) ~= "table" or not response.ok then
    die(type(response) == "table" and response.error or "nvim bridge request failed", 1)
  end

  if response.stdout ~= nil then
    io.write(tostring(response.stdout))
  elseif response.result ~= nil then
    io.write(json_encode(response.result) .. "\n")
  end
  os.exit(tonumber(response.exit_code) or 0)
end

function M.run_cli(raw_args)
  local args = cli_args(raw_args)
  local command, payload = parse_cli_command(args)
  if not command then
    die("unsupported nvim-cli-bridge command: " .. tostring(args[1]))
  end

  if command == "shell" then
    run_shell(payload.command)
  elseif command == "diff" then
    run_shell("git diff")
  end

  print_client_response(send_client_request(command, payload))
end

local function should_run_cli()
  if type(arg) ~= "table" then
    return false
  end
  for index = 1, #arg do
    if arg[index] == "--client" then
      return true
    end
  end
  return false
end

if should_run_cli() then
  M.run_cli(arg)
end

return M

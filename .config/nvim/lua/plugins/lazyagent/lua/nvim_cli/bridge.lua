-- nvim-cli receiver and shared command handlers. No LazyAgent dependency.
local M = {}

local uv = vim.uv or vim.loop

local bridge = {
  dir = nil,
  token = nil,
  timer = nil,
  cleanup_registered = false,
  instance_id = nil,
  record_path = nil,
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
  if bufnr and vim.api.nvim_buf_is_loaded(bufnr) then
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end
  return read_file_lines(path)
end

local function terminal_job_for_buf(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local job_id = vim.b[bufnr] and vim.b[bufnr].terminal_job_id or nil
  job_id = tonumber(job_id)
  if job_id and job_id > 0 then
    return job_id
  end
  return nil
end

local function is_terminal_buffer(bufnr)
  return bufnr
    and vim.api.nvim_buf_is_valid(bufnr)
    and (vim.bo[bufnr].buftype == "terminal" or terminal_job_for_buf(bufnr) ~= nil)
end

local function terminal_windows(bufnr)
  local windows = {}
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(winid) then
      local ok_top, top = pcall(vim.fn.line, "w0", winid)
      local ok_bot, bot = pcall(vim.fn.line, "w$", winid)
      windows[#windows + 1] = {
        winid = winid,
        current = winid == vim.api.nvim_get_current_win(),
        topline = ok_top and top or nil,
        botline = ok_bot and bot or nil,
      }
    end
  end
  return windows
end

local function terminal_info(bufnr)
  local job_id = terminal_job_for_buf(bufnr)
  local pid = nil
  if job_id then
    local ok_pid, value = pcall(vim.fn.jobpid, job_id)
    if ok_pid and type(value) == "number" and value > 0 then
      pid = value
    end
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  local title = nil
  pcall(function()
    title = vim.b[bufnr].term_title
  end)

  local windows = terminal_windows(bufnr)
  return {
    bufnr = bufnr,
    name = name,
    title = title,
    job_id = job_id,
    pid = pid,
    line_count = vim.api.nvim_buf_line_count(bufnr),
    listed = vim.fn.buflisted(bufnr) == 1,
    loaded = vim.api.nvim_buf_is_loaded(bufnr),
    visible = #windows > 0,
    windows = windows,
  }
end

local function terminal_content_end(bufnr)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local chunk_size = 200
  local scan_end = line_count
  while scan_end > 0 do
    local scan_start = math.max(0, scan_end - chunk_size)
    local lines = vim.api.nvim_buf_get_lines(bufnr, scan_start, scan_end, false)
    for index = #lines, 1, -1 do
      if vim.trim(lines[index] or "") ~= "" then
        return scan_start + index
      end
    end
    scan_end = scan_start
  end
  return 0
end

local function list_terminals()
  local terminals = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if is_terminal_buffer(bufnr) then
      terminals[#terminals + 1] = terminal_info(bufnr)
    end
  end
  table.sort(terminals, function(a, b)
    if a.bufnr == vim.api.nvim_get_current_buf() then
      return true
    end
    if b.bufnr == vim.api.nvim_get_current_buf() then
      return false
    end
    if a.visible ~= b.visible then
      return a.visible
    end
    return a.bufnr < b.bufnr
  end)
  return terminals
end

local function resolve_terminal_bufnr(args)
  args = args or {}
  local bufnr = tonumber(args.bufnr)
  if args.current then
    bufnr = vim.api.nvim_get_current_buf()
  end
  if bufnr then
    if not is_terminal_buffer(bufnr) then
      error("buffer is not a terminal: " .. tostring(bufnr))
    end
    return bufnr
  end

  local current = vim.api.nvim_get_current_buf()
  if is_terminal_buffer(current) then
    return current
  end

  local terminals = list_terminals()
  if #terminals == 1 then
    return terminals[1].bufnr
  end
  error("terminal capture requires --current or --bufnr when current buffer is not a terminal")
end

local function capture_terminal(args)
  args = args or {}
  local bufnr = resolve_terminal_bufnr(args)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local content_end = terminal_content_end(bufnr)
  local last = tonumber(args.last) or 200
  if last < 0 then
    last = 0
  end
  local start_line = 0
  if last > 0 then
    start_line = math.max(0, content_end - last)
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, content_end, false)
  return vim.tbl_extend("force", terminal_info(bufnr), {
    start_line = content_end > 0 and (start_line + 1) or 0,
    end_line = content_end,
    trailing_blank_lines = line_count - content_end,
    truncated = start_line > 0,
    content = table.concat(lines, "\n"),
    lines = lines,
  })
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
  if find_buffer_by_path(path) or vim.fn.filereadable(path) == 1 then
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
  if bufnr then vim.fn.bufload(bufnr) end
  local current = bufnr and vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    or (vim.fn.filereadable(path) == 1 and read_file_lines(path) or {})
  local first = args.start or 0
  local last = args["end"] or -1
  if last == -1 then last = #current end
  if first < 0 or first % 1 ~= 0 or last % 1 ~= 0 or last < first or last > #current then
    error("invalid line range: use zero-based [start, end), with -1 for EOF")
  end
  if bufnr then
    vim.api.nvim_buf_set_lines(bufnr, first, last, true, lines)
  else
    local next_lines = {}
    for i = 1, first do next_lines[#next_lines + 1] = current[i] end
    for _, line in ipairs(lines) do next_lines[#next_lines + 1] = line end
    for i = last + 1, #current do next_lines[#next_lines + 1] = current[i] end
    vim.fn.writefile(next_lines, path)
  end
  return { stdout = "Success\n" }
end

local function command_diagnostics(req)
  local args = req.args or {}
  local target = args.path and normalize_path(args.path, req.cwd) or nil
  if target then target = target:gsub("/+$", "") end
  local diagnostics = vim.diagnostic.get()
  local out = {}
  for _, item in ipairs(diagnostics or {}) do
    local path = vim.api.nvim_buf_get_name(item.bufnr)
    if not target or path == target or path:sub(1, #target + 1) == target .. "/" then
      out[#out + 1] = {
        path = path,
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

local function command_terminal(req)
  local args = req.args or {}
  local subcommand = args.subcommand or "list"
  if subcommand == "list" then
    return { result = { terminals = list_terminals() } }
  end
  if subcommand == "capture" then
    return { result = capture_terminal(args) }
  end
  error("unsupported terminal subcommand: " .. tostring(subcommand))
end

local function list_buffers()
  local buffers = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    buffers[#buffers + 1] = {
      bufnr = bufnr,
      path = vim.api.nvim_buf_get_name(bufnr),
      loaded = vim.api.nvim_buf_is_loaded(bufnr),
      listed = vim.bo[bufnr].buflisted,
      modified = vim.bo[bufnr].modified,
      buftype = vim.bo[bufnr].buftype,
      filetype = vim.bo[bufnr].filetype,
      changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
      line_count = vim.api.nvim_buf_line_count(bufnr),
      current = bufnr == vim.api.nvim_get_current_buf(),
    }
  end
  return buffers
end

local function command_context(req)
  local windows, clients = {}, {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    windows[#windows + 1] = {
      winid = win, bufnr = vim.api.nvim_win_get_buf(win),
      cursor = vim.api.nvim_win_get_cursor(win),
      current = win == vim.api.nvim_get_current_win(),
    }
  end
  local get_clients = vim.lsp.get_clients or vim.lsp.get_active_clients
  for _, client in ipairs(get_clients()) do
    clients[#clients + 1] = { id = client.id, name = client.name, root_dir = client.config.root_dir }
  end
  return { result = {
    cwd = vim.fn.getcwd(), cursor = command_cursor().result,
    buffers = list_buffers(), windows = windows,
    diagnostics = command_diagnostics(req).result.diagnostics, lsp_clients = clients,
  } }
end

local function instance_info()
  return {
    instance_id = bridge.instance_id, pid = vim.fn.getpid(),
    cwd = vim.fn.getcwd(), path = vim.api.nvim_buf_get_name(0),
    server = vim.v.servername,
  }
end

local function publish_record()
  if not bridge.record_path then return end
  local record = instance_info()
  record.dir, record.token = bridge.dir, bridge.token
  assert(write_json(bridge.record_path, record), "cannot publish nvim-cli instance record")
end

local handlers = {
  ["instance-info"] = function() return { result = instance_info() } end,
  context = command_context,
  buffers = function() return { result = { buffers = list_buffers() } } end,
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
  terminal = command_terminal,
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
    return M.dispatch(req)
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

function M.stop()
  if bridge.timer then
    bridge.timer:stop()
    bridge.timer:close()
    bridge.timer = nil
  end
  if bridge.record_path then pcall(vim.fn.delete, bridge.record_path) end
  if bridge.dir then pcall(vim.fn.delete, bridge.dir, "rf") end
  pcall(vim.api.nvim_del_augroup_by_name, "NvimCliBridge")
  bridge.dir, bridge.token, bridge.record_path, bridge.instance_id = nil, nil, nil, nil
  bridge.cleanup_registered = false
end

local function register_cleanup()
  if bridge.cleanup_registered then return end
  bridge.cleanup_registered = true
  local group = vim.api.nvim_create_augroup("NvimCliBridge", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group, callback = M.stop, desc = "Clean nvim-cli bridge",
  })
end

function M.ensure_started(opts)
  opts = opts or {}
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
  bridge.dir = join_path(opts.root or vim.fn.tempname():match("^(.*)/"), "nvim-cli-bridge-" .. tostring(vim.fn.getpid()) .. "-" .. bridge.token:sub(1, 10))

  vim.fn.mkdir(join_path(bridge.dir, "requests"), "p", 448)
  vim.fn.mkdir(join_path(bridge.dir, "responses"), "p", 448)
  pcall(vim.fn.setfperm, bridge.dir, "rwx------")
  pcall(vim.fn.setfperm, join_path(bridge.dir, "requests"), "rwx------")
  pcall(vim.fn.setfperm, join_path(bridge.dir, "responses"), "rwx------")

  local registry = opts.registry_dir or vim.env.NVIM_CLI_REGISTRY_DIR
    or join_path(uv.os_tmpdir(), "nvim-cli-" .. tostring(uv.getuid and uv.getuid() or vim.env.USERNAME or "user"))
  assert(registry:sub(1, 1) == "/" or registry:match("^%a:"), "registry directory must be absolute")
  vim.fn.mkdir(registry, "p", 448)
  local stat = uv.fs_lstat(registry)
  assert(stat and stat.type == "directory", "invalid instance registry")
  if uv.getuid then
    assert(stat.uid == uv.getuid() and bit.band(stat.mode, 63) == 0, "instance registry must be private and owned by current user")
  end
  bridge.instance_id = tostring(vim.fn.getpid()) .. "-" .. bridge.token:sub(1, 10)
  bridge.registry_dir = registry
  bridge.record_path = join_path(registry, bridge.instance_id .. ".json")
  publish_record()

  bridge.timer = uv.new_timer()
  bridge.timer:start(100, 100, vim.schedule_wrap(process_requests))
  register_cleanup()
  vim.api.nvim_create_autocmd({ "DirChanged", "BufEnter" }, {
    group = "NvimCliBridge", callback = publish_record,
    desc = "Update nvim-cli instance metadata",
  })

  return {
    dir = bridge.dir,
    token = bridge.token,
  }
end

function M.inject_env(env)
  env = env or {}
  local info = M.ensure_started()
  env.NVIM_CLI_REGISTRY_DIR = bridge.registry_dir
  env.NVIM_CLI_BRIDGE_DIR = info.dir
  env.NVIM_CLI_BRIDGE_TOKEN = info.token
  return env
end

-- Shared dispatcher used by both RPC and the file receiver.
function M.dispatch(req)
  if req.expected_instance and req.expected_instance ~= vim.NIL and req.expected_instance ~= bridge.instance_id then
    error("instance identity changed; list instances again")
  end
  if req.expected_pid and req.expected_pid ~= vim.NIL and req.expected_pid ~= vim.fn.getpid() then
    error("Neovim PID changed; list instances again")
  end
  req.args = req.args or {}
  for key, value in pairs(req.args) do
    if value == vim.NIL then req.args[key] = nil end
  end
  local handler = handlers[tostring(req.command or "")]
  if not handler then error("unsupported nvim-cli command: " .. tostring(req.command)) end
  return handler(req)
end

-- Integrations retain ownership of their application-specific operations.
function M.register(name, handler)
  assert(type(name) == "string" and type(handler) == "function")
  assert(handlers[name] == nil, "handler already registered: " .. name)
  handlers[name] = handler
end

return M

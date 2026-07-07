local M = {}

local uv = vim.uv or vim.loop
local indexes = {}

local DIRECT_LIMIT = 160
local DIRECT_SCAN_LIMIT = 2000
local CACHE_TTL_MS = 5 * 60 * 1000
local CHUNK_PARSE_BUDGET_MS = 6

local function truncate_text(text, max_len)
  if #text > max_len then return text:sub(1, max_len) .. "\n... (truncated)" end
  return text
end

local function path_doc(path)
  local full = vim.fn.fnamemodify(path, ":p")
  local stat = uv and uv.fs_stat(full) or nil
  if not stat then return "(missing)", full end

  if stat.type == "directory" then
    local entries = {}
    local scanner = uv and uv.fs_scandir(full) or nil
    while scanner and #entries < 20 do
      local name = uv.fs_scandir_next(scanner)
      if not name then break end
      if name ~= "." and name ~= ".." then table.insert(entries, name) end
    end
    local body = #entries > 0 and table.concat(entries, "\n") or "(empty)"
    return body, full
  end

  if stat.type == "file" and vim.fn.filereadable(full) == 1 then
    local ok, lines = pcall(vim.fn.readfile, full, "", 200)
    if ok and lines and type(lines) == "table" then
      local text = truncate_text(table.concat(lines, "\n"), 3000)
      local doc = (text ~= "" and text) or "(empty)"
      return doc, full
    end
    return "(unable to read)", full
  end

  return "(path)", full
end

local function now_ms()
  if uv and uv.hrtime then
    return math.floor(uv.hrtime() / 1000000)
  end
  return os.time() * 1000
end

local function normalize_path(path)
  path = tostring(path or "")
  path = path:gsub("\\", "/")
  local absolute = path:sub(1, 1) == "/"
  path = path:gsub("/+$", "")
  if path == "" then return absolute and "/" or "." end
  return path
end

local function normalize_prefix(prefix)
  prefix = tostring(prefix or "")
  if prefix:sub(1, 1) == "@" then
    prefix = prefix:sub(2)
  end
  prefix = prefix:gsub("\\", "/")
  prefix = prefix:gsub("^%./", "")
  return prefix
end

local function split_prefix(prefix)
  prefix = normalize_prefix(prefix)
  if prefix == "" then
    return "", ""
  end
  if prefix == "/" then
    return "/", ""
  end
  if prefix:sub(-1) == "/" then
    return prefix:sub(1, -2), ""
  end
  local dir, partial = prefix:match("^(.*)/([^/]*)$")
  if dir then
    if dir == "" and prefix:sub(1, 1) == "/" then
      dir = "/"
    end
    return dir, partial or ""
  end
  return "", prefix
end

local function current_cwd()
  local ok, cwd = pcall(vim.fn.getcwd)
  if ok and cwd and cwd ~= "" then
    return normalize_path(cwd)
  end
  return "."
end

local function path_join(parent, child)
  if parent == "" or parent == "." then
    return child
  end
  if parent == "/" then
    return "/" .. child
  end
  return parent .. "/" .. child
end

local function display_join(parent, child)
  if parent == "" then
    return child
  end
  if parent == "/" then
    return "/" .. child
  end
  if parent:sub(-1) == "/" then
    return parent .. child
  end
  return parent .. "/" .. child
end

local function expand_scan_dir(dir, cwd)
  if dir == "" then
    return cwd, ""
  end
  if dir == "~" or dir:sub(1, 2) == "~/" then
    local expanded = vim.fn.expand(dir)
    return normalize_path(expanded), dir
  end
  if dir:sub(1, 1) == "/" then
    return normalize_path(dir), dir
  end
  return normalize_path(path_join(cwd, dir)), dir
end

local function matches_name(name, partial)
  if partial == "" then return true end
  if partial:lower() == partial then
    return name:lower():sub(1, #partial) == partial
  end
  return name:sub(1, #partial) == partial
end

local function make_item(label_path, full_path, kind)
  local type_label = kind == "directory" and "Directory" or "Path"
  return {
    label = "@" .. label_path,
    desc = type_label .. ": " .. full_path,
  }
end

local function make_index_item(label_path, cwd)
  return make_item(label_path, normalize_path(path_join(cwd, label_path)), "path")
end

local function scan_direct(prefix, opts)
  opts = opts or {}
  local limit = tonumber(opts.direct_limit) or DIRECT_LIMIT
  local scan_limit = tonumber(opts.direct_scan_limit) or DIRECT_SCAN_LIMIT
  if limit <= 0 then return {} end

  local cwd = current_cwd()
  local dir, partial = split_prefix(prefix)
  local scan_dir, display_parent = expand_scan_dir(dir, cwd)
  local ok, scanner = pcall(function()
    return uv and uv.fs_scandir(scan_dir) or nil
  end)
  if not ok or not scanner then return {} end

  local items = {}
  local scanned = 0
  while #items < limit and scanned < scan_limit do
    local name, kind = uv.fs_scandir_next(scanner)
    if not name then break end
    scanned = scanned + 1
    if name ~= "." and name ~= ".." and matches_name(name, partial) then
      kind = kind or "path"
      local label_path = display_join(display_parent, name)
      local full_path = normalize_path(path_join(scan_dir, name))
      items[#items + 1] = make_item(label_path, full_path, kind)
    end
  end

  table.sort(items, function(a, b)
    local ad = a.desc and a.desc:match("^Directory:")
    local bd = b.desc and b.desc:match("^Directory:")
    if ad ~= bd then return ad ~= nil end
    return a.label < b.label
  end)
  return items
end

local function should_index_prefix(prefix)
  if vim.fn.executable("fd") ~= 1 then return false end
  if not uv or type(uv.spawn) ~= "function" then return false end

  local cwd = current_cwd()
  local dir, partial = split_prefix(prefix)
  if cwd == "/" then return false end
  if partial == "" and dir == "" then return true end
  if dir:sub(1, 1) == "/" or dir == "~" or dir:sub(1, 2) == "~/" then return false end
  return true
end

local function index_key()
  return current_cwd()
end

local function index_is_fresh(index)
  if not index then return false end
  if index.status == "running" then return true end
  return now_ms() - (index.time or 0) <= CACHE_TTL_MS
end

local function add_index_line(index, line)
  local path = normalize_prefix((line or ""):gsub("\r$", ""))
  if path == "" or path == "." or index.seen[path] then return end

  index.seen[path] = true
  index.items[#index.items + 1] = make_index_item(path, index.cwd)
end

local function drain_chunks(index)
  index.drain_scheduled = false

  local deadline = now_ms() + CHUNK_PARSE_BUDGET_MS
  while index.chunk_head <= #index.chunks do
    local chunk = index.chunks[index.chunk_head]
    index.chunks[index.chunk_head] = nil
    index.chunk_head = index.chunk_head + 1

    local data = (index.partial or "") .. (chunk or "")
    local start = 1
    while true do
      local newline = data:find("\n", start, true)
      if not newline then break end
      add_index_line(index, data:sub(start, newline - 1))
      start = newline + 1
    end
    index.partial = data:sub(start)

    if now_ms() >= deadline then
      index.drain_scheduled = true
      vim.schedule(function() drain_chunks(index) end)
      return
    end
  end

  index.chunks = {}
  index.chunk_head = 1

  if index.finished then
    if index.partial and index.partial ~= "" then
      add_index_line(index, index.partial)
      index.partial = ""
    end
    index.status = index.exit_code == 0 and "ready" or "failed"
    index.time = now_ms()
  end
end

local function schedule_drain(index)
  if index.drain_scheduled then return end
  index.drain_scheduled = true
  vim.schedule(function() drain_chunks(index) end)
end

local function close_handle(handle)
  if handle and not handle:is_closing() then
    pcall(function() handle:close() end)
  end
end

local function start_fd_index(prefix, opts)
  opts = opts or {}
  prefix = normalize_prefix(prefix)
  if not should_index_prefix(prefix) then return end

  local key = index_key()
  local existing = indexes[key]
  if index_is_fresh(existing) then return end

  local cwd = current_cwd()
  local index = {
    cwd = cwd,
    status = "running",
    time = now_ms(),
    items = {},
    seen = {},
    chunks = {},
    chunk_head = 1,
    partial = "",
  }
  indexes[key] = index

  local stdout = uv.new_pipe(false)
  local args = {
    "--type",
    "f",
    "--type",
    "d",
    "--hidden",
    "--exclude",
    ".git",
    "--one-file-system",
    "--color",
    "never",
    "--strip-cwd-prefix",
    ".",
  }

  local handle
  local spawn_opts = {
    args = args,
    cwd = cwd,
    stdio = { nil, stdout, nil },
    env = nil,
    uid = nil,
    gid = nil,
    verbatim = false,
    detached = false,
    hide = true,
  }
  handle = uv.spawn("fd", spawn_opts, function(code, signal)
    index.exit_code = code
    index.exit_signal = signal
    index.finished = true
    if index.timer then
      pcall(function()
        index.timer:stop()
        index.timer:close()
      end)
      index.timer = nil
    end
    pcall(function() stdout:read_stop() end)
    close_handle(stdout)
    close_handle(handle)
    schedule_drain(index)
  end)

  if not handle then
    close_handle(stdout)
    index.status = "failed"
    index.time = now_ms()
    return
  end

  index.handle = handle
  stdout:read_start(function(_, data)
    if data then
      index.chunks[#index.chunks + 1] = data
      schedule_drain(index)
    end
  end)

  local timeout_ms = tonumber(opts.fd_timeout_ms)
  if timeout_ms and timeout_ms > 0 and uv.new_timer then
    local timer = uv.new_timer()
    index.timer = timer
    timer:start(timeout_ms, 0, function()
      if indexes[key] == index and index.status == "running" then
        pcall(function() handle:kill("sigterm") end)
      end
    end)
  end
end

local function path_matches_prefix(path, prefix)
  if prefix == "" then return true end
  local compare_path = path
  local compare_prefix = prefix
  if prefix:lower() == prefix then
    compare_path = path:lower()
    compare_prefix = prefix:lower()
  end
  if compare_path:sub(1, #compare_prefix) == compare_prefix then return true end

  local dir, partial = split_prefix(compare_prefix)
  if partial == "" then return false end
  local rest = compare_path
  if dir ~= "" then
    local dir_prefix = dir:sub(-1) == "/" and dir or (dir .. "/")
    if rest:sub(1, #dir_prefix) ~= dir_prefix then return false end
    rest = rest:sub(#dir_prefix + 1)
  end

  for component in rest:gmatch("[^/]+") do
    if component:sub(1, #partial) == partial then return true end
  end
  return false
end

local function indexed_items(prefix, opts)
  opts = opts or {}
  prefix = normalize_prefix(prefix)
  if prefix == "" and opts.include_empty_index == false then return {} end

  local index = indexes[index_key()]
  if not index or not index_is_fresh(index) then return {} end

  local limit = tonumber(opts.max_items)
  local items = {}
  for _, item in ipairs(index.items or {}) do
    local path = item.label and item.label:gsub("^@", "") or ""
    if path_matches_prefix(path, prefix) then
      items[#items + 1] = item
      if limit and #items >= limit then break end
    end
  end
  return items
end

local function merge_items(primary, secondary, limit)
  local out = {}
  local seen = {}
  for _, list in ipairs({ primary or {}, secondary or {} }) do
    for _, item in ipairs(list) do
      if item and item.label and not seen[item.label] then
        seen[item.label] = true
        out[#out + 1] = item
        if limit and #out >= limit then
          return out
        end
      end
    end
  end
  return out
end

function M.list_fd_paths(prefix, opts)
  opts = opts or {}
  prefix = normalize_prefix(prefix)
  local direct = scan_direct(prefix, opts)
  local recursive = indexed_items(prefix, opts)
  start_fd_index(prefix, opts)
  local limit = tonumber(opts.max_items)
  return merge_items(direct, recursive, limit)
end

M.path_doc = path_doc

return M

local M = {}
local uv = vim.uv or vim.loop
local worker = vim.fs.dirname(debug.getinfo(1, "S").source:gsub("^@", "")) .. "/cockpit_search_worker.lua"
local FILE_LIMIT = 8 * 1024 * 1024

local function clean(text) return vim.fn.strtrans(tostring(text or "")):gsub("%s+", " ") end
local function valid_query(query)
  return type(query) == "string" and vim.trim(query) ~= "" and #query <= 1024 and not query:find("%c")
end
local function fingerprint(stat)
  return { dev = stat.dev, ino = stat.ino, size = stat.size, mtime = stat.mtime, ctime = stat.ctime }
end

-- Synchronous streaming core, called only in a worker or isolated tests.
function M.scan(threads, query, opts)
  opts = opts or {}
  if not valid_query(query) then return nil, "Enter 1–1024 bytes of literal text without control characters" end
  local result = { hits = {}, stats = { searched = 0, unavailable = 0, oversized = 0, binary = 0, changed = 0, limited = 0, bytes = 0 }, limits = {} }
  local stats = result.stats
  local limit = opts.max_results or 200
  local per_thread = opts.per_thread or 20
  local byte_limit = opts.max_bytes or 64 * 1024 * 1024
  local file_limit = opts.max_file_bytes or FILE_LIMIT
  local thread_limit = opts.max_threads or 1000
  local deadline = uv.hrtime() + (opts.timeout_ms or 6000) * 1e6
  local needle = query:lower()
  local chunk_size = opts.chunk_bytes or 64 * 1024
  for index, thread in ipairs(threads or {}) do
    if index > thread_limit then result.limits[#result.limits + 1] = "thread limit"; break end
    if #result.hits >= limit then result.limits[#result.limits + 1] = "result limit"; break end
    if stats.bytes >= byte_limit then result.limits[#result.limits + 1] = "byte limit"; break end
    if uv.hrtime() >= deadline then result.limits[#result.limits + 1] = "time limit"; break end
    local path = thread.transcript_path
    local source_stat = type(path) == "string" and path ~= "" and uv.fs_stat(path) or nil
    local fd = source_stat and source_stat.type == "file" and uv.fs_open(path, "r", 0) or nil
    local stat = fd and uv.fs_fstat(fd)
    if not fd or not stat or stat.type ~= "file" then
      stats.unavailable = stats.unavailable + 1
      if fd then uv.fs_close(fd) end
    elseif stat.size > file_limit then
      stats.oversized = stats.oversized + 1; uv.fs_close(fd)
    else
      local local_hits, offset, line, processed, tail, matched = {}, 0, 1, 0, "", false
      local issue
      while offset < stat.size do
        if uv.hrtime() >= deadline then issue = "time limit"; break end
        if stats.bytes >= byte_limit then issue = "byte limit"; break end
        local count = math.min(chunk_size, stat.size - offset, byte_limit - stats.bytes)
        local chunk = uv.fs_read(fd, count, offset)
        if not chunk or chunk == "" then issue = "read failure"; break end
        offset, stats.bytes = offset + #chunk, stats.bytes + #chunk
        if chunk:find("\0", 1, true) then issue = "binary"; break end
        local cursor = 1
        while cursor <= #chunk do
          local newline = chunk:find("\n", cursor, true)
          local fragment = chunk:sub(cursor, newline and newline - 1 or #chunk)
          local window = tail .. fragment
          local start = not matched and window:lower():find(needle, 1, true) or nil
          if start then
            local left, right = math.max(1, start - 60), math.min(#window, start + #needle + 140)
            local anchor = window:sub(left, right)
            local base = processed - #tail
            local_hits[#local_hits + 1] = {
              thread_id = thread.thread_id, title = thread.title, provider_id = thread.provider_id, cwd = thread.cwd,
              path = path, line = line, column = base + start, preview = clean(anchor),
              anchor_column = base + left, anchor_bytes = #anchor, anchor_hash = vim.fn.sha256(anchor),
              source = fingerprint(stat),
            }
            matched = true
          end
          processed = processed + #fragment
          tail = window:sub(math.max(1, #window - #needle - 64 + 1))
          if #local_hits >= per_thread or #result.hits + #local_hits >= limit then issue = "match limit"; break end
          if not newline then break end
          line, processed, tail, matched = line + 1, 0, "", false
          cursor = newline + 1
        end
        if issue then break end
      end
      local finished_stat = uv.fs_fstat(fd)
      uv.fs_close(fd)
      if not finished_stat or not vim.deep_equal(fingerprint(stat), fingerprint(finished_stat)) then
        stats.changed = stats.changed + 1
      elseif issue == "binary" then stats.binary = stats.binary + 1
      elseif issue == "read failure" then stats.unavailable = stats.unavailable + 1
      else
        stats.searched = stats.searched + 1
        vim.list_extend(result.hits, local_hits)
        if issue == "match limit" then stats.limited = stats.limited + 1 end
        if issue == "byte limit" or issue == "time limit" then result.limits[#result.limits + 1] = issue; break end
      end
    end
  end
  return result
end

-- Revalidate the matched byte range while opening; appends outside it are OK.
function M.read_hit(hit, query)
  if not valid_query(query) then return nil, "Invalid search text" end
  local current = uv.fs_stat(hit.path)
  if not current or current.type ~= "file" then return nil, "Transcript is unavailable" end
  local fd, err = uv.fs_open(hit.path, "r", 0)
  if not fd then return nil, err end
  local stat = uv.fs_fstat(fd)
  if not stat or stat.type ~= "file" or stat.size > FILE_LIMIT then uv.fs_close(fd); return nil, "Transcript is unavailable or exceeds 8 MiB" end
  if stat.dev ~= hit.source.dev or stat.ino ~= hit.source.ino then uv.fs_close(fd); return nil, "Transcript was replaced; repeat search" end
  local text, read_err = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  if not text then return nil, read_err end
  if text:find("\0", 1, true) then return nil, "Transcript is binary; repeat search" end
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then table.remove(lines) end
  local line = lines[hit.line] or ""
  local anchor = line:sub(hit.anchor_column, hit.anchor_column + hit.anchor_bytes - 1)
  if vim.fn.sha256(anchor) ~= hit.anchor_hash or line:sub(hit.column, hit.column + #query - 1):lower() ~= query:lower() then
    return nil, "Matched text moved or changed; repeat search"
  end
  return { lines = lines, line = hit.line, column = hit.column, thread_id = hit.thread_id }
end

local function run(request, callback)
  local ok, job = pcall(vim.system, { vim.v.progpath, "--headless", "--clean", "-u", "NONE", "-l", worker },
    { stdin = vim.json.encode(request), text = true, timeout = 8000 }, function(result)
      vim.schedule(function()
        local decoded, value = pcall(vim.json.decode, result.stdout or "")
        if result.code ~= 0 or not decoded or type(value) ~= "table" then callback(nil, "Search worker failed or timed out")
        elseif value.error then callback(nil, value.error)
        else callback(value) end
      end)
    end)
  if not ok then vim.schedule(function() callback(nil, tostring(job)) end); return nil end
  return job
end
function M.search(threads, query, callback, opts)
  if not valid_query(query) then
    vim.schedule(function() callback(nil, "Enter 1–1024 bytes of literal text without control characters") end)
    return nil
  end
  local sources = {}
  for _, thread in ipairs(threads or {}) do
    sources[#sources + 1] = { thread_id = thread.thread_id, title = thread.title, provider_id = thread.provider_id,
      cwd = thread.cwd, transcript_path = thread.transcript_path }
  end
  return run({ action = "search", threads = sources, query = query, opts = opts }, callback)
end

function M.open(threads, query, opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "lazyagent://search/" .. tostring(uv.hrtime()))
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "nofile", "wipe", false
  vim.bo[buf].filetype = "lazyagent_search"
  local jobs, closed, report, rows, owner_autocmd = {}, false, nil, {}, nil
  local opening_job
  local function render(message)
    if closed or not vim.api.nvim_buf_is_valid(buf) then return end
    local lines = { "LazyAgent · Transcript search · " .. clean(query),
      "<CR>/o open read-only transcript at match · <C-y> copy agent ref · q cancel/close",
      "Scope: " .. clean(opts.scope or "All provided threads"), "" }
    if message then lines[#lines + 1] = message end
    if report then
      local stats = report.stats
      lines[#lines + 1] = string.format("%d matches · %d searched · %d unavailable · %d oversized · %d binary · %d changed · %d capped",
        #report.hits, stats.searched, stats.unavailable, stats.oversized, stats.binary, stats.changed, stats.limited)
      if #report.limits > 0 or stats.limited > 0 then lines[#lines + 1] = "Partial results: " .. table.concat(report.limits, ", ") .. (stats.limited > 0 and " · per-thread/result cap reached" or "") end
      if #report.hits == 0 then lines[#lines + 1] = "No matches in searched transcript text." end
      rows = {}
      for index, hit in ipairs(report.hits) do
        lines[#lines + 1] = string.format("%s · %s · %s:%d:%d", clean(hit.title or hit.thread_id), clean(hit.provider_id), clean(hit.cwd), hit.line, hit.column)
        rows[#lines] = index
        lines[#lines + 1] = "  " .. hit.preview
        rows[#lines] = index
      end
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable, vim.bo[buf].modified = false, false
  end
  local function dispose()
    if closed then return end
    closed = true
    for job in pairs(jobs) do pcall(job.kill, job, 15) end
    if owner_autocmd then pcall(vim.api.nvim_del_autocmd, owner_autocmd) end
  end
  local handle = { bufnr = buf }
  function handle.close()
    dispose()
    if vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
  end
  local function open_hit()
    local hit = report and report.hits[rows[vim.api.nvim_win_get_cursor(0)[1]]]
    if not hit then return end
    if opening_job then pcall(opening_job.kill, opening_job, 15); jobs[opening_job] = nil end
    local requested_tab = vim.api.nvim_get_current_tabpage()
    local job
    job = run({ action = "open", hit = hit, query = query }, function(value, err)
      if job then jobs[job] = nil end
      if job ~= opening_job then return end
      opening_job = nil
      if closed or not vim.api.nvim_buf_is_valid(buf) then return end
      if not value then render("Unavailable: " .. clean(err)); return end
      if vim.api.nvim_get_current_tabpage() ~= requested_tab then return end
      local snapshot = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(snapshot, "lazyagent://search-hit/" .. hit.thread_id .. "/" .. tostring(uv.hrtime()))
      vim.bo[snapshot].buftype, vim.bo[snapshot].bufhidden, vim.bo[snapshot].swapfile = "nofile", "wipe", false
      vim.api.nvim_buf_set_lines(snapshot, 0, -1, false, value.lines)
      vim.bo[snapshot].filetype, vim.bo[snapshot].modifiable, vim.bo[snapshot].readonly = "markdown", false, true
      vim.cmd("tab sbuffer " .. snapshot)
      vim.api.nvim_win_set_cursor(0, { value.line, value.column - 1 })
      vim.wo.wrap = false
      vim.wo.winbar = "Transcript snapshot · " .. clean(hit.title or hit.thread_id):gsub("%%", "%%%%")
      vim.b[snapshot].lazyagent_search_thread_id = hit.thread_id
      vim.keymap.set("n", "q", function() vim.cmd("tabclose") end, { buffer = snapshot, nowait = true, desc = "Close transcript snapshot" })
    end)
    opening_job = job
    if job then jobs[job] = true end
  end
  render("Searching " .. #threads .. " threads…")
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
  vim.wo.wrap = false
  for _, key in ipairs({ "<CR>", "o" }) do vim.keymap.set("n", key, open_hit, { buffer = buf, desc = "Open matching transcript snapshot" }) end
  vim.keymap.set("n", "<C-y>", function()
    local hit = report and report.hits[rows[vim.api.nvim_win_get_cursor(0)[1]]]
    if hit then vim.fn.setreg('"', "agent:" .. hit.thread_id) end
  end, { buffer = buf, desc = "Copy matching thread reference" })
  vim.keymap.set("n", "q", function() vim.cmd("close") end, { buffer = buf, nowait = true, desc = "Cancel/close transcript search" })
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, once = true, callback = dispose })
  if opts.owner_buf then
    owner_autocmd = vim.api.nvim_create_autocmd("BufWipeout", { buffer = opts.owner_buf, once = true, callback = function()
      dispose()
      vim.schedule(handle.close)
    end })
  end
  local job
  job = M.search(threads, query, function(value, err)
    if job then jobs[job] = nil end
    if closed or not vim.api.nvim_buf_is_valid(buf) then return end
    if not value then render("Unavailable: " .. clean(err)); return end
    report = value; render()
    local targets = vim.tbl_keys(rows); table.sort(targets)
    local win = vim.fn.bufwinid(buf)
    if targets[1] and win >= 0 then vim.api.nvim_win_set_cursor(win, { targets[1], 0 }) end
  end, opts.search_opts)
  if job then jobs[job] = true end
  return handle
end
return M

local M = {}

local function percent(value)
  return type(value) == "number" and value == value and value >= 0 and value < math.huge and value or nil
end

function M.parse(provider, response)
  if type(response) ~= "table" then return nil end
  local windows = {}
  local function add(label, used, reset, period)
    if percent(used) then
      windows[#windows + 1] = { label = label, used = used, resets_at = reset, period = period }
    end
  end
  if provider == "claude" then
    local limits = response.rate_limits
    if type(limits) ~= "table" then return nil end
    local function add_window(label, limit, period)
      if type(limit) == "table" then
        add(label, limit.utilization or limit.percent,
          type(limit.resets_at) == "string" and limit.resets_at or nil, period)
      end
    end
    if type(limits.limits) == "table" then
      for _, limit in ipairs(limits.limits) do
        if type(limit) == "table" then
          local label = ({ session = "Session", weekly_all = "Week", weekly_scoped = "Week" })[limit.kind]
            or limit.kind or "Limit"
          local period = ({ session = "Session", weekly_all = "Week" })[limit.kind]
          for _, key in ipairs({ "model", "surface" }) do
            local scope = type(limit.scope) == "table" and limit.scope[key]
            if type(scope) == "table" and type(scope.display_name) == "string" then
              label, period = label .. " · " .. scope.display_name, nil
              break
            end
          end
          add_window(label, limit, period)
        end
      end
    end
    if #windows == 0 then
      add_window("Session", limits.five_hour, "Session")
      add_window("Week", limits.seven_day, "Week")
      local scoped = type(limits.model_scoped) == "table" and limits.model_scoped or {}
      for _, limit in ipairs(scoped) do
        if type(limit) == "table" and type(limit.display_name) == "string" then
          add_window("Week · " .. limit.display_name, limit)
        end
      end
      if #scoped == 0 then
        add_window("Week · Opus", limits.seven_day_opus)
        add_window("Week · Sonnet", limits.seven_day_sonnet)
      end
    end
  elseif provider == "codex" then
    local buckets = response.rateLimitsByLimitId
    if type(buckets) ~= "table" or next(buckets) == nil then
      if type(response.rateLimits) ~= "table" then return nil end
      buckets = { [""] = response.rateLimits }
    end
    local names = vim.tbl_keys(buckets); table.sort(names)
    for _, name in ipairs(names) do
      local bucket = buckets[name]
      for _, key in ipairs({ "primary", "secondary" }) do
        local limit = type(bucket) == "table" and bucket[key]
        if type(limit) == "table" then
          local minutes = tonumber(limit.windowDurationMins)
          local label = minutes == 10080 and "Week" or (minutes and string.format("%g h", minutes / 60) or key)
          local period = (name == "" or name:lower() == "codex") and label or nil
          if name ~= "" then label = label .. " · " .. tostring(bucket.limitName or name) end
          local reset = percent(limit.resetsAt)
          if reset and reset > 32503680000 then reset = nil end
          add(label, limit.usedPercent, reset and os.date("!%Y-%m-%d %H:%M:%S UTC", reset) or nil, period)
        end
      end
    end
  else return nil end
  return #windows > 0 and windows or nil
end

-- Converts a reported reset timestamp with an explicit UTC offset to epoch
-- seconds, so callers can render it in the local time zone with os.date.
function M.reset_time(value)
  if type(value) ~= "string" then return nil end
  local y, m, d, hh, mm, ss, zone =
    value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)[.%d]*%s*(.+)$")
  if not y then return nil end
  local offset
  if zone == "UTC" or zone == "Z" then
    offset = 0
  else
    local sign, oh, om = zone:match("^([+-])(%d%d):?(%d%d)$")
    if not sign then return nil end
    offset = (sign == "-" and -1 or 1) * (tonumber(oh) * 3600 + tonumber(om) * 60)
  end
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  -- Days from civil (proleptic Gregorian), independent of the local zone.
  if m <= 2 then y = y - 1 end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  local days = era * 146097 + doe - 719468
  return days * 86400 + tonumber(hh) * 3600 + tonumber(mm) * 60 + tonumber(ss) - offset
end

function M.footer(entry)
  if not entry or not entry.windows then return nil end
  local parts = {}
  local function add_window(window)
    local left = math.floor(math.max(0, 100 - window.used) + 0.5)
    local label = string.format("%s %d%% left", window.period or window.label, left)
    local reset = M.reset_time(window.resets_at)
    if reset then label = label .. " " .. os.date("%m/%d %H:%M", reset) end
    parts[#parts + 1] = label
  end
  for _, window in ipairs(entry.windows) do
    if window.period then add_window(window) end
  end
  if #parts == 0 and entry.windows[1] then add_window(entry.windows[1]) end
  if #parts == 0 then return nil end
  local stale = entry.status ~= "ready" and entry.status ~= "loading"
  return table.concat(parts, " / ") .. (stale and " (stale)" or "")
end

function M.provider(source)
  local name = tostring(source and source.provider or ""):lower()
  if name:find("codex", 1, true) then return "codex" end
  if name:find("claude", 1, true) then return "claude" end
end

-- Probes ask control questions only. A failed refresh retains the last good value.
function M.new(opts)
  opts = opts or {}
  local cache, closed = {}, false
  local self = {}
  function self.get(source, callback, refresh)
    if closed or not source then return { status = "unavailable" } end
    local provider = M.provider(source)
    if not provider then return { status = "unsupported" } end
    local env = {}
    local keys = vim.tbl_keys(source.env or {})
    table.sort(keys)
    for _, name in ipairs(keys) do env[#env + 1] = { name, source.env[name] } end
    local key = vim.fn.sha256(vim.json.encode({ provider, source.executable or "", source.cwd or "", env }))
    local entry = cache[key]
    if entry then
      local ttl = refresh and entry.status == "ready" and (opts.refresh_interval or 30) or (opts.ttl or 300)
      if entry.job or os.time() - entry.at < ttl then return entry end
    end
    entry = entry or {}; cache[key] = entry
    entry.at, entry.status = os.time(), "loading"
    local command = opts.command and opts.command(provider) or (provider == "codex" and { "codex", "app-server" }
      or { "claude", "--output-format", "stream-json", "--verbose", "--input-format", "stream-json", "--no-session-persistence" })
    if not opts.command and source.executable then command[1] = source.executable end
    local function notify()
      if not callback then return end
      vim.schedule(function()
        if not closed then callback() end
      end)
    end
    if vim.fn.executable(command[1]) ~= 1 then
      entry.status = "CLI unavailable"
      notify()
      return entry
    end
    local pending, settled, timer = "", false, (vim.uv or vim.loop).new_timer()
    entry.timer = timer
    local function finish(windows, reason)
      if settled then return end
      settled = true
      timer:stop(); timer:close(); entry.timer = nil
      entry.cancel = nil
      local job = entry.job; entry.job = nil
      if job then pcall(vim.fn.jobstop, job) end
      entry.status, entry.at = windows and "ready" or (reason or "unavailable"), os.time()
      if windows then entry.windows, entry.reported_at = windows, os.time() end
      notify()
    end
    entry.cancel = function()
      if settled then return end
      settled = true
      timer:stop(); timer:close(); entry.timer = nil
      entry.cancel = nil
      if entry.job then pcall(vim.fn.jobstop, entry.job); entry.job = nil end
    end
    local function send(message)
      vim.fn.chansend(entry.job, vim.json.encode(message) .. "\n")
    end
    local function receive(line)
      local ok, message = pcall(vim.json.decode, line)
      if not ok or type(message) ~= "table" then return end
      if provider == "codex" then
        if message.id == "lazyagent-init" then
          if message.error then finish(nil, "initialization failed"); return end
          send({ method = "initialized" })
          send({ id = "lazyagent-usage", method = "account/rateLimits/read", params = vim.NIL })
        elseif message.id == "lazyagent-usage" then
          finish(M.parse(provider, message.result), message.error and "usage request failed" or "unavailable")
        end
      elseif message.type == "control_response" and type(message.response) == "table"
        and message.response.request_id == "lazyagent-usage" then
        local response = message.response
        finish(response.subtype == "success" and M.parse(provider, response.response) or nil,
          response.subtype == "success" and "unavailable" or "usage request refused")
      end
    end
    local job = vim.fn.jobstart(command, {
      cwd = source.cwd, env = source.env,
      on_stdout = function(_, chunks)
        if settled then return end
        pending = pending .. table.concat(chunks, "\n")
        if #pending > 262144 then finish(nil, "response too large"); return end
        while not settled do
          local at = pending:find("\n", 1, true)
          if not at then break end
          local line = pending:sub(1, at - 1); pending = pending:sub(at + 1)
          receive(line)
        end
      end,
      on_exit = function() finish(nil, "CLI exited without usage") end,
    })
    if job <= 0 then finish(nil, "CLI failed to start"); return entry end
    entry.job = job
    timer:start(opts.timeout or 8000, 0, vim.schedule_wrap(function() finish(nil, "usage request timed out") end))
    if provider == "codex" then
      send({ id = "lazyagent-init", method = "initialize", params = {
        clientInfo = { name = "lazyagent-usage", version = "1" }, capabilities = vim.empty_dict() } })
    else
      send({ request_id = "lazyagent-usage", type = "control_request", request = { subtype = "get_usage", skip_behaviors = true } })
    end
    return entry
  end
  function self.close()
    closed = true
    for _, entry in pairs(cache) do
      if entry.cancel then entry.cancel() end
    end
  end
  return self
end

return M

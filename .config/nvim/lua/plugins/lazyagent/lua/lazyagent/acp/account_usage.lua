local M = {}

local function percent(value)
  return type(value) == "number" and value == value and value >= 0 and value < math.huge and value or nil
end

function M.parse(provider, response)
  if type(response) ~= "table" then return nil end
  local windows = {}
  local function add(label, used, reset)
    if percent(used) then windows[#windows + 1] = { label = label, used = used, resets_at = reset } end
  end
  if provider == "claude" then
    local limits = type(response.rate_limits) == "table" and response.rate_limits.limits
    if type(limits) ~= "table" then return nil end
    for _, limit in ipairs(limits) do
      if type(limit) == "table" then
        local label = ({ session = "Session", weekly_all = "Week", weekly_scoped = "Week" })[limit.kind] or limit.kind or "Limit"
        for _, key in ipairs({ "model", "surface" }) do
          local scope = type(limit.scope) == "table" and limit.scope[key]
          if type(scope) == "table" and type(scope.display_name) == "string" then
            label = label .. " · " .. scope.display_name; break
          end
        end
        add(label, limit.percent, type(limit.resets_at) == "string" and limit.resets_at or nil)
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
        local limit = bucket[key]
        if type(limit) == "table" then
          local minutes = tonumber(limit.windowDurationMins)
          local label = minutes == 10080 and "Week" or (minutes and string.format("%g h", minutes / 60) or key)
          if name ~= "" then label = label .. " · " .. tostring(bucket.limitName or name) end
          local reset = percent(limit.resetsAt)
          if reset and reset > 32503680000 then reset = nil end
          add(label, limit.usedPercent, reset and os.date("!%Y-%m-%d %H:%M:%S UTC", reset) or nil)
        end
      end
    end
  else return nil end
  return windows
end

-- One owner per Cockpit. Probes ask control questions only: no prompt, thread or model turn.
-- Failures back off for five minutes and retain the last good value with a stale marker.
function M.new(opts)
  opts = opts or {}
  local cache, closed = {}, false
  local self = {}
  function self.get(source, callback)
    if closed or not source then return { status = "unavailable" } end
    local name = tostring(source.provider or ""):lower()
    local provider = name:find("codex", 1, true) and "codex" or (name:find("claude", 1, true) and "claude" or nil)
    if not provider then return { status = "unsupported" } end
    local key = vim.fn.sha256(vim.json.encode({ provider, source.executable or "", source.cwd or "", source.env or {} }))
    local entry = cache[key]
    if entry and (entry.job or os.time() - entry.at < (opts.ttl or 300)) then return entry end
    entry = entry or {}; cache[key] = entry
    entry.at, entry.status = os.time(), "loading"
    local command = opts.command and opts.command(provider) or (provider == "codex" and { "codex", "app-server" }
      or { "claude", "--output-format", "stream-json", "--verbose", "--input-format", "stream-json", "--no-session-persistence" })
    if not opts.command and source.executable then command[1] = source.executable end
    if vim.fn.executable(command[1]) ~= 1 then entry.status = "CLI unavailable"; return entry end
    local pending, settled, timer = "", false, (vim.uv or vim.loop).new_timer()
    entry.timer = timer
    local function finish(windows, reason)
      if settled then return end
      settled = true
      timer:stop(); timer:close(); entry.timer = nil
      local job = entry.job; entry.job = nil
      if job then pcall(vim.fn.jobstop, job) end
      entry.status = windows and "ready" or (reason or "unavailable")
      if windows then entry.windows, entry.reported_at = windows, os.time() end
      if not closed and callback then callback() end
    end
    entry.cancel = function()
      if settled then return end
      settled = true
      timer:stop(); timer:close(); entry.timer = nil
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
        finish(response.subtype == "success" and M.parse(provider, response.response) or nil, "usage request refused")
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
        clientInfo = { name = "lazyagent-usage", version = "1" }, capabilities = {} } })
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

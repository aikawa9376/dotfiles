local mode = arg[1]
local function send(value)
  local encoded = vim.json.encode(value) .. "\n"
  -- Exercise partial stdout records, as well as the actual control handshake.
  io.stdout:write(encoded:sub(1, 12)); io.stdout:flush()
  vim.uv.sleep(5)
  io.stdout:write(encoded:sub(13)); io.stdout:flush()
end
for line in io.lines() do
  local message = vim.json.decode(line)
  if mode == "hang" then
    -- Keep stdin open until the owning probe times out or is disposed.
  elseif mode == "codex" then
    if message.method == "initialize" then
      assert(type(message.params.capabilities) == "table" and not vim.islist(message.params.capabilities),
        "Codex requires an object even when capabilities are empty")
      send({ id = message.id, result = {} })
    elseif message.method == "account/rateLimits/read" then
      send({ id = message.id, result = { rateLimits = {
        primary = { usedPercent = 25, windowDurationMins = 300, resetsAt = 1795000000 },
        secondary = { usedPercent = 49, windowDurationMins = 10080 },
      } } })
    else assert(message.method == "initialized", "usage must not create a thread or turn") end
  else
    assert(message.type == "control_request" and message.request.subtype == "get_usage"
      and message.request.skip_behaviors == true, "usage must be a control-only question")
    send({ type = "control_response", response = {
      request_id = message.request_id, subtype = "success", response = { rate_limits_available = true, rate_limits = {
        five_hour = { utilization = 44, resets_at = "2026-11-20T10:00:00.000Z" },
        seven_day = { utilization = 20 },
        model_scoped = { { display_name = "Fable", utilization = 4 } },
      } },
    } })
  end
end

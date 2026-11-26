local M = {}
local LIMIT, DEPTH = 200, 12
local complete = { completed = true, done = true, succeeded = true }
local icons = { completed = "●", done = "●", succeeded = "●", in_progress = "◐", running = "◐",
  failed = "×", cancelled = "−", canceled = "−", pending = "○", blocked = "!" }

local function text(value)
  if type(value) ~= "string" and type(value) ~= "number" then return "" end
  return vim.fn.strcharpart(vim.trim(tostring(value):gsub("[%c%s]+", " ")), 0, 240)
end

local function number(value)
  local n = tonumber(value)
  return n and n == n and n >= 0 and n < math.huge and n or nil
end

-- Display projection only: no transcript/tool bodies, process ownership or durable state.
function M.snapshot(runtime)
  if not runtime then return { available = false } end
  local budget, seen, truncated = LIMIT, {}, false
  local function node(item, depth)
    if type(item) ~= "table" then return nil end
    if budget <= 0 or depth > DEPTH or seen[item] then truncated = true; return nil end
    budget = budget - 1
    seen[item] = true
    local result = { title = text(item.content or item.text or item.title or item.name or item.description or item.id),
      state = text(item.status or item.state):lower(), children = {}, note = text(item.note),
      weight = (number(item.weight) or 0) > 0 and number(item.weight) or 1 }
    if result.state == "" then result.state = "unknown" end
    for _, child in ipairs(type(item.children) == "table" and item.children or {}) do
      if budget <= 0 then truncated = true; break end
      local projected = node(child, depth + 1)
      if projected then result.children[#result.children + 1] = projected end
    end
    return result
  end
  local function plan_nodes(plan)
    if type(plan) ~= "table" then return {} end
    local roots, ids, items = {}, {}, {}
    for _, item in ipairs(plan.entries or plan) do
      if budget <= 0 then truncated = true; break end
      local projected = node(item, 1)
      if projected then
        items[#items + 1] = { source = item, node = projected }
        if item.id ~= nil then ids[tostring(item.id)] = projected end
      end
    end
    -- Preserve explicit parent links when supplied; a standard flat ACP plan stays flat.
    local parents = {}
    for _, pair in ipairs(items) do
      local parent_id = pair.source.parentId or pair.source.parent_id
      local parent = parent_id and ids[tostring(parent_id)] or nil
      local ancestor, cyclic = parent, false
      while ancestor do
        if ancestor == pair.node then cyclic = true; break end
        ancestor = parents[ancestor]
      end
      if parent and not cyclic then
        parent.children[#parent.children + 1] = pair.node
        parents[pair.node] = parent
      else roots[#roots + 1] = pair.node end
    end
    return roots
  end
  local goal = runtime.acp_goal
  local result = { available = true, title = text(type(goal) == "table" and (goal.title or goal.objective or goal.text) or goal),
    plan = plan_nodes(runtime.acp_plan), agents = {}, tasks = {} }
  local agents = {}
  for _, id in ipairs(vim.tbl_keys(runtime.acp_subagents or {})) do agents[#agents + 1] = tostring(id) end
  table.sort(agents)
  local by_id, parent_ids = {}, {}
  for _, id in ipairs(agents) do
    if budget <= 0 then truncated = true; break end
    local child = runtime.acp_subagents[id]
    local projected = node(child, 1)
    if projected then
      projected.children = plan_nodes(child.current_plan)
      by_id[id], parent_ids[id] = projected, child.parentSessionId
    end
  end
  local linked = {}
  for _, id in ipairs(agents) do
    local projected, parent = by_id[id], by_id[parent_ids[id]]
    local ancestor, cyclic = parent, false
    while ancestor do
      if ancestor == projected then cyclic = true; break end
      ancestor = linked[ancestor]
    end
    if projected then
      if parent and not cyclic then
        parent.children[#parent.children + 1] = projected; linked[projected] = parent
      else result.agents[#result.agents + 1] = projected end
    end
  end
  local task_ids = vim.tbl_keys(runtime.acp_async_tasks or {})
  table.sort(task_ids)
  for _, id in ipairs(task_ids) do
    if budget <= 0 then truncated = true; break end
    local projected = node(runtime.acp_async_tasks[id], 1)
    if projected then result.tasks[#result.tasks + 1] = projected end
  end
  result.truncated = truncated
  local usage = runtime.acp_usage_stats or {}
  result.usage = { provider = text(usage.provider_usage), model = text(usage.model_id),
    updated_at = number(usage.updated_at), context = {}, turn = {}, cumulative = {} }
  for _, field in ipairs({ "used_tokens", "total_tokens", "percentage" }) do
    result.usage.context[field] = number((usage.context or {})[field])
  end
  for _, section in ipairs({ "turn", "cumulative" }) do
    for _, field in ipairs({ "prompt_tokens", "completion_tokens", "total_tokens" }) do
      result.usage[section][field] = number((usage[section] or {})[field])
    end
  end
  local cost = type(usage.cost) == "table" and usage.cost or {}
  result.usage.cost = number(cost.amount)
  result.usage.currency = text(cost.currency)
  return result
end

local function counts(nodes, depth)
  local done, total, weighted, weights = 0, 0, 0, 0
  if (depth or 0) > DEPTH then return 0, 1, 0 end
  for _, node in ipairs(nodes) do
    local d, t, p
    if #node.children > 0 then
      d, t, p = counts(node.children, (depth or 0) + 1)
    else
      d, t, p = 0, 1, 0
    end
    if complete[node.state] then d, p = t, 100 end
    done, total = done + d, total + t
    weights, weighted = weights + node.weight, weighted + p * node.weight
  end
  return done, total, weights > 0 and weighted / weights or 0
end
M.progress = counts

local function bar(percent, width)
  width = math.max(4, math.min(24, math.floor((width or 80) / 4)))
  local filled = math.floor(math.max(0, math.min(100, percent)) * width / 100 + 0.5)
  return string.rep("━", filled) .. string.rep("─", width - filled)
end

local function progress(done, total, width, percent)
  if total == 0 then return "No tasks reported" end
  percent = percent or done / total * 100
  return string.format("%s %.1f%% · %d/%d completed", bar(percent, width), percent, done, total)
end

function M.timeline(data, width)
  local lines = { "## Timeline", "" }
  if not data.available then
    lines[#lines + 1] = "Live timeline unavailable for this thread."
    return lines
  end
  if data.title ~= "" then lines[#lines + 1] = "### " .. data.title end
  local done, total, percent = counts(data.plan)
  lines[#lines + 1] = progress(done, total, width, percent)
  lines[#lines + 1] = data.weighted and "Progress uses relative sibling weights; splitting a task preserves its share."
    or "ACP plan progress uses equal sibling weights; it is not elapsed-time progress."
  if data.recorded_at then lines[#lines + 1] = "Recorded: " .. os.date("%Y-%m-%d %H:%M:%S", data.recorded_at) end
  local function append(nodes, depth)
    for _, node in ipairs(nodes) do
      local prefix = string.rep("  ", depth)
      lines[#lines + 1] = prefix .. (icons[node.state] or "○") .. " " .. node.title .. " [" .. node.state .. "]"
      local d, t, p = counts({ node })
      lines[#lines + 1] = prefix .. "  " .. progress(d, t, width, p)
      if node.note ~= "" then lines[#lines + 1] = prefix .. "  " .. node.note end
      if #node.children > 0 and depth < DEPTH then
        append(node.children, depth + 1)
      elseif #node.children > 0 then
        lines[#lines + 1] = prefix .. "  … deeper tasks omitted"
      end
    end
  end
  append(data.plan, 0)
  for _, section in ipairs({ { "Subagents", data.agents }, { "Background tasks", data.tasks } }) do
    if #section[2] > 0 then
      lines[#lines + 1] = ""; lines[#lines + 1] = "### " .. section[1]
      append(section[2], 0)
    end
  end
  if total == 0 and #data.agents == 0 and #data.tasks == 0 then
    lines[#lines + 1] = "Waiting for the agent to report a plan or tasks."
  end
  if data.truncated then lines[#lines + 1] = "Timeline truncated; counts cover displayed tasks only." end
  return lines
end

local function tokens(n) return n and string.format("%.0f", n) or "unavailable" end

function M.usage(data, width, allowance)
  local lines = { "## Usage", "" }
  if not data.available then
    lines[#lines + 1] = "Live usage unavailable for this thread."
    return lines
  end
  local usage = data.usage
  if usage.model ~= "" then lines[#lines + 1] = "Model: " .. usage.model end
  lines[#lines + 1] = "### Context"
  local context = usage.context
  local percent = context.percentage
  if context.used_tokens and context.total_tokens and context.total_tokens > 0 then
    percent = context.used_tokens / context.total_tokens * 100
  end
  if percent then
    lines[#lines + 1] = string.format("%s %.1f%% left", bar(percent, width), math.max(0, 100 - percent))
    lines[#lines + 1] = string.format("%.1f%% used · %s / %s tokens", percent,
      tokens(context.used_tokens), tokens(context.total_tokens))
  elseif context.used_tokens then
    lines[#lines + 1] = tokens(context.used_tokens) .. " tokens used · context capacity unavailable"
  else lines[#lines + 1] = "Context usage unavailable." end
  for _, section in ipairs({ { "Latest turn", usage.turn }, { "Session total", usage.cumulative } }) do
    lines[#lines + 1] = ""; lines[#lines + 1] = "### " .. section[1]
    local stats = section[2]
    lines[#lines + 1] = "Input: " .. tokens(stats.prompt_tokens) .. " · Output: " .. tokens(stats.completion_tokens)
      .. " · Total: " .. tokens(stats.total_tokens)
  end
  if usage.cost then
    lines[#lines + 1] = string.format("Reported cost: %.4f %s", usage.cost, usage.currency)
  end
  lines[#lines + 1] = ""; lines[#lines + 1] = "### Provider limits"
  if usage.provider ~= "" then lines[#lines + 1] = usage.provider end
  allowance = allowance or {}
  if allowance.windows then
    if allowance.status ~= "ready" then lines[#lines + 1] = "Last known limits · stale (" .. allowance.status .. ")" end
    for _, window in ipairs(allowance.windows) do
      lines[#lines + 1] = ""; lines[#lines + 1] = window.label
      lines[#lines + 1] = string.format("%s %.1f%% left · %.1f%% used", bar(window.used, width), math.max(0, 100 - window.used), window.used)
      if window.resets_at then
        local reset = require("lazyagent.acp.account_usage").reset_time(window.resets_at)
        lines[#lines + 1] = "Resets: " .. (reset and os.date("%Y-%m-%d %H:%M", reset) or window.resets_at)
      end
    end
    if #allowance.windows == 0 then lines[#lines + 1] = "No subscription limits reported for this account." end
    if allowance.reported_at then lines[#lines + 1] = "Limits reported: " .. os.date("%Y-%m-%d %H:%M:%S", allowance.reported_at) end
  else
    lines[#lines + 1] = "Weekly / model-specific allowance: " .. (allowance.status or "unavailable") .. "."
  end
  if usage.updated_at then lines[#lines + 1] = "Last reported: " .. os.date("%Y-%m-%d %H:%M:%S", usage.updated_at) end
  return lines
end

return M

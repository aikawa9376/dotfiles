local M = {}
local LIMIT = 8
local terminal = { completed = true, failed = true, cancelled = true, canceled = true, stopped = true }
local active = { running = true, in_progress = true, pending = true, working = true, thinking = true, waiting = true, blocked = true }

local function text(value)
  if type(value) ~= "string" and type(value) ~= "number" then return "" end
  return vim.fn.strcharpart(vim.trim(tostring(value):gsub("[%c%s]+", " ")), 0, 240)
end

-- Runtime-only receipt time; this never writes the thread manifest or saves content.
function M.record(session, kind, parent)
  local activity = session.cockpit_activity or {}
  if kind ~= "prompt" then activity.received_at = os.time() end
  if parent ~= false then
    if kind == "agent_message_chunk" then activity.phase = "responding"
    elseif kind == "agent_thought_chunk" then activity.phase = "thinking"
    elseif kind == "prompt" or kind == "tool_call" or kind == "tool_call_update" then activity.phase = "working"
    end
  end
  session.cockpit_activity = activity
end

local function entries(source, tool)
  local result, counts = {}, { active = 0, completed = 0, failed = 0, unknown = 0, total = 0 }
  for id, item in pairs(source or {}) do
    if type(item) == "table" then
      local state = text(tool and item.status or item.state):lower()
      counts.total = counts.total + 1
      if terminal[state] then
        if state == "failed" then counts.failed = counts.failed + 1 else counts.completed = counts.completed + 1 end
      elseif active[state] then counts.active = counts.active + 1
      else counts.unknown = counts.unknown + 1 end
      if not tool or not terminal[state] then
        result[#result + 1] = { id = tostring(id), state = state ~= "" and state or "unknown",
          title = text(item.title or item.name or item.description or id), kind = text(item.kind or item.taskType),
          subagent_id = tool and ((item._meta or {}).lazyagent or {}).subagentSessionId or nil,
          detail = not tool and text(item.summary or item.description or item.task) or nil,
          last_tool = not tool and text(item.lastToolName) or nil }
      end
    end
  end
  table.sort(result, function(a, b)
    local a_active, b_active = active[a.state] == true, active[b.state] == true
    if a_active ~= b_active then return a_active end
    return a.id < b.id
  end)
  return vim.list_slice(result, 1, LIMIT), counts
end

-- Compact projection: tool names/statuses only, never raw input/output or timelines.
function M.snapshot(session)
  local current = session.cockpit_activity or {}
  local tools, tool_counts = entries(session.tool_calls, true)
  for _, tool in ipairs(tools) do
    if tool.subagent_id then
      local child = (session.subagents or {})[tool.subagent_id] or {}
      tool.title = "Subagent " .. text(child.name or tool.subagent_id) .. " · " .. tool.title
    end
  end
  local children, child_counts = entries(session.subagents)
  local tasks, task_counts = entries(session.async_tasks)
  local plan = { completed = 0, total = 0 }
  local plan_entries = {}
  local raw_plan = session.current_plan or {}
  for _, entry in ipairs(raw_plan.entries or raw_plan) do
    plan.total = plan.total + 1
    if entry.status == "completed" then plan.completed = plan.completed + 1 end
    plan_entries[#plan_entries + 1] = { text(entry.status), text(entry.content or entry.text or entry.title) }
  end
  plan.revision = vim.fn.sha256(vim.json.encode(plan_entries))
  local result = {
    phase = current.phase, received_at = current.received_at,
    tools = tools, tool_counts = tool_counts, children = children, child_counts = child_counts,
    tasks = tasks, task_counts = task_counts, plan = plan,
    busy = session.busy == true, preparing = session.preparing_prompt == true,
    ready = session.ready == true, failed = session.failed == true,
  }
  local signature = vim.deepcopy(result)
  local goal = session.goal
  signature.goal = text(type(goal) == "table" and (goal.title or goal.objective or goal.text) or goal)
  local failure = session.active_session_failure or {}
  signature.failure = { failure.id or "", failure.revision or "" }
  signature.received_at = nil -- Repeated streaming chunks must not rebuild the entire list.
  result.signature = vim.fn.sha256(vim.json.encode(signature))
  return result
end

function M.summarize(runtime)
  if not runtime then return { label = "Live activity unavailable", available = false } end
  local data = runtime.acp_activity or M.snapshot({ subagents = runtime.acp_subagents, async_tasks = runtime.acp_async_tasks,
    current_plan = runtime.acp_plan })
  local tools = data.tools or {}
  local result = { available = true, data = data }
  local requests = runtime.acp_ui_requests or {}
  local request = requests.active or (requests.pending or {})[1]
  if request then
    local labels = { permission = "Approval", elicitation = "Question", authentication = "Authentication", auth = "Authentication" }
    result.label = (requests.active and "Waiting for " or "Queued for ") .. (labels[request.kind] or "input")
      .. ": " .. text(request.label or request.kind)
    result.waiting = true
  elseif runtime.acp_pending_permission or (tonumber((runtime.acp_client_debug or {}).pending_permissions) or 0) > 0 then
    result.label = "Waiting for approval: " .. text((runtime.acp_pending_permission or {}).title or "Permission required")
    result.waiting = true
  elseif runtime.acp_failed or (runtime.acp_active_session_failure or {}).severity == "error" then result.label = "Session error"
  elseif runtime.acp_preparing_prompt then result.label = "Preparing prompt"
  elseif #tools > 0 then
    result.label = (tools[1].state == "pending" and "Tool pending: " or "Tool: ") .. tools[1].title
    local tool_count = math.max(#tools, ((data.tool_counts or {}).active or 0) + ((data.tool_counts or {}).unknown or 0))
    if tool_count > 1 then
      result.label = result.label .. " (+" .. (tool_count - 1) .. ")"
    end
  elseif runtime.agent_status == "waiting" then result.label, result.waiting = "Waiting · reason unavailable", true
  elseif runtime.acp_busy or runtime.agent_status == "thinking" then
    result.label = data.phase == "thinking" and "Thinking" or data.phase == "responding" and "Responding"
      or data.phase == "working" and "Working" or "Working · activity unavailable"
  elseif runtime.acp_ready then result.label = "Idle"
  else result.label = "Connecting · activity unavailable" end
  return result
end

return M

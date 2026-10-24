local M = {}
function M.run()
  local Activity = require("lazyagent.acp.cockpit_activity")
  local Cockpit = require("lazyagent.acp.cockpit")
  local Details = require("lazyagent.acp.cockpit_details")
  local session = { busy = true, ready = true, tool_calls = {}, subagents = {}, async_tasks = {},
    current_plan = { entries = { { status = "completed" }, { status = "in_progress" }, { status = "pending" } } } }
  Activity.record(session, "agent_thought_chunk")
  local data = Activity.snapshot(session)
  assert(data.phase == "thinking" and type(data.received_at) == "number", "runtime records receipt and parent phase")
  local signature = data.signature
  session.cockpit_activity.received_at = data.received_at + 100
  assert(Activity.snapshot(session).signature == signature, "stream receipt time does not invalidate list")
  local received_at = session.cockpit_activity.received_at
  Activity.record(session, "prompt")
  assert(session.cockpit_activity.received_at == received_at, "outgoing prompt does not claim provider receipt")
  Activity.record(session, "agent_thought_chunk")
  Activity.record(session, "agent_message_chunk", false)
  assert(Activity.snapshot(session).phase == "thinking", "child output does not become parent response phase")
  session.tool_calls = {
    b = { title = "Run tests\nfor parser", status = "in_progress", kind = "execute", rawOutput = "SECRET OUTPUT" },
    c = { title = "Finished old tool", status = "completed" },
    a = { title = "Read source", status = "pending" },
  }
  session.subagents = { one = { name = "Reviewer", state = "running" }, two = { name = "Old agent", state = "completed" },
    three = { name = "Unknown", state = "future_state" } }
  session.async_tasks = { test = { name = "Checks", state = "running" }, error = { name = "Old test", state = "failed" } }
  data = Activity.snapshot(session)
  assert(#data.tools == 2 and data.tools[1].id == "a", "active tools are deterministic and terminal tools excluded")
  assert(not vim.json.encode(data):find("SECRET", 1, true), "compact projection excludes tool output")
  assert(data.child_counts.active == 1 and data.child_counts.unknown == 1 and data.child_counts.completed == 1,
    "unknown child states are not assumed active or successful")
  session.tool_calls.b._meta = { lazyagent = { subagentSessionId = "one" } }
  assert(Activity.snapshot(session).tools[2].title:find("Subagent Reviewer", 1, true), "child tools retain their source")
  data = Activity.snapshot(session)
  session.current_plan.entries[2].content = "Different current step"
  assert(Activity.snapshot(session).signature ~= data.signature, "plan content changes refresh even with unchanged counts")
  local runtime = { acp_busy = true, acp_ready = true, acp_activity = data }
  assert(Activity.summarize(runtime).label == "Tool pending: Read source (+1)", "tool activity with concurrent count")
  runtime.acp_ui_requests = { pending = { { kind = "elicitation", label = "Choose API" } } }
  assert(Activity.summarize(runtime).label == "Queued for Question: Choose API", "FIFO queued input is distinguished")
  runtime.acp_ui_requests = { active = { kind = "permission", label = "Write file" } }
  assert(Activity.summarize(runtime).label == "Waiting for Approval: Write file", "human input outranks executing tool")
  runtime.acp_ui_requests = nil
  runtime.acp_pending_permission = { title = "Use terminal" }
  assert(Activity.summarize(runtime).waiting, "permission fallback indicates input wait")
  runtime.acp_pending_permission = nil
  runtime.acp_preparing_prompt = true
  assert(Activity.summarize(runtime).label == "Preparing prompt", "prompt preparation is explicit")
  runtime.acp_preparing_prompt = nil
  session.tool_calls = {}
  runtime.acp_activity = Activity.snapshot(session)
  local result = Activity.summarize(runtime)
  assert(result.label == "Thinking" and not result.waiting, "running children do not imply a parent wait")
  runtime.agent_status = "waiting"
  assert(Activity.summarize(runtime).label == "Waiting · reason unavailable", "missing wait reason stays unknown")
  runtime.agent_status = nil
  local thread = { thread_id = "activity-thread", title = "Implement parser", cwd = "/tmp/activity", status = "active", provider_id = "Codex" }
  local lines = table.concat(Details.render(thread, runtime, "overview"), "\n")
  assert(lines:find("Last received:", 1, true) and lines:find("Plan: 1/3 items completed", 1, true), "overview shows receipt and item counts")
  assert(lines:find("Reviewer", 1, true) and lines:find("Old test", 1, true), "children and background task states remain visible")
  assert(#Cockpit.filter({ thread }, "thinking", { [thread.thread_id] = runtime }) == 1, "activity is searchable")
  local rendered, map = Cockpit.render({ thread }, { [thread.thread_id] = runtime }, { width = 200 })
  for row in pairs(map) do assert(rendered[row]:find("activity:Thinking", 1, true), "card separates activity from prompt title") end
  local narrow, narrow_map = Cockpit.render({ thread }, { [thread.thread_id] = runtime }, { width = 40 })
  for row in pairs(narrow_map) do assert(vim.fn.strdisplaywidth(narrow[row]) <= 40, "activity honors card width") end
  assert(not Activity.summarize(nil).available, "no runtime does not invent current activity from history")
  for index = 1, 20 do session.tool_calls[tostring(index)] = { title = "Tool " .. index, status = "in_progress" } end
  data = Activity.snapshot(session)
  assert(#data.tools == 8 and data.tool_counts.active == 20, "compact projection bounds rows while preserving counts")
  local unavailable = table.concat(Details.render(thread, nil, "overview"), "\n")
  assert(unavailable:find("Live activity unavailable", 1, true) and unavailable:find("Last received: unknown", 1, true),
    "historical details do not label saved work as current")
end
return M

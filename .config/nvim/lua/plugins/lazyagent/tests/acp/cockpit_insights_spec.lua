local M = {}
function M.run()
  local Insights = require("lazyagent.acp.cockpit_insights")
  local Details = require("lazyagent.acp.cockpit_details")
  local Timeline = require("lazyagent.acp.task_timeline")
  local params = { title = "Ship task tree", tasks = {
    { id = "small", title = "Small step", status = "completed", weight = 1 },
    { id = "large", title = "Large step", status = "in_progress", weight = 3 },
    { id = "child", parent_id = "large", title = "Nested step", status = "pending" },
  } }
  local saved = assert(Timeline.validate(params, "insights-thread"))
  local runtime = { acp_plan = saved.tasks, acp_goal = params.title,
    acp_subagents = { reviewer = { name = "Reviewer", state = "failed", current_plan = {
      { content = "Review source", status = "completed" }, { content = "Review tests", status = "blocked" },
    } } },
    acp_async_tasks = { checks = { name = "Checks", state = "cancelled", rawOutput = "SECRET" } },
    acp_usage_stats = { context = { used_tokens = 45000, total_tokens = 100000 },
      turn = { prompt_tokens = 40, completion_tokens = 60, total_tokens = 100 },
      cumulative = { total_tokens = 1000 }, cost = { amount = 0.5, currency = "USD" } },
  }
  local data = Insights.snapshot(runtime)
  local done, total, percent = Insights.progress(data.plan)
  assert(done == 1 and total == 2 and percent == 25, "sibling weights preserve the larger task's share")
  params.tasks[#params.tasks + 1] = { id = "child-2", parent_id = "large", title = "Another nested step", status = "pending" }
  runtime.acp_plan = assert(Timeline.validate(params, "insights-thread")).tasks
  data = Insights.snapshot(runtime)
  local _, _, split_percent = Insights.progress(data.plan)
  assert(split_percent == 25, "splitting an incomplete task does not change its parent's contribution")
  local text = table.concat(Insights.timeline(data, 60), "\n")
  assert(text:find("25.0%%") and text:find("Reviewer", 1, true) and text:find("[cancelled]", 1, true), "hierarchy and non-success task states remain visible")
  assert(not vim.json.encode(data):find("SECRET", 1, true), "insights exclude raw task/tool output")
  local usage = table.concat(Insights.usage(data, 60, { status = "ready", windows = {
    { label = "Week", used = 49, resets_at = "2026-11-20" },
  } }), "\n")
  assert(usage:find("55.0% left", 1, true) and usage:find("51.0% left", 1, true), "context and weekly quota stay distinct")
  assert(usage:find("0.5000 USD", 1, true) and usage:find("unavailable", 1, true), "reported cost and missing counters")
  local thread = { thread_id = "insights-thread", provider_id = "Fixture", title = "Fixture", metadata = { cockpit_timeline = saved } }
  text = table.concat(Details.render(thread, nil, "timeline"), "\n")
  assert(text:find("25.0%", 1, true) and text:find("Recorded:", 1, true), "persisted timeline works without a running agent")
  assert(Details.tabs("usage"):find("**[Usage]**", 1, true), "active tab is explicit")
  assert(table.concat(Details.render(thread, nil, "usage"), "\n"):find("Live usage unavailable", 1, true), "history cannot claim live usage")
  params.tasks[3].parent_id = "child"
  assert(not Timeline.validate(params, "insights-thread"), "cycles are rejected")
  params.tasks[3].parent_id = "missing"
  assert(not Timeline.validate(params, "insights-thread"), "missing parents are rejected")
  params.tasks[3].parent_id = "large"; params.tasks[1].weight = 0
  assert(not Timeline.validate(params, "insights-thread"), "zero weight is rejected")
  assert(not Timeline.report(params, {}, { sessions = {} }), "unscoped calls cannot mutate a timeline")
  local called
  local result = Timeline.report({ title = "Mine", tasks = {} }, { headers = { ["x-lazyagent-thread-id"] = "mine" } }, {
    sessions = { fixture = { thread_id = "mine", backend = "fixture" } }, backends = { fixture = {
      update_timeline = function(id) called = id; return { revision = 1 } end,
    } },
  })
  assert(result.revision == 1 and called == "mine", "MCP updates only the caller's exact live thread")
  local cycle = { content = "Cyclic provider data", status = "pending" }; cycle.children = { cycle }
  data = Insights.snapshot({ acp_plan = { cycle } })
  assert(data.truncated, "malformed provider cycles are bounded")
  local many = {}; for index = 1, 205 do many[index] = { content = "Task " .. index, status = "pending" } end
  data = Insights.snapshot({ acp_plan = many })
  assert(#data.plan == 200 and data.truncated, "large provider plans are bounded and visibly truncated")
end
return M

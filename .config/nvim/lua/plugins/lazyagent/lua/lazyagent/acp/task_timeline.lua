local M = {}
local states = { pending = true, in_progress = true, completed = true, blocked = true, failed = true, cancelled = true }

-- A complete, bounded snapshot. Parent IDs are local to this thread, never agent refs.
function M.validate(params, thread_id, previous)
  if type(params.tasks) ~= "table" or not vim.islist(params.tasks) or #params.tasks > 200 then
    return nil, "tasks must be an array of at most 200 tasks"
  end
  if type(params.title) ~= "string" or #params.title == 0 or #params.title > 500 then
    return nil, "title must contain 1–500 bytes"
  end
  local tasks, ids = {}, {}
  for _, task in ipairs(params.tasks) do
    if type(task) ~= "table" or type(task.id) ~= "string" or #task.id == 0 or #task.id > 100 or ids[task.id] then
      return nil, "task IDs must be unique nonempty strings (at most 100 bytes)"
    end
    if type(task.title) ~= "string" or #task.title == 0 or #task.title > 500 then return nil, "invalid task title" end
    local weight = task.weight == nil and 1 or task.weight
    if type(weight) ~= "number" or weight ~= weight or weight <= 0 or weight > 1000000 then
      return nil, "weights must be positive finite numbers at most 1000000"
    end
    local status = task.status or "pending"
    if not states[status] then return nil, "invalid task status" end
    if task.parent_id ~= nil and type(task.parent_id) ~= "string" then return nil, "invalid parent_id" end
    if task.note ~= nil and (type(task.note) ~= "string" or #task.note > 2000) then return nil, "invalid task note" end
    local saved = { id = task.id, parent_id = task.parent_id, title = task.title,
      status = status, weight = weight, note = task.note }
    tasks[#tasks + 1], ids[task.id] = saved, saved
  end
  for _, task in ipairs(tasks) do
    local seen, current, depth = {}, task, 0
    while current do
      depth = depth + 1
      if seen[current.id] or depth > 12 then return nil, "task hierarchy is cyclic or exceeds 12 levels" end
      seen[current.id] = true
      if current.parent_id and not ids[current.parent_id] then return nil, "task parent does not exist" end
      current = current.parent_id and ids[current.parent_id] or nil
    end
  end
  return { schema_version = 1, thread_id = thread_id, title = params.title, tasks = tasks,
    revision = ((previous or {}).revision or 0) + 1, updated_at = os.time(),
    started_at = (previous or {}).started_at or os.time() }
end

function M.report(params, context, runtime_state)
  local headers = type(context) == "table" and context.headers or {}
  local thread_id = headers["x-lazyagent-thread-id"]
  if type(thread_id) ~= "string" or thread_id == "" then return nil, "timeline requires an ACP thread-scoped MCP connection" end
  for key, session in pairs(runtime_state.sessions or {}) do
    local backend = runtime_state.backends and runtime_state.backends[session.backend]
    local id = require("lazyagent.logic.session.identity").thread_id(key, session) or session.acp_thread_id
    if id == thread_id and backend and type(backend.update_timeline) == "function" then
      return backend.update_timeline(thread_id, params)
    end
  end
  return nil, "calling ACP thread is no longer local and live"
end

return M

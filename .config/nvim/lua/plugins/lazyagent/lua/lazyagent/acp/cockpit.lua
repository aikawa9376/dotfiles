local M = {}

local function changed_file_count(thread)
  local seen = {}
  for _, turn in ipairs(thread.change_journal and thread.change_journal.turns or {}) do
    for _, change in ipairs(turn.changes or {}) do
      local path = change.path or change.new_path or change.old_path
      if path and path ~= "" then seen[path] = true end
    end
  end
  return vim.tbl_count(seen)
end

local function latest_paths(thread)
  local turns = thread.change_journal and thread.change_journal.turns or {}
  local turn = turns[#turns]
  local paths = {}
  for _, change in ipairs(turn and turn.changes or {}) do
    local path = change.path or change.new_path or change.old_path
    if path and path ~= "" then paths[path] = true end
  end
  return paths
end

function M.conflicts(threads)
  local result = {}
  for left_index, left in ipairs(threads or {}) do
    if left.status == "active" then
      local left_paths = latest_paths(left)
      for right_index = left_index + 1, #(threads or {}) do
        local right = threads[right_index]
        if right.status == "active" and left.cwd == right.cwd then
          for path in pairs(latest_paths(right)) do
            if left_paths[path] then
              result[left.thread_id] = result[left.thread_id] or {}
              result[right.thread_id] = result[right.thread_id] or {}
              result[left.thread_id][path] = true
              result[right.thread_id][path] = true
            end
          end
        end
      end
    end
  end
  return result
end

local function group_path(thread)
  local metadata = type(thread.metadata) == "table" and thread.metadata or {}
  return metadata.worktree_path or thread.cwd or "(unknown workspace)"
end

local function common_status(thread, runtime)
  if runtime then
    if runtime.acp_failed == true then return "disconnected" end
    if runtime.acp_client_debug and (tonumber(runtime.acp_client_debug.pending_permissions) or 0) > 0 then return "permission" end
    if runtime.agent_status == "waiting" then return "waiting" end
    if runtime.acp_busy == true or runtime.acp_preparing_prompt == true or runtime.agent_status == "thinking" then
      return "running"
    end
    if runtime.acp_ready == true then return "idle" end
  end
  local agentmux_state = thread.metadata and thread.metadata.agentmux and thread.metadata.agentmux.state
  if agentmux_state == "working" then return "running" end
  if agentmux_state == "blocked" then return "waiting" end
  if agentmux_state == "idle" then return "idle" end
  if thread.status == "active" and thread.process_id ~= nil then return "disconnected" end
  return thread.status or "closed"
end

local function usage_label(runtime)
  local usage = runtime and runtime.acp_usage_stats or {}
  local cumulative = type(usage.cumulative) == "table" and usage.cumulative or {}
  local context = type(usage.context) == "table" and usage.context or {}
  local tokens = cumulative.total_tokens or cumulative.totalTokens or context.used_tokens or context.usedTokens
  local cost = cumulative.cost or cumulative.total_cost or usage.cost or usage.total_cost
  local parts = {}
  if tokens then parts[#parts + 1] = tostring(tokens) .. "tok" end
  if cost then parts[#parts + 1] = "$" .. string.format("%.4f", tonumber(cost) or 0) end
  return #parts > 0 and table.concat(parts, "/") or "n/a"
end

function M.render(threads, runtimes)
  runtimes = runtimes or {}
  local conflicts = M.conflicts(threads)
  local groups = {}
  for _, thread in ipairs(threads or {}) do
    local path = group_path(thread)
    groups[path] = groups[path] or {}
    groups[path][#groups[path] + 1] = thread
  end
  local paths = vim.tbl_keys(groups)
  table.sort(paths)

  local lines = {
    "# LazyAgent ACP Session Cockpit",
    "",
    "`<CR>` open  `/` filter  `p` pin  `t` test  `a` archive/restore  `c` cleanup worktree  `d` delete  `X` bulk close  `r` refresh  `q` close",
  }
  local line_map = {}
  if #paths == 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "_No persisted ACP threads._"
    return lines, line_map
  end

  for _, path in ipairs(paths) do
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## " .. vim.fn.fnamemodify(path, ":~")
    table.sort(groups[path], function(left, right)
      local left_pinned = left.metadata and left.metadata.cockpit_pinned == true
      local right_pinned = right.metadata and right.metadata.cockpit_pinned == true
      if left_pinned ~= right_pinned then return left_pinned end
      if left.updated_at == right.updated_at then return left.thread_id < right.thread_id end
      return tostring(left.updated_at or "") > tostring(right.updated_at or "")
    end)
    for _, thread in ipairs(groups[path]) do
      local runtime = runtimes[thread.thread_id]
      local unread = thread.unread == true and "unread" or "read"
      local runtime_model = runtime and runtime.acp_model_catalog and runtime.acp_model_catalog.currentModelId
      local model = runtime_model or (thread.model and thread.model ~= "" and thread.model) or "default"
      local changes = changed_file_count(thread)
      local pin = thread.metadata and thread.metadata.cockpit_pinned == true and "★ " or ""
      local conflict_count = vim.tbl_count(conflicts[thread.thread_id] or {})
      local conflict = conflict_count > 0 and (" · ⚠conflicts:" .. tostring(conflict_count)) or ""
      local test = thread.metadata and thread.metadata.test_result or nil
      local test_label = test and (" · test:" .. tostring(test.status)) or ""
      lines[#lines + 1] = string.format(
        "- %s[%s] %s · %s · model:%s · %s · usage:%s · changes:%d%s",
        pin,
        common_status(thread, runtime),
        tostring(thread.title or thread.thread_id),
        tostring(thread.provider_id or "provider"),
        tostring(model),
        unread,
        usage_label(runtime),
        changes,
        conflict .. test_label
      )
      line_map[#lines] = thread.thread_id
    end
  end
  return lines, line_map
end

function M.filter(threads, query)
  query = vim.trim(tostring(query or "")):lower()
  if query == "" then return vim.deepcopy(threads or {}) end
  return vim.tbl_filter(function(thread)
    local text = table.concat({
      thread.title or "", thread.provider_id or "", thread.cwd or "", thread.status or "",
      thread.model or "", thread.unread == true and "unread" or "read",
    }, " "):lower()
    return text:find(query, 1, true) ~= nil
  end, threads or {})
end

return M

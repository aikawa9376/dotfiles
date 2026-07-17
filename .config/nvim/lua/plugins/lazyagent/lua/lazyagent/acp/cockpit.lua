local M = {}

local highlight_ns = vim.api.nvim_create_namespace("LazyAgentACPCockpit")

local function display_width(text)
  local ok, width = pcall(vim.fn.strdisplaywidth, text)
  return ok and width or #text
end

local function truncate_display(text, max_width)
  text = tostring(text or ""):gsub("%s+", " ")
  text = vim.trim(text)
  if display_width(text) <= max_width then return text end
  if max_width <= 1 then return "…" end
  local result = ""
  local chars = vim.fn.strchars(text)
  for index = 0, chars - 1 do
    local char = vim.fn.strcharpart(text, index, 1)
    if display_width(result .. char .. "…") > max_width then break end
    result = result .. char
  end
  return result .. "…"
end

local function add_segment(parts, spans, text, group)
  local start_col = #table.concat(parts)
  parts[#parts + 1] = text
  if group and text ~= "" then
    spans[#spans + 1] = { start_col = start_col, end_col = start_col + #text, group = group }
  end
end

local status_highlights = {
  running = "LazyAgentACPCockpitStatusRunning",
  permission = "LazyAgentACPCockpitStatusPermission",
  waiting = "LazyAgentACPCockpitStatusWaiting",
  idle = "LazyAgentACPCockpitStatusIdle",
  disconnected = "LazyAgentACPCockpitStatusDisconnected",
  failed = "LazyAgentACPCockpitStatusDisconnected",
  closed = "LazyAgentACPCockpitStatusClosed",
  archived = "LazyAgentACPCockpitStatusArchived",
}

local function setup_highlights()
  local definitions = {
    LazyAgentACPCockpitTitle = { default = true, link = "Title" },
    LazyAgentACPCockpitHelp = { default = true, link = "Comment" },
    LazyAgentACPCockpitWorkspace = { default = true, link = "Directory" },
    LazyAgentACPCockpitPrompt = { default = true, link = "String" },
    LazyAgentACPCockpitProvider = { default = true, link = "Type" },
    LazyAgentACPCockpitModel = { default = true, link = "Identifier" },
    LazyAgentACPCockpitMuted = { default = true, link = "Comment" },
    LazyAgentACPCockpitUnread = { default = true, link = "DiagnosticWarn" },
    LazyAgentACPCockpitChanges = { default = true, link = "Special" },
    LazyAgentACPCockpitConflict = { default = true, link = "DiagnosticError" },
    LazyAgentACPCockpitTestRunning = { default = true, link = "DiagnosticWarn" },
    LazyAgentACPCockpitTestPassed = { default = true, link = "DiagnosticOk" },
    LazyAgentACPCockpitTestFailed = { default = true, link = "DiagnosticError" },
    LazyAgentACPCockpitPin = { default = true, link = "DiagnosticWarn" },
    LazyAgentACPCockpitStatusRunning = { default = true, link = "DiagnosticInfo" },
    LazyAgentACPCockpitStatusPermission = { default = true, link = "DiagnosticWarn" },
    LazyAgentACPCockpitStatusWaiting = { default = true, link = "DiagnosticWarn" },
    LazyAgentACPCockpitStatusIdle = { default = true, link = "DiagnosticOk" },
    LazyAgentACPCockpitStatusDisconnected = { default = true, link = "DiagnosticError" },
    LazyAgentACPCockpitStatusClosed = { default = true, link = "Comment" },
    LazyAgentACPCockpitStatusArchived = { default = true, link = "NonText" },
  }
  for name, definition in pairs(definitions) do
    pcall(vim.api.nvim_set_hl, 0, name, definition)
  end
end

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

local function card_line(thread, runtime, conflicts, max_width)
  local status = common_status(thread, runtime)
  local runtime_model = runtime and runtime.acp_model_catalog and runtime.acp_model_catalog.currentModelId
  local model = runtime_model or (thread.model and thread.model ~= "" and thread.model) or "default"
  local changes = changed_file_count(thread)
  local pinned = thread.metadata and thread.metadata.cockpit_pinned == true
  local conflict_count = vim.tbl_count(conflicts[thread.thread_id] or {})
  local test = thread.metadata and thread.metadata.test_result or nil
  local provider = tostring(thread.provider_id or "provider")

  local fields = {}
  if model ~= "default" then fields[#fields + 1] = { "model:" .. tostring(model), "LazyAgentACPCockpitModel", "model" } end
  if thread.unread == true then fields[#fields + 1] = { "unread", "LazyAgentACPCockpitUnread", "unread" } end
  local usage = usage_label(runtime)
  if usage ~= "n/a" then fields[#fields + 1] = { "usage:" .. usage, "LazyAgentACPCockpitMuted", "usage" } end
  if changes > 0 then fields[#fields + 1] = { "changes:" .. tostring(changes), "LazyAgentACPCockpitChanges", "changes" } end
  if conflict_count > 0 then
    fields[#fields + 1] = { "⚠conflicts:" .. tostring(conflict_count), "LazyAgentACPCockpitConflict", "conflict" }
  end
  if test then
    local test_status = tostring(test.status)
    local test_group = test_status == "passed" and "LazyAgentACPCockpitTestPassed"
      or test_status == "failed" and "LazyAgentACPCockpitTestFailed"
      or "LazyAgentACPCockpitTestRunning"
    fields[#fields + 1] = { "test:" .. test_status, test_group, "test" }
  end

  local function fixed_width()
    local width = display_width("- " .. (pinned and "★ " or "") .. "[" .. status .. "]  · " .. provider)
    for _, field in ipairs(fields) do width = width + display_width(" · " .. field[1]) end
    return width
  end

  local removal_order = { "usage", "model", "changes", "test", "unread", "conflict" }
  while max_width and max_width - fixed_width() < 12 do
    local removed = false
    for _, kind in ipairs(removal_order) do
      for index = #fields, 1, -1 do
        if fields[index][3] == kind then
          table.remove(fields, index)
          removed = true
          break
        end
      end
      if removed then break end
    end
    if not removed then break end
  end

  local title_width = max_width and math.max(8, max_width - fixed_width()) or 80
  local title = truncate_display(thread.title or thread.thread_id, title_width)
  local parts, spans = {}, {}
  add_segment(parts, spans, "- ", "LazyAgentACPCockpitMuted")
  if pinned then add_segment(parts, spans, "★ ", "LazyAgentACPCockpitPin") end
  add_segment(parts, spans, "[" .. status .. "]", status_highlights[status] or "LazyAgentACPCockpitMuted")
  add_segment(parts, spans, " ")
  add_segment(parts, spans, title, "LazyAgentACPCockpitPrompt")
  add_segment(parts, spans, " · ", "LazyAgentACPCockpitMuted")
  add_segment(parts, spans, provider, "LazyAgentACPCockpitProvider")
  for _, field in ipairs(fields) do
    add_segment(parts, spans, " · ", "LazyAgentACPCockpitMuted")
    add_segment(parts, spans, field[1], field[2])
  end
  return table.concat(parts), spans
end

function M.render(threads, runtimes, opts)
  runtimes = runtimes or {}
  opts = opts or {}
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
    "persisted threads: running = live process, closed = resumable history, archived = retained history",
    "`<CR>` open  `x` stop  `/` filter  `p` pin  `t` test  `a` archive/restore  `c` cleanup  `d` delete  `X` stop all  `r` refresh  `q` close",
  }
  local line_map = {}
  local highlights = {
    [1] = { { start_col = 0, end_col = #lines[1], group = "LazyAgentACPCockpitTitle" } },
    [3] = { { start_col = 0, end_col = #lines[3], group = "LazyAgentACPCockpitHelp" } },
    [4] = { { start_col = 0, end_col = #lines[4], group = "LazyAgentACPCockpitHelp" } },
  }
  if #paths == 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "_No persisted ACP threads._"
    return lines, line_map, highlights
  end

  for _, path in ipairs(paths) do
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## " .. vim.fn.fnamemodify(path, ":~")
    highlights[#lines] = { { start_col = 0, end_col = #lines[#lines], group = "LazyAgentACPCockpitWorkspace" } }
    table.sort(groups[path], function(left, right)
      local left_pinned = left.metadata and left.metadata.cockpit_pinned == true
      local right_pinned = right.metadata and right.metadata.cockpit_pinned == true
      if left_pinned ~= right_pinned then return left_pinned end
      if left.updated_at == right.updated_at then return left.thread_id < right.thread_id end
      return tostring(left.updated_at or "") > tostring(right.updated_at or "")
    end)
    for _, thread in ipairs(groups[path]) do
      local runtime = runtimes[thread.thread_id]
      local line, spans = card_line(thread, runtime, conflicts, opts.width)
      lines[#lines + 1] = line
      line_map[#lines] = thread.thread_id
      highlights[#lines] = spans
    end
  end
  return lines, line_map, highlights
end

function M.apply_highlights(bufnr, highlights)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  setup_highlights()
  vim.api.nvim_buf_clear_namespace(bufnr, highlight_ns, 0, -1)
  for line, spans in pairs(highlights or {}) do
    for _, span in ipairs(spans) do
      pcall(vim.api.nvim_buf_set_extmark, bufnr, highlight_ns, line - 1, span.start_col, {
        end_col = span.end_col,
        hl_group = span.group,
      })
    end
  end
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

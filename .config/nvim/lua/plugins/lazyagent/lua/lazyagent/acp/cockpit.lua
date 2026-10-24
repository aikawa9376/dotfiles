local M = {}
local config_values = require("lazyagent.acp.config_values")
local Activity = require("lazyagent.acp.cockpit_activity")
local Query = require("lazyagent.acp.cockpit_query")
local process = require("lazyagent.acp.process")
local Attention = require("lazyagent.acp.cockpit_attention")
local WorktreeTest = require("lazyagent.acp.worktree_test")
local Review = require("lazyagent.acp.cockpit_review")

local highlight_ns = vim.api.nvim_create_namespace("LazyAgentACPCockpit")
local PROMPT_MAX_WIDTH = 48

function M.agent_ref(thread)
  local thread_id = thread and vim.trim(tostring(thread.thread_id or "")) or ""
  return thread_id ~= "" and ("agent:" .. thread_id) or nil
end

function M.normalize_preview_layout(layout)
  return layout == "horizontal" and "horizontal" or "split"
end

function M.preview_width(requested_width, cockpit_width)
  local requested = math.max(20, tonumber(requested_width) or 60)
  local available = math.max(1, tonumber(cockpit_width) or requested * 2 + 1)
  -- Keep the preview inside the cockpit's current allocation. This avoids
  -- stealing width from an ACP window that is already visible in the tab.
  local local_limit = math.max(1, math.floor((available - 1) / 2))
  return math.min(requested, local_limit)
end

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
  external = "LazyAgentACPCockpitStatusExternal",
  failed = "LazyAgentACPCockpitStatusDisconnected",
  closed = "LazyAgentACPCockpitStatusClosed",
  archived = "LazyAgentACPCockpitStatusArchived",
}

local context_labels = {
  native_load = "load",
  native_resume = "resume",
  local_carryover = "carryover",
  new = "new",
  none = "none",
}

local history_labels = {
  native_replay = "replay",
  local_snapshot = "local",
  unavailable = "unavailable",
}

function M.activation_summary(thread, runtime)
  local persisted = thread and thread.metadata and thread.metadata.activation or {}
  local active = runtime and runtime.acp_activation or {}
  local context = active.context_continuity or persisted.context_continuity
  local history = active.visible_history or persisted.visible_history
  return {
    phase = active.phase,
    context = context,
    history = history,
    context_label = context_labels[context],
    history_label = history_labels[history],
  }
end

function M.explicit_activation_actions(thread, runtime)
  if not thread or not thread.native_session_id or thread.native_session_id == "" or not runtime then return {} end
  local agent_caps = runtime.acp_agent_capabilities or {}
  local session_caps = runtime.acp_session_capabilities or {}
  local actions = {}
  if agent_caps.loadSession == true then
    actions[#actions + 1] = { mode = "load", label = "Load with history" }
  end
  if session_caps.resume == true or type(session_caps.resume) == "table" then
    actions[#actions + 1] = { mode = "resume", label = "Resume without replay" }
  end
  return actions
end

local function setup_highlights()
  local definitions = {
    LazyAgentACPCockpitTitle = { default = true, link = "Title" },
    LazyAgentACPCockpitHelp = { default = true, link = "Comment" },
    LazyAgentACPCockpitWorkspace = { default = true, link = "Directory" },
    LazyAgentACPCockpitPrompt = { default = true, link = "String" },
    LazyAgentACPCockpitProvider = { default = true, link = "Type" },
    LazyAgentACPCockpitModel = { default = true, link = "Identifier" },
    LazyAgentACPCockpitTeam = { default = true, link = "Special" },
    LazyAgentACPCockpitMuted = { default = true, link = "Comment" },
    LazyAgentACPCockpitUnread = { default = true, link = "DiagnosticWarn" },
    LazyAgentACPCockpitChanges = { default = true, link = "Special" },
    LazyAgentACPCockpitConflict = { default = true, link = "DiagnosticError" },
    LazyAgentACPCockpitTestRunning = { default = true, link = "DiagnosticWarn" },
    LazyAgentACPCockpitTestPassed = { default = true, link = "DiagnosticOk" },
    LazyAgentACPCockpitTestFailed = { default = true, link = "DiagnosticError" },
    LazyAgentACPCockpitPin = { default = true, link = "DiagnosticWarn" },
    LazyAgentACPCockpitActive = { default = true, link = "DiagnosticOk" },
    LazyAgentACPCockpitQueue = { default = true, link = "DiagnosticWarn" },
    LazyAgentACPCockpitStatusRunning = { default = true, link = "DiagnosticInfo" },
    LazyAgentACPCockpitStatusPermission = { default = true, link = "DiagnosticWarn" },
    LazyAgentACPCockpitStatusWaiting = { default = true, link = "DiagnosticWarn" },
    LazyAgentACPCockpitStatusIdle = { default = true, link = "DiagnosticOk" },
    LazyAgentACPCockpitStatusDisconnected = { default = true, link = "DiagnosticError" },
    LazyAgentACPCockpitStatusExternal = { default = true, link = "DiagnosticWarn" },
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

local function transcript_first_user_prompt(path)
  if not path or path == "" or vim.fn.filereadable(path) ~= 1 then return nil end
  local ok, lines = pcall(vim.fn.readfile, path, "", 2000)
  if not ok then return nil end
  local collecting = false
  local body = {}
  for _, line in ipairs(lines or {}) do
    if line:match("^─ .- User") or line:match("^#+%s+User") then
      collecting = true
    elseif collecting and (line:match("^─ ") or line:match("^#+%s+")) then
      break
    elseif collecting then
      local text = vim.trim(line)
      if text ~= "" then body[#body + 1] = text end
      if #body >= 20 then break end
    end
  end
  local prompt = vim.trim(table.concat(body, " "))
  return prompt ~= "" and prompt or nil
end

function M.prompt_title(thread)
  local title = vim.trim(tostring(thread and thread.title or "")):gsub("%s+", " ")
  local provider = vim.trim(tostring(thread and thread.provider_id or ""))
  if title ~= "" and title ~= provider and title ~= (thread and thread.thread_id) then return title end
  return transcript_first_user_prompt(thread and thread.transcript_path)
end

function M.has_meaningful_content(thread)
  if not thread then return false end
  if thread.status == "active" or thread.status == "failed" or thread.process_id ~= nil then return true end
  local metadata = type(thread.metadata) == "table" and thread.metadata or {}
  if metadata.has_user_prompt == true or metadata.imported_from_native == true then return true end
  if changed_file_count(thread) > 0 then return true end
  return M.prompt_title(thread) ~= nil
end

function M.prune_empty(backend, threads)
  local kept = {}
  local removed = 0
  for _, thread in ipairs(threads or {}) do
    if M.has_meaningful_content(thread) or not backend or type(backend.delete_thread) ~= "function" then
      kept[#kept + 1] = thread
    else
      local deleted = backend.delete_thread(thread.thread_id)
      if deleted == true then
        removed = removed + 1
        if thread.transcript_path and thread.transcript_path ~= "" then pcall(vim.fn.delete, thread.transcript_path) end
      else
        kept[#kept + 1] = thread
      end
    end
  end
  return kept, removed
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

local function process_info(pid, opts)
  local cache = opts.process_cache
  local key = tostring(pid)
  if cache and cache[key] then return cache[key] end
  local info = (opts.process_info or process.inspect)(pid)
  if cache then cache[key] = info end
  return info
end

function M.thread_status(thread, runtime, opts)
  opts = opts or {}
  if runtime then
    if runtime.acp_failed == true then
      local info = process_info(runtime.acp_process_id or thread.process_id, opts)
      return info.alive == false and "closed" or "disconnected"
    end
    if runtime.acp_client_debug and (tonumber(runtime.acp_client_debug.pending_permissions) or 0) > 0 then return "permission" end
    local requests = runtime.acp_ui_requests or {}
    if requests.active or #(requests.pending or {}) > 0 then return "waiting" end
    if runtime.agent_status == "waiting" then return "waiting" end
    if runtime.acp_busy == true or runtime.acp_preparing_prompt == true or runtime.agent_status == "thinking" then
      return "running"
    end
    if runtime.acp_ready == true then return "idle" end
  end
  if thread.status == "active" then
    local info = process_info(thread.process_id, opts)
    local metadata = type(thread.metadata) == "table" and thread.metadata or {}
    if info.alive == false
      or (type(metadata.process_identity) == "string" and info.identity
        and metadata.process_identity ~= info.identity)
    then
      return "closed"
    end
    local persisted_instance = metadata.editor and metadata.editor.instance_id
    local persisted_owner = metadata.editor and metadata.editor.owner_pid
      or metadata.agentmux and metadata.agentmux.owner_pid
    local foreign = persisted_instance and opts.owner_instance_id and persisted_instance ~= opts.owner_instance_id
      or not persisted_instance and opts.owner_pid and persisted_owner
        and tonumber(persisted_owner) ~= tonumber(opts.owner_pid)
    if foreign then
      return process_info(persisted_owner, opts).alive == true and "external" or "disconnected"
    end
    if opts.owner_pid and persisted_owner then
      return "disconnected"
    end
    local agentmux_state = thread.metadata and thread.metadata.agentmux and thread.metadata.agentmux.state
    if agentmux_state == "working" then return "running" end
    if agentmux_state == "blocked" then return "waiting" end
    if agentmux_state == "idle" then return "idle" end
    return "disconnected"
  end
  return thread.status or "closed"
end

local common_status = M.thread_status

function M.test_status(thread, opts)
  opts = opts or {}
  local result = thread.metadata and thread.metadata.test_result
  if result and result.status ~= "running" and opts.fingerprint_pending and opts.fingerprint_pending[thread.cwd] then
    return "checking"
  end
  local fingerprint = opts.fingerprints and opts.fingerprints[thread.cwd]
  return WorktreeTest.status(result, fingerprint)
end

function M.attention(thread, runtime, opts)
  opts = vim.tbl_extend("force", {}, opts or {})
  opts.status = common_status(thread, runtime, opts)
  opts.test_status = M.test_status(thread, opts)
  opts.review = M.review(thread, runtime, opts)
  opts.since = M.since(thread, opts)
  return Attention.summarize(thread, runtime, opts)
end

function M.review(thread, runtime, opts)
  opts = opts or {}
  if not Review.enabled(thread) then return { enabled = false, state = "off" } end
  local cache = opts.review_cache
  if cache and cache[thread.thread_id] then return cache[thread.thread_id] end
  local unowned_active = runtime == nil and thread.status == "active"
  runtime = runtime or {}
  local result = Review.summary(thread, {
    fingerprint = opts.fingerprints and opts.fingerprints[thread.cwd],
    fingerprint_pending = opts.fingerprint_pending and opts.fingerprint_pending[thread.cwd],
    busy = runtime.acp_busy or runtime.acp_preparing_prompt or unowned_active,
  })
  if cache then cache[thread.thread_id] = result end
  return result
end

function M.since(thread, opts)
  local cache = opts and opts.since_cache
  if cache and cache[thread.thread_id] then return cache[thread.thread_id] end
  local result = Review.since(thread)
  if cache then cache[thread.thread_id] = result end
  return result
end

function M.needs_attention(thread, runtime, opts)
  local attention = M.attention(thread, runtime, opts)
  return #attention.items > 0 and not attention.snoozed
end

local function live_thread(thread, runtime, opts)
  local status = common_status(thread, runtime, opts)
  return runtime ~= nil or (thread.status == "active" and status ~= "closed")
end

local transcript_roles = {
  assistant = true,
  user = true,
  system = true,
  tool = true,
  thinking = true,
  plan = true,
}

local function transcript_role(line)
  line = tostring(line or "")
  local role = line:match("^#+%s+([%a]+)")
  if not role and line:match("^─ ") then
    role = line:match("%s([%a]+)%s*")
  end
  role = role and role:lower() or nil
  if role and transcript_roles[role] then return role end
  if line:match("^─ ") and line:match("─+$") then return "assistant" end
  return nil
end

function M.latest_response(thread, max_lines)
  local path = thread and thread.transcript_path or nil
  if not path or path == "" or vim.fn.filereadable(path) ~= 1 then return {} end
  local ok, lines = pcall(vim.fn.readfile, path, "", -400)
  if not ok then return {} end
  local start = nil
  for index = #lines, 1, -1 do
    if transcript_role(lines[index]) == "assistant" then
      start = index + 1
      break
    end
  end
  if not start then return {} end
  local response = {}
  for index = start, #lines do
    if transcript_role(lines[index]) then break end
    response[#response + 1] = lines[index]
  end
  while #response > 0 and vim.trim(response[1]) == "" do table.remove(response, 1) end
  while #response > 0 and vim.trim(response[#response]) == "" do table.remove(response) end
  max_lines = math.max(1, tonumber(max_lines) or 8)
  if #response > max_lines then
    response = vim.list_slice(response, 1, max_lines)
    response[#response + 1] = "…"
  end
  return response
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

local function configured_model(thread, runtime)
  local runtime_model = runtime and config_values.preferred(
    runtime.acp_config_options,
    { "model" },
    runtime.acp_model_catalog and runtime.acp_model_catalog.currentModelId
  )
  local stored_model = config_values.preferred(thread.config, { "model" }, thread.model)
  return runtime_model or (stored_model and stored_model ~= "" and stored_model) or "default"
end

local function card_line(thread, runtime, conflicts, opts)
  opts = opts or {}
  local max_width = opts.width
  local status = common_status(thread, runtime, opts)
  local model = configured_model(thread, runtime)
  local changes = changed_file_count(thread)
  local pinned = thread.metadata and thread.metadata.cockpit_pinned == true
  local conflict_count = vim.tbl_count(conflicts[thread.thread_id] or {})
  local test = thread.metadata and thread.metadata.test_result or nil
  local provider = tostring(thread.provider_id or "provider")
  local raw_title = M.prompt_title(thread) or ""
  local show_title = raw_title ~= ""
  local is_open = opts.open_thread_id == thread.thread_id
  local activation = M.activation_summary(thread, runtime)
  local attention = M.attention(thread, runtime, opts)
  local alerted = #attention.items > 0 and not attention.snoozed

  local fields = {}
  local activity = Activity.summarize(runtime)
  if activity.available and activity.label ~= "Idle" then
    fields[#fields + 1] = { "activity:" .. truncate_display(activity.label, 36), "LazyAgentACPCockpitMuted", "activity" }
  end
  if Review.enabled(thread) then
    fields[#fields + 1] = { "review:" .. M.review(thread, runtime, opts).state, "LazyAgentACPCockpitMuted", "review" }
  end
  if alerted then
    fields[#fields + 1] = { truncate_display(attention.items[1].label, 36), "LazyAgentACPCockpitUnread", "attention" }
  end
  local team = runtime and runtime.lazyagent_team
    or (thread.metadata and thread.metadata.lazyagent_team)
    or nil
  if team then
    local team_label = tostring(team.team_id or team.name or "team")
      .. "/" .. tostring(team.role_id or team.role or "member")
    if team.status and team.status ~= "" then team_label = team_label .. ":" .. tostring(team.status) end
    fields[#fields + 1] = { "team:" .. team_label, "LazyAgentACPCockpitTeam", "team" }
  end
  if thread.metadata and thread.metadata.client_local_branch == true then
    fields[#fields + 1] = { "branch:local", "LazyAgentACPCockpitMuted", "branch" }
  end
  if model ~= "default" then fields[#fields + 1] = { "model:" .. tostring(model), "LazyAgentACPCockpitModel", "model" } end
  if thread.unread == true then fields[#fields + 1] = { "unread", "LazyAgentACPCockpitUnread", "unread" } end
  local usage = usage_label(runtime)
  if usage ~= "n/a" then fields[#fields + 1] = { "usage:" .. usage, "LazyAgentACPCockpitMuted", "usage" } end
  if changes > 0 then fields[#fields + 1] = { "changes:" .. tostring(changes), "LazyAgentACPCockpitChanges", "changes" } end
  local queue_count = runtime and #(runtime.acp_prompt_queue or {}) or 0
  if queue_count > 0 then
    fields[#fields + 1] = { "queue:" .. tostring(queue_count), "LazyAgentACPCockpitQueue", "queue" }
  end
  if conflict_count > 0 then
    fields[#fields + 1] = { "⚠conflicts:" .. tostring(conflict_count), "LazyAgentACPCockpitConflict", "conflict" }
  end
  if test then
    local test_status = M.test_status(thread, opts)
    local test_group = test_status == "passed" and "LazyAgentACPCockpitTestPassed"
      or test_status == "failed" and "LazyAgentACPCockpitTestFailed"
      or "LazyAgentACPCockpitTestRunning"
    fields[#fields + 1] = { "test:" .. test_status, test_group, "test" }
  end
  if activation.context_label then
    fields[#fields + 1] = { "ctx:" .. activation.context_label, "LazyAgentACPCockpitMuted", "activation" }
  end
  if activation.history_label then
    fields[#fields + 1] = { "hist:" .. activation.history_label, "LazyAgentACPCockpitMuted", "activation" }
  end

  local function fixed_width()
    local status_padding = math.max(1, (opts.status_width or display_width(status)) - display_width(status) + 1)
    local width = display_width("- " .. (alerted and "! " or "") .. (is_open and "● " or "") .. (pinned and "★ " or "") .. "[" .. status .. "]")
      + status_padding + display_width(provider)
    for _, field in ipairs(fields) do width = width + display_width(" · " .. field[1]) end
    if show_title then width = width + display_width(" · ") end
    return width
  end

  local removal_order = { "activation", "usage", "model", "changes", "test", "unread", "conflict", "queue", "team", "review", "activity", "attention" }
  local minimum_tail_width = show_title and 12 or 0
  while max_width and max_width - fixed_width() < minimum_tail_width do
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

  if max_width then
    local width_without_provider = fixed_width() - display_width(provider)
    local title_reserve = show_title and 1 or 0
    local provider_width = math.max(1, max_width - width_without_provider - title_reserve)
    provider = truncate_display(provider, provider_width)
  end
  local available_title_width = max_width and math.max(0, max_width - fixed_width()) or PROMPT_MAX_WIDTH
  local title_width = math.min(PROMPT_MAX_WIDTH, available_title_width)
  local title = show_title and title_width > 0 and truncate_display(raw_title, title_width) or ""
  local parts, spans = {}, {}
  add_segment(parts, spans, "- ", "LazyAgentACPCockpitMuted")
  if alerted then add_segment(parts, spans, "! ", "LazyAgentACPCockpitUnread") end
  if is_open then add_segment(parts, spans, "● ", "LazyAgentACPCockpitActive") end
  if pinned then add_segment(parts, spans, "★ ", "LazyAgentACPCockpitPin") end
  add_segment(parts, spans, "[" .. status .. "]", status_highlights[status] or "LazyAgentACPCockpitMuted")
  add_segment(parts, spans, string.rep(" ", math.max(1, (opts.status_width or display_width(status)) - display_width(status) + 1)))
  add_segment(parts, spans, provider, "LazyAgentACPCockpitProvider")
  for _, field in ipairs(fields) do
    add_segment(parts, spans, " · ", "LazyAgentACPCockpitMuted")
    add_segment(parts, spans, field[1], field[2])
  end
  if title ~= "" then
    add_segment(parts, spans, " · ", "LazyAgentACPCockpitMuted")
    add_segment(parts, spans, title, "LazyAgentACPCockpitPrompt")
  end
  return table.concat(parts), spans
end

function M.render(threads, runtimes, opts)
  runtimes = runtimes or {}
  opts = vim.tbl_extend("force", {}, opts or {})
  opts.process_cache = opts.process_cache or {}
  opts.review_cache, opts.since_cache = {}, {}
  opts.status_width = 0
  for _, thread in ipairs(threads or {}) do
    opts.status_width = math.max(
      opts.status_width,
      display_width(common_status(thread, runtimes[thread.thread_id], opts))
    )
  end
  local conflicts = M.conflicts(threads)
  local groups = {}
  local attention_count = 0
  for _, thread in ipairs(threads or {}) do
    if M.needs_attention(thread, runtimes[thread.thread_id], opts) then attention_count = attention_count + 1 end
    if not opts.attention_only or M.needs_attention(thread, runtimes[thread.thread_id], opts) then
      local path = group_path(thread)
      groups[path] = groups[path] or {}
      groups[path][#groups[path] + 1] = thread
    end
  end
  local paths = vim.tbl_keys(groups)
  local current_root = tostring(opts.current_root or ""):gsub("/$", "")
  table.sort(paths, function(left, right)
    local left_current = tostring(left):gsub("/$", "") == current_root
    local right_current = tostring(right):gsub("/$", "") == current_root
    if left_current ~= right_current then return left_current end
    return left < right
  end)

  local lines = {
    "# LazyAgent ACP Session Cockpit · attention:" .. attention_count .. (opts.attention_only and " · Attention view" or ""),
    "",
    "persisted threads: running/idle = this Neovim, external = another Neovim, closed = resumable history, archived = retained history",
    "`?` actions  `n` new agent  `<C-y>` copy ref  `<CR>` latest/mirror  `P` preview  `s` preview layout  `q` close",
  }
  if opts.query and opts.query ~= "" or opts.view_name then
    lines[2] = (opts.view_name and ("View: " .. opts.view_name .. " · ") or "") .. "Filter: " .. (opts.query or "")
    lines[2] = vim.fn.strcharpart(lines[2]:gsub("%c", " "), 0, 240)
  end
  local line_map = {}
  local controls = {}
  local group_rows = {}
  local highlights = {
    [1] = { { start_col = 0, end_col = #lines[1], group = "LazyAgentACPCockpitTitle" } },
    [3] = { { start_col = 0, end_col = #lines[3], group = "LazyAgentACPCockpitHelp" } },
    [4] = { { start_col = 0, end_col = #lines[4], group = "LazyAgentACPCockpitHelp" } },
  }
  if lines[2] ~= "" then highlights[2] = { { start_col = 0, end_col = #lines[2], group = "LazyAgentACPCockpitHelp" } } end
  if #paths == 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = opts.attention_only and "_No threads need attention._" or "_No persisted ACP threads._"
    return lines, line_map, highlights, controls, group_rows
  end

  for _, path in ipairs(paths) do
    local group_attention = 0
    for _, thread in ipairs(groups[path]) do
      if M.needs_attention(thread, runtimes[thread.thread_id], opts) then group_attention = group_attention + 1 end
    end
    local collapsed = opts.collapsed_groups and opts.collapsed_groups[path]
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## " .. vim.fn.fnamemodify(path, ":~")
      .. (group_attention > 0 and (" · attention:" .. group_attention) or "")
      .. (collapsed and " · collapsed" or "")
    group_rows[#lines] = path
    highlights[#lines] = { { start_col = 0, end_col = #lines[#lines], group = "LazyAgentACPCockpitWorkspace" } }
    table.sort(groups[path], function(left, right)
      if opts.attention_only then
        local left_priority = M.attention(left, runtimes[left.thread_id], opts).priority
        local right_priority = M.attention(right, runtimes[right.thread_id], opts).priority
        if left_priority ~= right_priority then return left_priority < right_priority end
      end
      local left_live = live_thread(left, runtimes[left.thread_id], opts)
      local right_live = live_thread(right, runtimes[right.thread_id], opts)
      if left_live ~= right_live then return left_live end
      local left_pinned = left.metadata and left.metadata.cockpit_pinned == true
      local right_pinned = right.metadata and right.metadata.cockpit_pinned == true
      if left_pinned ~= right_pinned then return left_pinned end
      if left.updated_at == right.updated_at then return left.thread_id < right.thread_id end
      return tostring(left.updated_at or "") > tostring(right.updated_at or "")
    end)
    local limit = math.max(1, math.floor(tonumber(opts.history_limit) or 10))
    local expanded = opts.expanded_groups and opts.expanded_groups[path] == true
    local history_count, hidden_count = 0, 0
    for _, thread in ipairs(collapsed and {} or groups[path]) do
      local runtime = runtimes[thread.thread_id]
      local pinned = thread.metadata and thread.metadata.cockpit_pinned == true
      local history = not live_thread(thread, runtime, opts) and not pinned and not M.needs_attention(thread, runtime, opts)
      if history then history_count = history_count + 1 end
      if history and history_count > limit and not expanded then
        hidden_count = hidden_count + 1
      else
        local line, spans = card_line(thread, runtime, conflicts, opts)
        lines[#lines + 1] = line
        line_map[#lines] = thread.thread_id
        highlights[#lines] = spans
      end
    end
    if hidden_count > 0 or (expanded and history_count > limit) then
      lines[#lines + 1] = expanded and "  ▴ Show less history  <CR>"
        or string.format("  ▸ More history (%d)  <CR>", hidden_count)
      controls[#lines] = { path = path, expanded = expanded }
      highlights[#lines] = { { start_col = 0, end_col = #lines[#lines], group = "LazyAgentACPCockpitHelp" } }
    end
  end
  return lines, line_map, highlights, controls, group_rows
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

function M.filter(threads, query, runtimes, opts)
  query = vim.trim(tostring(query or ""))
  runtimes = runtimes or {}
  opts = opts or {}
  local meaningful = vim.tbl_filter(M.has_meaningful_content, threads or {})
  if query == "" then return meaningful end
  local compiled, err = Query.compile(query)
  if not compiled then return {}, err end
  local needed = {}
  for _, term in ipairs(compiled.terms) do needed[term.field] = true end
  return vim.tbl_filter(function(thread)
    local runtime = runtimes[thread.thread_id]
    local text = ""
    if needed.text then
      text = table.concat({
        thread.thread_id or "",
        thread.title or "",
        M.prompt_title(thread) or "",
        thread.provider_id or "",
        thread.cwd or "",
        group_path(thread),
        thread.status or "",
        common_status(thread, runtime, opts),
        tostring(configured_model(thread, runtime)),
        thread.metadata and thread.metadata.lazyagent_team
            and vim.inspect(thread.metadata.lazyagent_team)
          or "",
        runtime and runtime.lazyagent_team and vim.inspect(runtime.lazyagent_team) or "",
        thread.unread == true and "unread" or "read",
        (M.activation_summary(thread, runtime).context_label or ""),
        (M.activation_summary(thread, runtime).history_label or ""),
        "review:" .. M.review(thread, runtime, opts).state,
        M.since(thread, opts).changed and "updates" or "",
        Activity.summarize(runtime).label,
      }, " "):lower()
    end
    local workspace = group_path(thread)
    local function root(path) return vim.fs.normalize(tostring(path)):gsub("(.)/+$", "%1") end
    return Query.matches(compiled, {
      text = text, status = common_status(thread, runtime, opts), provider = thread.provider_id,
      model = configured_model(thread, runtime), workspace = workspace,
      current_workspace = opts.current_root ~= nil and opts.current_root ~= "" and root(workspace) == root(opts.current_root),
      team = vim.inspect(runtime and runtime.lazyagent_team or (thread.metadata or {}).lazyagent_team or {}),
      review = needed.review and M.review(thread, runtime, opts).state, test = needed.test and M.test_status(thread, opts),
      activity = needed.activity and Activity.summarize(runtime).label, unread = thread.unread == true,
      pinned = (thread.metadata or {}).cockpit_pinned == true, attention = needed.attention and M.needs_attention(thread, runtime, opts),
      updates = needed.updates and M.since(thread, opts).changed == true, live = live_thread(thread, runtime, opts), tracked = Review.enabled(thread),
    })
  end, meaningful)
end

return M

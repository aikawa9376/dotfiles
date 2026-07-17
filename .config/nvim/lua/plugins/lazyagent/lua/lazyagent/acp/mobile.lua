local M = {}

local uv = vim.loop

local acp_logic = require("lazyagent.logic.acp")
local backend_logic = require("lazyagent.logic.backend")
local qr = require("lazyagent.web.qr")
local state = require("lazyagent.logic.state")
local security = require("lazyagent.acp.mobile_security")

M._server = nil
M.port = nil
M.host = nil
M.token = nil

local event_clients = {}
local heartbeat_timer = nil
local event_poll_timer = nil
local event_signatures = {}
local event_seq = 0
local stop_heartbeat
local stop_event_watcher

local AUTO_PORT_START = 39280
local AUTO_PORT_END = 39480
local MAX_HEADER_BYTES = 16 * 1024

local function trim(text)
  return tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function config()
  local acp = state.opts and state.opts.acp or {}
  return acp.mobile or {}
end

local function parse_http_request(raw)
  local header_end = raw:find("\r\n\r\n", 1, true)
  if not header_end then
    return nil
  end

  local header_part = raw:sub(1, header_end - 1)
  if header_end > MAX_HEADER_BYTES then
    return nil, "headers_too_large"
  end
  local body = raw:sub(header_end + 4)
  local lines = vim.split(header_part, "\r\n", { plain = true })
  local method, path = (lines[1] or ""):match("^(%u+) (%S+)")
  if not method then
    return nil
  end

  local headers = {}
  for i = 2, #lines do
    local k, v = lines[i]:match("^([^:]+):%s*(.*)$")
    if k then
      headers[k:lower()] = v
    end
  end

  local raw_content_length = headers["content-length"]
  if method == "POST" and raw_content_length == nil then
    return nil, "content_length_required"
  end
  local content_length = raw_content_length and tonumber(raw_content_length) or 0
  if content_length == nil or content_length < 0 or content_length % 1 ~= 0 then
    return nil, "invalid_content_length"
  end

  return {
    method = method,
    path = path,
    headers = headers,
    body = body:sub(1, content_length),
    content_length = content_length,
  }
end

local function request_is_complete(raw, max_body_bytes)
  if not raw:find("\r\n\r\n", 1, true) and #raw > MAX_HEADER_BYTES then
    return false, "headers_too_large"
  end
  if #raw > MAX_HEADER_BYTES + max_body_bytes + 4 then
    return false, "request_too_large"
  end
  local req, parse_err = parse_http_request(raw)
  if not req then
    return false, parse_err
  end
  if not security.body_allowed(req.content_length, max_body_bytes) then
    return false, "request_too_large"
  end
  return #req.body >= req.content_length, nil
end

local function http_response(status, content_type, body, extra_headers, cors_origin)
  body = body or ""
  local lines = {
    "HTTP/1.1 " .. status,
    "Content-Type: " .. content_type,
    "Access-Control-Allow-Methods: POST, GET, OPTIONS",
    "Access-Control-Allow-Headers: Content-Type, Authorization",
    "Vary: Origin",
    "Content-Length: " .. #body,
  }
  if cors_origin and cors_origin ~= "" then
    lines[#lines + 1] = "Access-Control-Allow-Origin: " .. cors_origin
  end
  if extra_headers then
    for _, header in ipairs(extra_headers) do
      lines[#lines + 1] = header
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = body
  return table.concat(lines, "\r\n")
end

local function json_response(status, payload, cors_origin)
  return http_response(status, "application/json; charset=utf-8", vim.fn.json_encode(payload or {}), nil, cors_origin)
end

local backend_for

local function active_acp_sessions()
  local sessions = {}
  for name, session in pairs(state.sessions or {}) do
    if type(session) == "table"
      and session.pane_id
      and session.pane_id ~= ""
      and acp_logic.is_acp_backend(session.backend)
    then
      local queue_size = type(session.prompt_queue) == "table" and #session.prompt_queue or 0
      local busy = session.busy == true or session.preparing_prompt == true or queue_size > 0
      local status = "ready"
      if session.failed then
        status = "failed"
      elseif not session.ready then
        status = "starting"
      elseif busy then
        status = "busy"
      end
      local backend_mod = backend_for(name)
      local pending_permission = backend_mod and type(backend_mod.get_pending_permission) == "function"
        and backend_mod.get_pending_permission(session.pane_id) or nil
      sessions[#sessions + 1] = {
        name = name,
        pane_id = session.pane_id,
        backend = session.backend,
        status = status,
        ready = session.ready == true,
        busy = busy,
        failed = session.failed == true,
        queue = queue_size,
        model = session.current_model or session.model or session.acp_model,
        mode = session.current_mode or session.mode or session.acp_mode,
        permission = pending_permission ~= nil,
      }
    end
  end
  table.sort(sessions, function(a, b)
    return a.name < b.name
  end)
  return sessions
end

local function session_is_active_acp(name)
  if not name or name == "" then
    return false
  end
  local session = state.sessions[name]
  return type(session) == "table"
    and session.pane_id
    and session.pane_id ~= ""
    and acp_logic.is_acp_backend(session.backend)
end

local function default_agent()
  if session_is_active_acp(state.open_agent) then
    return state.open_agent
  end

  if session_is_active_acp(state.current_session_name) then
    return state.current_session_name
  end

  local active = active_acp_sessions()
  if #active == 1 then
    return active[1].name
  end

  return active[1] and active[1].name or nil
end

local function resolve_agent(agent_name)
  agent_name = trim(agent_name)
  if agent_name ~= "" then
    if session_is_active_acp(agent_name) then
      return agent_name
    end
    return nil, "ACP session not found: " .. agent_name
  end

  local chosen = default_agent()
  if chosen then
    return chosen
  end

  return nil, "No active ACP session"
end

backend_for = function(agent_name)
  local _, backend_mod = backend_logic.resolve_backend_for_agent(agent_name, nil)
  return backend_mod
end

local function send_prompt(agent_name, text)
  local target, err = resolve_agent(agent_name)
  if not target then
    return false, err
  end

  text = trim(text)
  if text == "" then
    return false, "Prompt is empty"
  end

  local session = state.sessions[target]
  local backend_mod = backend_for(target)
  if not backend_mod or type(backend_mod.paste_and_submit) ~= "function" then
    return false, "ACP backend cannot send prompts"
  end

  local ok = backend_mod.paste_and_submit(session.pane_id, text, { "C-m" }, {})
  if ok == false then
    return false, "ACP backend rejected the prompt"
  end

  return true, nil, target
end

local function interrupt_agent(agent_name)
  local target, err = resolve_agent(agent_name)
  if not target then
    return false, err
  end

  local session = state.sessions[target]
  local backend_mod = backend_for(target)
  if not backend_mod or type(backend_mod.send_keys) ~= "function" then
    return false, "ACP backend cannot send interrupts"
  end

  local ok = backend_mod.send_keys(session.pane_id, "C-c")
  if ok == false then
    return false, "ACP backend rejected the interrupt"
  end

  return true, nil, target
end

local function action_snapshot(agent_name)
  local target, err = resolve_agent(agent_name)
  if not target then return nil, err end
  local session = state.sessions[target]
  local backend_mod = backend_for(target)
  if not backend_mod then return nil, "ACP backend is unavailable" end
  local permission = type(backend_mod.get_pending_permission) == "function"
    and backend_mod.get_pending_permission(session.pane_id) or nil
  local thread_id = session.thread_id or session.acp_thread_id
  local review = { changes = {} }
  if type(backend_mod.get_thread_review) == "function" and thread_id then
    local review_err
    review, review_err = backend_mod.get_thread_review(thread_id)
    if not review then return nil, review_err end
  end
  return { agent = target, permission = permission, review = review }, nil, target
end

local function respond_permission(agent_name, option_id, scope)
  local target, err = resolve_agent(agent_name)
  if not target then return false, err end
  local session = state.sessions[target]
  local backend_mod = backend_for(target)
  if not backend_mod or type(backend_mod.respond_permission) ~= "function" then
    return false, "ACP backend cannot answer permissions"
  end
  local ok, response_err = backend_mod.respond_permission(session.pane_id, tostring(option_id or ""), tostring(scope or "once"))
  if not ok then return false, response_err end
  return true, nil, target
end

local function decide_review(agent_name, body)
  local target, err = resolve_agent(agent_name)
  if not target then return false, err end
  local session = state.sessions[target]
  local backend_mod = backend_for(target)
  local thread_id = session.thread_id or session.acp_thread_id
  if not backend_mod or not thread_id then return false, "ACP review is unavailable" end
  local decision = (body.decision == "approve" or body.decision == "keep") and "kept"
    or body.decision == "reject" and "rejected"
    or body.decision
  if decision ~= "kept" and decision ~= "rejected" then return false, "decision must be approve or reject" end
  local turn_id = tostring(body.turn_id or "")
  if turn_id == "" then return false, "turn_id is required" end
  local result, decision_err
  if body.change_index and body.hunk_index then
    local change_index, hunk_index = tonumber(body.change_index), tonumber(body.hunk_index)
    if not change_index or change_index < 1 or change_index % 1 ~= 0
      or not hunk_index or hunk_index < 1 or hunk_index % 1 ~= 0
    then
      return false, "change_index and hunk_index must be positive integers"
    end
    result, decision_err = backend_mod.decide_thread_hunk(
      thread_id, turn_id, change_index, hunk_index, decision
    )
  else
    local indices = {}
    for _, index in ipairs(type(body.indices) == "table" and body.indices or {}) do
      index = tonumber(index)
      if not index or index < 1 or index % 1 ~= 0 then return false, "indices must contain positive integers" end
      indices[#indices + 1] = index
    end
    if #indices == 0 then return false, "indices are required" end
    result, decision_err = backend_mod.decide_thread_changes(thread_id, turn_id, indices, decision)
  end
  if not result then return false, decision_err end
  return true, nil, target
end

local function transcript_snapshot(agent_name, opts)
  local target, err = resolve_agent(agent_name)
  if not target then
    return nil, err
  end

  local ok, view = pcall(require, "lazyagent.acp.view_buffer")
  if ok and view and type(view.mobile_transcript_snapshot) == "function" then
    local snapshot, snapshot_err = view.mobile_transcript_snapshot(target, opts or {})
    if snapshot then
      return snapshot, nil, target
    end
    if snapshot_err then
      return nil, snapshot_err
    end
  end

  local session = state.sessions[target]
  local path = session and (session.acp_transcript_path or session.transcript_path) or nil
  local lines = {}
  local tail = math.min(math.max(1, math.floor(tonumber(opts and opts.tail) or 420)), 1600)
  if path and path ~= "" and vim.fn.filereadable(path) == 1 then
    local read_ok, data = pcall(vim.fn.readfile, path)
    if read_ok and type(data) == "table" then
      lines = data
    end
  end
  local total = #lines
  local start_idx = math.max(0, total - tail)
  if start_idx > 0 then
    lines = vim.list_slice(lines, start_idx + 1, total)
  end

  return {
    agent = target,
    pane_id = session and session.pane_id or nil,
    source = "file",
    lines = lines,
    start_line = start_idx + 1,
    line_count = total,
    truncated = start_idx > 0,
    changedtick = 0,
    follow = true,
  }, nil, target
end

local WEB_UI = [=[
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>LazyAgent ACP</title>
  <style>
    :root {
      color-scheme: light dark;
      --bg: #0f1216;
      --surface: #171b21;
      --surface-2: #20262e;
      --surface-3: #262d36;
      --text: #eef3f6;
      --muted: #9aa8b5;
      --line: #343d48;
      --accent: #6bd6bd;
      --accent-2: #8bb8ff;
      --danger: #ff7373;
      --ok: #a6e36d;
      --warn: #f0c36a;
    }
    * { box-sizing: border-box; }
    html, body { height: 100%; }
    body {
      margin: 0;
      overflow: hidden;
      font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: var(--bg);
      color: var(--text);
    }
    main {
      width: min(880px, 100%);
      height: 100dvh;
      margin: 0 auto;
      display: grid;
      grid-template-rows: auto auto minmax(0, 1fr) auto;
      background: var(--bg);
    }
    .topbar {
      min-height: 44px;
      padding: 8px 12px 6px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
      border-bottom: 1px solid var(--line);
    }
    .brand {
      font-size: 16px;
      font-weight: 700;
      line-height: 1.2;
      min-width: 0;
    }
    .status {
      color: var(--muted);
      font-size: 12px;
      line-height: 1.2;
      text-align: right;
      white-space: nowrap;
    }
    .agentbar {
      padding: 8px 12px;
      display: grid;
      grid-template-columns: minmax(0, 1fr) 84px;
      gap: 8px;
      border-bottom: 1px solid var(--line);
      background: var(--surface);
    }
    select, textarea, button {
      width: 100%;
      border: 1px solid var(--line);
      border-radius: 6px;
      background: var(--surface-2);
      color: var(--text);
      font: inherit;
    }
    select {
      min-height: 38px;
      padding: 0 10px;
    }
    button {
      min-height: 38px;
      padding: 0 10px;
      cursor: pointer;
      font-weight: 650;
    }
    button.primary {
      background: var(--accent);
      border-color: transparent;
      color: #06110f;
    }
    button.danger { color: var(--danger); }
    button:disabled {
      opacity: 0.45;
      cursor: not-allowed;
    }
    .transcript-panel {
      min-height: 0;
      display: grid;
      grid-template-rows: auto minmax(0, 1fr);
    }
    .transcript-meta {
      min-height: 32px;
      padding: 6px 12px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 10px;
      border-bottom: 1px solid var(--line);
      color: var(--muted);
      font-size: 12px;
      background: var(--bg);
    }
    .transcript-meta strong {
      color: var(--text);
      font-size: 13px;
    }
    .transcript {
      overflow-y: auto;
      overscroll-behavior: contain;
      padding: 10px 12px 16px;
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace;
      font-size: 13px;
      line-height: 1.45;
      background: #101318;
    }
    .line {
      white-space: pre-wrap;
      overflow-wrap: anywhere;
      min-height: 1.45em;
      padding: 1px 0;
    }
    .line.heading {
      margin: 12px 0 5px;
      padding-top: 8px;
      border-top: 1px solid var(--line);
      color: var(--accent-2);
      font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      font-size: 12px;
      font-weight: 750;
      text-transform: uppercase;
    }
    .line.heading.user { color: var(--warn); }
    .line.heading.assistant { color: var(--ok); }
    .line.heading.tool,
    .line.heading.edited { color: var(--accent-2); }
    .line.heading.error { color: var(--danger); }
    .empty {
      color: var(--muted);
      padding: 16px 0;
      font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      font-size: 13px;
    }
    .composer {
      padding: 10px 12px 12px;
      display: grid;
      gap: 8px;
      border-top: 1px solid var(--line);
      background: var(--surface);
    }
    textarea {
      min-height: 84px;
      max-height: 28dvh;
      resize: vertical;
      padding: 10px;
      line-height: 1.45;
    }
    .actions {
      display: grid;
      grid-template-columns: minmax(0, 1fr) 92px 108px;
      gap: 8px;
    }
    .action-card {
      display: grid;
      gap: 8px;
      padding: 9px;
      border: 1px solid var(--warn);
      border-radius: 6px;
      background: var(--surface-2);
      font-size: 12px;
    }
    .choice-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 6px; }
    .review-list { display: grid; gap: 8px; margin-top: 8px; max-height: 34dvh; overflow-y: auto; }
    .review-item { padding: 8px; border: 1px solid var(--line); border-radius: 6px; background: var(--surface-2); }
    .review-head { display: flex; justify-content: space-between; gap: 8px; font-size: 12px; font-weight: 700; }
    .review-buttons { display: grid; grid-template-columns: 1fr 1fr; gap: 6px; margin-top: 7px; }
    .diff { max-height: 180px; overflow: auto; white-space: pre; font: 11px/1.4 ui-monospace, monospace; color: var(--muted); }
    details {
      border-top: 1px solid var(--line);
      padding-top: 8px;
    }
    summary {
      cursor: pointer;
      color: var(--muted);
      font-size: 12px;
      font-weight: 650;
    }
    .agents {
      display: grid;
      gap: 6px;
      margin-top: 8px;
      max-height: 22dvh;
      overflow-y: auto;
    }
    .agent {
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto;
      gap: 4px 8px;
      padding: 8px;
      border-radius: 6px;
      background: var(--surface-2);
      border: 1px solid transparent;
    }
    .agent.active { border-color: var(--accent); }
    .agent-name {
      min-width: 0;
      font-weight: 700;
      overflow-wrap: anywhere;
    }
    .agent-meta {
      grid-column: 1 / -1;
      color: var(--muted);
      font-size: 12px;
    }
    .pill {
      align-self: start;
      border: 1px solid var(--line);
      border-radius: 999px;
      padding: 1px 8px;
      color: var(--muted);
      font-size: 12px;
    }
    .pill.ready { color: var(--ok); }
    .pill.busy,
    .pill.starting { color: var(--warn); }
    .pill.failed { color: var(--danger); }
    @media (max-width: 560px) {
      .topbar { padding-inline: 10px; }
      .agentbar { grid-template-columns: minmax(0, 1fr) 76px; padding-inline: 10px; }
      .transcript { padding-inline: 10px; font-size: 12px; }
      .composer { padding-inline: 10px; }
      .actions { grid-template-columns: 1fr 76px 96px; }
    }
  </style>
</head>
<body>
  <main>
    <header class="topbar">
      <div class="brand">LazyAgent ACP</div>
      <div class="status" id="status">Connecting</div>
    </header>

    <div class="agentbar">
      <select id="agent"></select>
      <button id="latest">Latest</button>
    </div>

    <section class="transcript-panel">
      <div class="transcript-meta">
        <strong id="transcriptTitle">Transcript</strong>
        <span id="transcriptMeta"></span>
      </div>
      <div class="transcript" id="transcript" aria-live="polite"></div>
    </section>

    <section class="composer">
      <div class="action-card" id="permissionPanel" hidden></div>
      <textarea id="prompt" placeholder="Prompt"></textarea>
      <div class="actions">
        <button class="primary" id="send">Send</button>
        <button id="mic">Mic</button>
        <button class="danger" id="interrupt">Interrupt</button>
      </div>
      <details id="reviewDetails" hidden>
        <summary id="reviewSummary">Review changes</summary>
        <div class="review-list" id="reviewList"></div>
      </details>
      <details>
        <summary>Sessions</summary>
        <div class="agents" id="agents"></div>
      </details>
    </section>
  </main>

  <script>
    const agentSelect = document.getElementById('agent');
    const promptInput = document.getElementById('prompt');
    const sendButton = document.getElementById('send');
    const micButton = document.getElementById('mic');
    const interruptButton = document.getElementById('interrupt');
    const latestButton = document.getElementById('latest');
    const permissionPanel = document.getElementById('permissionPanel');
    const reviewDetails = document.getElementById('reviewDetails');
    const reviewSummary = document.getElementById('reviewSummary');
    const reviewList = document.getElementById('reviewList');
    const statusEl = document.getElementById('status');
    const agentsEl = document.getElementById('agents');
    const transcriptEl = document.getElementById('transcript');
    const transcriptTitleEl = document.getElementById('transcriptTitle');
    const transcriptMetaEl = document.getElementById('transcriptMeta');
    let knownAgents = [];
    let statusTimer = null;
    let statusRefreshTimer = null;
    let fallbackTranscriptTimer = null;
    let events = null;
    let lastTranscriptKey = '';
    let followTranscript = true;
    const mobileToken = new URLSearchParams(window.location.search).get('token') || '';

    async function api(path, options = {}) {
      const headers = {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + mobileToken,
        ...(options.headers || {}),
      };
      const response = await fetch(path, {
        ...options,
        headers,
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok || data.ok === false) {
        throw new Error(data.error || response.statusText);
      }
      return data;
    }

    function setStatus(text) {
      statusEl.textContent = text || '';
    }

    function selectedAgent() {
      return agentSelect.value || '';
    }

    function nearTranscriptEnd() {
      return transcriptEl.scrollHeight - transcriptEl.scrollTop - transcriptEl.clientHeight < 80;
    }

    function scrollTranscriptToEnd() {
      transcriptEl.scrollTop = transcriptEl.scrollHeight;
      followTranscript = true;
    }

    function headingKind(line) {
      const match = String(line || '').match(/^\s*(?:\u2500|-){2,}\s*(.*?)\s*(?:\u2500|-){2,}\s*$/);
      if (!match) return null;
      const label = match[1].toLowerCase();
      if (label.includes('user')) return 'user';
      if (label.includes('assistant')) return 'assistant';
      if (label.includes('tool') || label.includes('terminal')) return 'tool';
      if (label.includes('edited')) return 'edited';
      if (label.includes('error')) return 'error';
      return 'heading';
    }

    function renderTranscript(snapshot) {
      const lines = snapshot.lines || [];
      const key = [
        snapshot.agent || '',
        snapshot.changedtick || 0,
        snapshot.line_count || 0,
        snapshot.start_line || 1,
        lines.length,
        lines[lines.length - 1] || '',
      ].join('\u0001');
      if (key === lastTranscriptKey) return;
      lastTranscriptKey = key;

      followTranscript = followTranscript || nearTranscriptEnd();
      transcriptTitleEl.textContent = snapshot.agent || 'Transcript';
      const meta = [];
      if (snapshot.truncated) meta.push('tail');
      meta.push(String(snapshot.line_count || lines.length) + ' lines');
      meta.push(snapshot.source || 'buffer');
      transcriptMetaEl.textContent = meta.join(' / ');

      transcriptEl.textContent = '';
      if (lines.length === 0) {
        const empty = document.createElement('div');
        empty.className = 'empty';
        empty.textContent = 'No transcript';
        transcriptEl.appendChild(empty);
      } else {
        const frag = document.createDocumentFragment();
        for (const line of lines) {
          const div = document.createElement('div');
          const kind = headingKind(line);
          div.className = kind ? 'line heading ' + kind : 'line';
          div.textContent = line === '' ? ' ' : line;
          frag.appendChild(div);
        }
        transcriptEl.appendChild(frag);
      }

      if (followTranscript) {
        requestAnimationFrame(scrollTranscriptToEnd);
      }
    }

    async function refreshTranscript() {
      const agent = selectedAgent();
      if (!agent) {
        transcriptEl.textContent = '';
        transcriptMetaEl.textContent = '';
        lastTranscriptKey = '';
        return;
      }
      try {
        const payload = await api('/api/transcript?agent=' + encodeURIComponent(agent) + '&tail=520');
        renderTranscript(payload.transcript || {});
      } catch (err) {
        transcriptMetaEl.textContent = err.message;
      }
    }

    function renderStatus(payload) {
      knownAgents = payload.agents || [];
      const current = selectedAgent() || payload.default_agent || (knownAgents[0] && knownAgents[0].name) || '';
      agentSelect.textContent = '';
      if (knownAgents.length === 0) {
        const opt = document.createElement('option');
        opt.value = '';
        opt.textContent = 'No active ACP session';
        agentSelect.appendChild(opt);
      } else {
        for (const agent of knownAgents) {
          const opt = document.createElement('option');
          opt.value = agent.name;
          opt.textContent = agent.name + ' - ' + agent.status;
          agentSelect.appendChild(opt);
        }
        agentSelect.value = knownAgents.some(agent => agent.name === current) ? current : knownAgents[0].name;
      }

      agentsEl.textContent = '';
      for (const agent of knownAgents) {
        const row = document.createElement('div');
        row.className = 'agent' + (agent.name === selectedAgent() ? ' active' : '');
        const name = document.createElement('div');
        name.className = 'agent-name';
        name.textContent = agent.name;
        const pill = document.createElement('div');
        pill.className = 'pill ' + agent.status;
        pill.textContent = agent.status;
        const meta = document.createElement('div');
        meta.className = 'agent-meta';
        const details = [];
        if (agent.model) details.push('model ' + agent.model);
        if (agent.mode) details.push('mode ' + agent.mode);
        if (agent.queue) details.push('queue ' + agent.queue);
        details.push(agent.backend || 'acp');
        meta.textContent = details.join(' / ');
        row.append(name, pill, meta);
        row.addEventListener('click', () => {
          agentSelect.value = agent.name;
          lastTranscriptKey = '';
          renderStatus({ agents: knownAgents, default_agent: agent.name });
          refreshTranscript();
        });
        agentsEl.appendChild(row);
      }
      setStatus(new Date().toLocaleTimeString());
    }

    async function refreshStatus() {
      try {
        const payload = await api('/api/status');
        const before = selectedAgent();
        renderStatus(payload);
        if (selectedAgent() !== before || lastTranscriptKey === '') {
          await refreshTranscript();
        }
        await refreshActions();
      } catch (err) {
        setStatus('Disconnected');
      }
    }

    async function answerPermission(choice) {
      try {
        await api('/api/permission', {
          method: 'POST',
          body: JSON.stringify({ agent: selectedAgent(), option_id: choice.option_id, scope: choice.scope }),
        });
        setStatus('Permission answered');
        await refreshActions();
      } catch (err) {
        setStatus(err.message);
      }
    }

    async function decideChange(turnId, indices, decision) {
      if (decision === 'reject' && !confirm('Reject selected changes and restore the previous content?')) return;
      try {
        await api('/api/review', {
          method: 'POST',
          body: JSON.stringify({ agent: selectedAgent(), turn_id: turnId, indices, decision }),
        });
        setStatus(decision === 'approve' ? 'Changes approved' : 'Changes rejected');
        await refreshActions();
        await refreshTranscript();
      } catch (err) {
        setStatus(err.message);
        alert(err.message);
      }
    }

    function renderActions(payload) {
      const permission = payload.permission;
      permissionPanel.hidden = !permission;
      permissionPanel.textContent = '';
      if (permission) {
        const title = document.createElement('strong');
        title.textContent = permission.title || 'Permission required';
        const meta = document.createElement('span');
        meta.textContent = [permission.kind, permission.path].filter(Boolean).join(' / ');
        const choices = document.createElement('div');
        choices.className = 'choice-grid';
        for (const choice of permission.choices || []) {
          const button = document.createElement('button');
          button.textContent = choice.label;
          if (String(choice.option_kind || '').startsWith('reject')) button.className = 'danger';
          button.addEventListener('click', () => answerPermission(choice));
          choices.appendChild(button);
        }
        permissionPanel.append(title, meta, choices);
      }

      const review = payload.review || {};
      const changes = review.changes || [];
      reviewDetails.hidden = changes.length === 0;
      reviewSummary.textContent = 'Review changes (' + changes.filter(change => !change.decision).length + ' pending)';
      reviewList.textContent = '';
      for (const change of changes) {
        const item = document.createElement('div');
        item.className = 'review-item';
        const head = document.createElement('div');
        head.className = 'review-head';
        const path = document.createElement('span');
        path.textContent = (change.operation || '?') + ' ' + (change.path || 'unknown');
        const state = document.createElement('span');
        state.textContent = change.decision === 'kept' ? 'approved' : (change.decision || 'pending');
        head.append(path, state);
        item.appendChild(head);
        if (change.diff) {
          const diff = document.createElement('pre');
          diff.className = 'diff';
          diff.textContent = change.diff + (change.truncated ? '\n… truncated' : '');
          item.appendChild(diff);
        }
        if (!change.decision) {
          const buttons = document.createElement('div');
          buttons.className = 'review-buttons';
          const approve = document.createElement('button');
          approve.textContent = 'Approve';
          approve.addEventListener('click', () => decideChange(review.turn_id, [change.index], 'approve'));
          const reject = document.createElement('button');
          reject.className = 'danger';
          reject.textContent = 'Reject';
          reject.addEventListener('click', () => decideChange(review.turn_id, [change.index], 'reject'));
          buttons.append(approve, reject);
          item.appendChild(buttons);
        }
        reviewList.appendChild(item);
      }
    }

    async function refreshActions() {
      const agent = selectedAgent();
      if (!agent) { renderActions({}); return; }
      try {
        renderActions(await api('/api/actions?agent=' + encodeURIComponent(agent)));
      } catch (err) {
        permissionPanel.hidden = true;
        reviewDetails.hidden = true;
      }
    }

    function scheduleStatusRefresh() {
      if (statusRefreshTimer) return;
      statusRefreshTimer = setTimeout(() => {
        statusRefreshTimer = null;
        refreshStatus();
      }, 800);
    }

    async function sendPrompt() {
      const text = promptInput.value.trim();
      if (!text) return;
      sendButton.disabled = true;
      setStatus('Sending');
      try {
        const res = await api('/api/send', {
          method: 'POST',
          body: JSON.stringify({ agent: selectedAgent(), text }),
        });
        promptInput.value = '';
        setStatus('Sent to ' + res.agent);
        followTranscript = true;
        await refreshStatus();
        await refreshTranscript();
      } catch (err) {
        setStatus(err.message);
        alert(err.message);
      } finally {
        sendButton.disabled = false;
      }
    }

    async function interruptAgent() {
      interruptButton.disabled = true;
      setStatus('Interrupting');
      try {
        const res = await api('/api/interrupt', {
          method: 'POST',
          body: JSON.stringify({ agent: selectedAgent() }),
        });
        setStatus('Interrupted ' + res.agent);
        await refreshStatus();
      } catch (err) {
        setStatus(err.message);
        alert(err.message);
      } finally {
        interruptButton.disabled = false;
      }
    }

    function connectEvents() {
      if (!window.EventSource) return false;
      events = new EventSource('/api/events?token=' + encodeURIComponent(mobileToken));
      events.addEventListener('open', () => setStatus('Live'));
      events.addEventListener('transcript', event => {
        let payload = {};
        try { payload = JSON.parse(event.data || '{}'); } catch (_) {}
        if (!payload.agent || payload.agent === selectedAgent()) {
          refreshTranscript();
          refreshActions();
        }
        scheduleStatusRefresh();
      });
      events.onerror = () => setStatus('Reconnecting');
      return true;
    }

    sendButton.addEventListener('click', sendPrompt);
    interruptButton.addEventListener('click', interruptAgent);
    latestButton.addEventListener('click', scrollTranscriptToEnd);
    transcriptEl.addEventListener('scroll', () => {
      followTranscript = nearTranscriptEnd();
    }, { passive: true });
    promptInput.addEventListener('keydown', event => {
      if (event.key === 'Enter' && (event.ctrlKey || event.metaKey)) {
        event.preventDefault();
        sendPrompt();
      }
    });
    agentSelect.addEventListener('change', () => {
      lastTranscriptKey = '';
      followTranscript = true;
      renderStatus({ agents: knownAgents, default_agent: selectedAgent() });
      refreshTranscript();
      refreshActions();
    });

    const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;
    const secure = location.protocol === 'https:' || location.hostname === 'localhost' || location.hostname === '127.0.0.1';
    if (!SpeechRecognition || !secure) {
      micButton.disabled = true;
      micButton.title = !SpeechRecognition ? 'Voice input is not supported' : 'Voice input requires HTTPS or localhost';
    } else {
      const recognition = new SpeechRecognition();
      recognition.continuous = false;
      recognition.interimResults = false;
      recognition.lang = navigator.language || 'ja-JP';
      recognition.onresult = event => {
        const text = event.results[0][0].transcript;
        promptInput.value = (promptInput.value ? promptInput.value + ' ' : '') + text;
        promptInput.focus();
      };
      recognition.onend = () => micButton.disabled = false;
      recognition.onerror = () => micButton.disabled = false;
      micButton.addEventListener('click', () => {
        micButton.disabled = true;
        recognition.start();
      });
    }

    refreshStatus();
    if (!connectEvents()) {
      fallbackTranscriptTimer = setInterval(refreshTranscript, 1200);
    }
    statusTimer = setInterval(refreshStatus, 5000);
    window.addEventListener('pagehide', () => {
      if (statusTimer) clearInterval(statusTimer);
      if (statusRefreshTimer) clearTimeout(statusRefreshTimer);
      if (fallbackTranscriptTimer) clearInterval(fallbackTranscriptTimer);
      if (events) events.close();
    });
  </script>
</body>
</html>
]=]

local function route_path(path)
  return tostring(path or ""):match("^([^?]+)") or "/"
end

local function url_decode(value)
  value = tostring(value or ""):gsub("+", " ")
  return (value:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

local function query_params(path)
  local query = tostring(path or ""):match("%?(.*)$")
  local params = {}
  if not query or query == "" then
    return params
  end
  for pair in query:gmatch("[^&]+") do
    local key, value = pair:match("^([^=]*)=?(.*)$")
    if key and key ~= "" then
      params[url_decode(key)] = url_decode(value or "")
    end
  end
  return params
end

local function read_json_body(req)
  if trim(req.body) == "" then
    return {}
  end
  local ok, decoded = pcall(vim.fn.json_decode, req.body)
  if not ok or type(decoded) ~= "table" then
    return nil, "Invalid JSON body"
  end
  return decoded
end

local function sse_headers(cors_origin)
  local lines = {
    "HTTP/1.1 200 OK",
    "Content-Type: text/event-stream; charset=utf-8",
    "Cache-Control: no-cache",
    "Connection: keep-alive",
    "Vary: Origin",
  }
  if cors_origin and cors_origin ~= "" then
    lines[#lines + 1] = "Access-Control-Allow-Origin: " .. cors_origin
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = ""
  return table.concat(lines, "\r\n")
end

local function close_event_client(client)
  if event_clients[client] then
    event_clients[client] = nil
  end
  pcall(function() client:close() end)
  if next(event_clients) == nil then
    if stop_heartbeat then
      stop_heartbeat()
    end
    if stop_event_watcher then
      stop_event_watcher()
    end
  end
end

local function write_event(client, event_name, payload)
  local closing_ok, closing = pcall(function()
    return client and client:is_closing()
  end)
  if not client or not closing_ok or closing then
    close_event_client(client)
    return false
  end
  event_seq = event_seq + 1
  local body = table.concat({
    "id: " .. tostring(event_seq),
    "event: " .. tostring(event_name or "message"),
    "data: " .. vim.fn.json_encode(payload or {}),
    "",
    "",
  }, "\n")
  local ok = pcall(function()
    client:write(body)
  end)
  if not ok then
    close_event_client(client)
  end
  return ok
end

local function broadcast_event(event_name, payload)
  for client in pairs(event_clients) do
    write_event(client, event_name, payload)
  end
end

local function transcript_stat_signature(path)
  path = tostring(path or "")
  if path == "" then
    return ""
  end
  local stat = uv.fs_stat(path)
  if not stat then
    return path .. ":missing"
  end
  local mtime = stat.mtime or {}
  return table.concat({
    path,
    tostring(stat.size or 0),
    tostring(mtime.sec or 0),
    tostring(mtime.nsec or 0),
  }, ":")
end

local function session_event_signature(session)
  local queue_size = type(session.prompt_queue) == "table" and #session.prompt_queue or 0
  local busy = session.busy == true or session.preparing_prompt == true or queue_size > 0
  return table.concat({
    tostring(session.backend or ""),
    tostring(session.ready == true),
    tostring(session.failed == true),
    tostring(busy),
    tostring(queue_size),
    tostring(session.current_model or session.model or session.acp_model or ""),
    tostring(session.current_mode or session.mode or session.acp_mode or ""),
    transcript_stat_signature(session.acp_transcript_path or session.transcript_path),
  }, "\31")
end

local function active_event_signatures()
  local signatures = {}
  for name, session in pairs(state.sessions or {}) do
    if type(session) == "table"
      and session.pane_id
      and session.pane_id ~= ""
      and acp_logic.is_acp_backend(session.backend)
    then
      signatures[name] = session_event_signature(session)
    end
  end
  return signatures
end

local function start_event_watcher()
  if event_poll_timer then
    return
  end
  event_signatures = active_event_signatures()
  event_poll_timer = uv.new_timer()
  event_poll_timer:start(250, 250, vim.schedule_wrap(function()
    if next(event_clients) == nil then
      if stop_event_watcher then
        stop_event_watcher()
      end
      return
    end

    local current = active_event_signatures()
    local active_set_changed = false
    for name, signature in pairs(current) do
      if event_signatures[name] ~= signature then
        local session = state.sessions[name]
        broadcast_event("transcript", {
          agent = name,
          pane_id = session and session.pane_id and tostring(session.pane_id) or nil,
        })
      end
    end
    for name in pairs(event_signatures) do
      if current[name] == nil then
        active_set_changed = true
        break
      end
    end
    if active_set_changed then
      broadcast_event("transcript", {})
    end
    event_signatures = current
  end))
end

stop_event_watcher = function()
  if event_poll_timer then
    pcall(function() event_poll_timer:stop() end)
    pcall(function() event_poll_timer:close() end)
    event_poll_timer = nil
  end
  event_signatures = {}
end

local function start_heartbeat()
  if heartbeat_timer then
    return
  end
  heartbeat_timer = uv.new_timer()
  heartbeat_timer:start(15000, 15000, vim.schedule_wrap(function()
    for client in pairs(event_clients) do
      local closing_ok, closing = pcall(function()
        return client:is_closing()
      end)
      if not closing_ok or closing then
        close_event_client(client)
      else
        local ok = pcall(function()
          client:write(": ping\n\n")
        end)
        if not ok then
          close_event_client(client)
        end
      end
    end
  end))
end

stop_heartbeat = function()
  if heartbeat_timer then
    pcall(function() heartbeat_timer:stop() end)
    pcall(function() heartbeat_timer:close() end)
    heartbeat_timer = nil
  end
end

local function handle_events(client, req)
  pcall(function() client:read_stop() end)
  event_clients[client] = true
  local ok = pcall(function()
    client:write(sse_headers(((req or {}).headers or {}).origin))
  end)
  if not ok then
    close_event_client(client)
    return
  end
  write_event(client, "hello", {
    ok = true,
    agents = active_acp_sessions(),
    default_agent = default_agent(),
  })
  start_heartbeat()
  start_event_watcher()
  pcall(function()
    client:read_start(function(err, data)
      if err or data == nil then
        close_event_client(client)
      end
    end)
  end)
end

local function handle_request(req)
  local cfg = config()
  if not security.origin_allowed(req, cfg.allowed_origins) then
    return json_response("403 Forbidden", { ok = false, error = "Origin is not allowed" })
  end
  local cors_origin = ((req or {}).headers or {}).origin
  if req.method == "OPTIONS" then
    return http_response("200 OK", "text/plain; charset=utf-8", "", nil, cors_origin)
  end

  local query = query_params(req.path)
  if not security.authorized(req, M.token, query.token) then
    return json_response("401 Unauthorized", { ok = false, error = "Bearer token is required" }, cors_origin)
  end

  local path = route_path(req.path)
  if req.method == "GET" and (path == "/" or path == "/ui") then
    return http_response("200 OK", "text/html; charset=utf-8", WEB_UI, nil, cors_origin)
  end

  if req.method == "GET" and path == "/api/status" then
    return json_response("200 OK", {
      ok = true,
      agents = active_acp_sessions(),
      default_agent = default_agent(),
      server = {
        host = M.host,
        port = M.port,
      },
    }, cors_origin)
  end

  if req.method == "GET" and path == "/api/transcript" then
    local params = query_params(req.path)
    local snapshot, err, agent = transcript_snapshot(params.agent or params.agent_name, {
      tail = params.tail,
    })
    if not snapshot then
      return json_response("400 Bad Request", { ok = false, error = err }, cors_origin)
    end
    return json_response("200 OK", {
      ok = true,
      agent = agent,
      transcript = snapshot,
    }, cors_origin)
  end

  if req.method == "GET" and path == "/api/actions" then
    local params = query_params(req.path)
    local snapshot, err = action_snapshot(params.agent or params.agent_name)
    if not snapshot then return json_response("400 Bad Request", { ok = false, error = err }, cors_origin) end
    snapshot.ok = true
    return json_response("200 OK", snapshot, cors_origin)
  end

  if req.method == "POST" and path == "/api/send" then
    local body, body_err = read_json_body(req)
    if not body then
      return json_response("400 Bad Request", { ok = false, error = body_err }, cors_origin)
    end
    local ok, err, agent = send_prompt(body.agent or body.agent_name, body.text or body.prompt)
    if not ok then
      return json_response("400 Bad Request", { ok = false, error = err }, cors_origin)
    end
    return json_response("200 OK", { ok = true, agent = agent }, cors_origin)
  end

  if req.method == "POST" and path == "/api/interrupt" then
    local body, body_err = read_json_body(req)
    if not body then
      return json_response("400 Bad Request", { ok = false, error = body_err }, cors_origin)
    end
    local ok, err, agent = interrupt_agent(body.agent or body.agent_name)
    if not ok then
      return json_response("400 Bad Request", { ok = false, error = err }, cors_origin)
    end
    return json_response("200 OK", { ok = true, agent = agent }, cors_origin)
  end

  if req.method == "POST" and path == "/api/permission" then
    local body, body_err = read_json_body(req)
    if not body then return json_response("400 Bad Request", { ok = false, error = body_err }, cors_origin) end
    local ok, err, agent = respond_permission(body.agent or body.agent_name, body.option_id, body.scope)
    if not ok then return json_response("409 Conflict", { ok = false, error = err }, cors_origin) end
    return json_response("200 OK", { ok = true, agent = agent }, cors_origin)
  end

  if req.method == "POST" and path == "/api/review" then
    local body, body_err = read_json_body(req)
    if not body then return json_response("400 Bad Request", { ok = false, error = body_err }, cors_origin) end
    local ok, err, agent = decide_review(body.agent or body.agent_name, body)
    if not ok then return json_response("409 Conflict", { ok = false, error = err }, cors_origin) end
    return json_response("200 OK", { ok = true, agent = agent }, cors_origin)
  end

  return http_response("404 Not Found", "text/plain; charset=utf-8", "Not Found", nil, cors_origin)
end

local function close_client(client)
  pcall(function()
    client:shutdown(function()
      pcall(function() client:close() end)
    end)
  end)
end

local function handle_client(client)
  local buf = ""
  local max_body_bytes = tonumber(config().max_body_bytes)
  if not max_body_bytes or max_body_bytes <= 0 then
    max_body_bytes = 256 * 1024
  end
  client:read_start(function(err, data)
    if err or not data then
      pcall(function() client:close() end)
      return
    end

    buf = buf .. data
    local complete, request_err = request_is_complete(buf, max_body_bytes)
    if request_err then
      local status = "400 Bad Request"
      local message = "Bad Request"
      if request_err == "headers_too_large" then
        status = "431 Request Header Fields Too Large"
        message = "Request Headers Too Large"
      elseif request_err == "request_too_large" then
        status = "413 Payload Too Large"
        message = "Payload Too Large"
      end
      client:write(http_response(status, "text/plain; charset=utf-8", message))
      close_client(client)
      return
    end
    if not complete then
      return
    end

    local raw = buf
    buf = ""
    vim.schedule(function()
      local req = parse_http_request(raw)
      if not req then
        client:write(http_response("400 Bad Request", "text/plain; charset=utf-8", "Bad Request"))
        close_client(client)
        return
      end

      local cfg = config()
      local query = query_params(req.path)
      if req.method == "GET"
        and route_path(req.path) == "/api/events"
        and security.origin_allowed(req, cfg.allowed_origins)
        and security.authorized(req, M.token, query.token)
      then
        handle_events(client, req)
        return
      end

      client:write(handle_request(req))
      close_client(client)
    end)
  end)
end

local function resolve_start_opts(opts)
  opts = opts or {}
  local cfg = config()
  local host = opts.host or cfg.host or "127.0.0.1"
  local port = tonumber(opts.port or cfg.port)
  if port == 0 then
    port = nil
  end
  return host, port
end

function M.start(on_ready, opts)
  if M._server then
    if on_ready then
      on_ready(M.port)
    end
    return true
  end

  local host, fixed_port = resolve_start_opts(opts)
  local token, token_err = security.random_token()
  if not token then
    vim.notify("[lazyagent ACP mobile] " .. tostring(token_err), vim.log.levels.ERROR)
    return false
  end
  M.token = token
  if not security.is_loopback(host) then
    vim.notify(
      "[lazyagent ACP mobile] LAN exposure enabled on " .. tostring(host) .. "; bearer authentication is required",
      vim.log.levels.WARN
    )
  end
  local function listen(port, quiet)
    if not port then
      vim.notify("[lazyagent ACP mobile] failed to find a free port", vim.log.levels.ERROR)
      return false
    end

    local server = uv.new_tcp()
    local bind_ok, _, bind_err = pcall(function()
      return server:bind(host, port)
    end)
    if not bind_ok or bind_err then
      pcall(function() server:close() end)
      if not quiet then
        vim.notify("[lazyagent ACP mobile] bind error on " .. host .. ":" .. port .. ": " .. tostring(bind_err), vim.log.levels.ERROR)
      end
      return false
    end

    local listen_ok, _, listen_err = pcall(function()
      return server:listen(64, function(lerr)
        if lerr then
          vim.notify("[lazyagent ACP mobile] listen error: " .. tostring(lerr), vim.log.levels.ERROR)
          return
        end
        local client = uv.new_tcp()
        server:accept(client)
        handle_client(client)
      end)
    end)
    if not listen_ok or listen_err then
      pcall(function() server:close() end)
      if not quiet then
        vim.notify("[lazyagent ACP mobile] listen error on " .. host .. ":" .. port .. ": " .. tostring(listen_err), vim.log.levels.ERROR)
      end
      return false
    end

    M._server = server
    M.host = host
    M.port = port

    if on_ready then
      on_ready(port)
    end
    return true
  end

  local function listen_auto()
    for port = AUTO_PORT_START, AUTO_PORT_END do
      if listen(port, true) then
        return true
      end
    end

    vim.notify(
      "[lazyagent ACP mobile] failed to find a free port in "
        .. tostring(AUTO_PORT_START)
        .. "-"
        .. tostring(AUTO_PORT_END),
      vim.log.levels.ERROR
    )
    return false
  end

  local started = fixed_port and listen(fixed_port, false) or listen_auto()
  if not started then
    M.token = nil
  end
  return started
end

function M.stop()
  if M._server then
    pcall(function() M._server:close() end)
  end
  for client in pairs(event_clients) do
    close_event_client(client)
  end
  if stop_heartbeat then
    stop_heartbeat()
  end
  if stop_event_watcher then
    stop_event_watcher()
  end
  M._server = nil
  M.port = nil
  M.host = nil
  M.token = nil
end

local function display_host(host)
  host = tostring(host or "")
  if host == "0.0.0.0" or host == "::" then
    return qr.local_ip()
  end
  if host == "" or host == "localhost" or host == "127.0.0.1" or host == "::1" then
    return "127.0.0.1"
  end
  if host:find(":", 1, true) and not host:match("^%[") then
    return "[" .. host .. "]"
  end
  return host
end

function M.url()
  if not M.port then
    return nil
  end
  return "http://" .. display_host(M.host) .. ":" .. tostring(M.port) .. "/?token=" .. tostring(M.token or "")
end

local function mobile_hints()
  return {
    "To enable mic on Android Chrome:",
    "chrome://flags/#unsafely-treat-insecure-origin-as-secure",
    "Add the URL above, then Relaunch",
  }
end

function M.show_qr(opts)
  M.start(function()
    local url = M.url()
    if not url then
      vim.notify("LazyAgentACPMobileQR: server is not ready", vim.log.levels.WARN)
      return
    end
    qr.show(url, {
      title = " LazyAgent ACP Mobile ",
      hints = mobile_hints(),
    })
  end, opts)
end

function M.notify_url(opts)
  M.start(function()
    local url = M.url()
    if url then
      vim.notify("[lazyagent ACP mobile] " .. url, vim.log.levels.INFO)
    end
  end, opts)
end

return M

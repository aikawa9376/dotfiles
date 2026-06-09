local M = {}

local uv = vim.loop

local acp_logic = require("lazyagent.logic.acp")
local backend_logic = require("lazyagent.logic.backend")
local qr = require("lazyagent.web.qr")
local state = require("lazyagent.logic.state")

M._server = nil
M.port = nil
M.host = nil

local AUTO_PORT_START = 39280
local AUTO_PORT_END = 39480

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

  return {
    method = method,
    path = path,
    headers = headers,
    body = body,
    content_length = tonumber(headers["content-length"] or "0") or 0,
  }
end

local function request_is_complete(raw)
  local req = parse_http_request(raw)
  if not req then
    return false
  end
  return #req.body >= req.content_length
end

local function http_response(status, content_type, body, extra_headers)
  body = body or ""
  local lines = {
    "HTTP/1.1 " .. status,
    "Content-Type: " .. content_type,
    "Access-Control-Allow-Origin: *",
    "Access-Control-Allow-Methods: POST, GET, OPTIONS",
    "Access-Control-Allow-Headers: Content-Type",
    "Content-Length: " .. #body,
  }
  if extra_headers then
    for _, header in ipairs(extra_headers) do
      lines[#lines + 1] = header
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = body
  return table.concat(lines, "\r\n")
end

local function json_response(status, payload)
  return http_response(status, "application/json; charset=utf-8", vim.fn.json_encode(payload or {}))
end

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

local function backend_for(agent_name)
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
      --bg: #101214;
      --panel: #181c20;
      --panel-2: #20262c;
      --text: #eef2f4;
      --muted: #a9b3bd;
      --line: #313941;
      --accent: #69d2e7;
      --danger: #ff6b6b;
      --ok: #9be564;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: var(--bg);
      color: var(--text);
    }
    main {
      width: min(760px, 100%);
      margin: 0 auto;
      padding: 16px;
      display: grid;
      gap: 12px;
    }
    header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
      padding: 4px 0;
    }
    h1 {
      font-size: 18px;
      line-height: 1.2;
      margin: 0;
      font-weight: 650;
      letter-spacing: 0;
    }
    .status {
      color: var(--muted);
      font-size: 13px;
      min-height: 18px;
      text-align: right;
    }
    section {
      display: grid;
      gap: 10px;
      padding: 12px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: var(--panel);
    }
    label {
      color: var(--muted);
      font-size: 12px;
      font-weight: 600;
      text-transform: uppercase;
    }
    select, textarea, button {
      width: 100%;
      border: 1px solid var(--line);
      border-radius: 6px;
      background: var(--panel-2);
      color: var(--text);
      font: inherit;
    }
    select {
      min-height: 42px;
      padding: 0 10px;
    }
    textarea {
      min-height: 190px;
      resize: vertical;
      padding: 10px;
      line-height: 1.45;
    }
    .actions {
      display: grid;
      grid-template-columns: minmax(0, 1fr) 112px 112px;
      gap: 8px;
      align-items: stretch;
    }
    button {
      min-height: 44px;
      padding: 0 12px;
      cursor: pointer;
      font-weight: 650;
    }
    button.primary {
      background: var(--accent);
      color: #071012;
      border-color: transparent;
    }
    button.danger {
      color: var(--danger);
    }
    button:disabled {
      opacity: 0.45;
      cursor: not-allowed;
    }
    .agents {
      display: grid;
      gap: 8px;
    }
    .agent {
      display: grid;
      grid-template-columns: 1fr auto;
      gap: 6px;
      padding: 10px;
      border-radius: 6px;
      background: var(--panel-2);
      border: 1px solid transparent;
    }
    .agent.active {
      border-color: var(--accent);
    }
    .agent-name {
      font-weight: 650;
      min-width: 0;
      overflow-wrap: anywhere;
    }
    .agent-meta {
      color: var(--muted);
      font-size: 12px;
      grid-column: 1 / -1;
    }
    .pill {
      align-self: start;
      border-radius: 999px;
      border: 1px solid var(--line);
      padding: 2px 8px;
      font-size: 12px;
      color: var(--muted);
    }
    .pill.ready { color: var(--ok); }
    .pill.failed { color: var(--danger); }
    .hint {
      color: var(--muted);
      font-size: 12px;
      line-height: 1.5;
    }
    @media (max-width: 560px) {
      main { padding: 12px; }
      header { align-items: flex-start; }
      .actions { grid-template-columns: 1fr; }
      .status { text-align: left; }
    }
  </style>
</head>
<body>
  <main>
    <header>
      <h1>LazyAgent ACP</h1>
      <div class="status" id="status">Connecting...</div>
    </header>

    <section>
      <label for="agent">Agent</label>
      <select id="agent"></select>
      <label for="prompt">Prompt</label>
      <textarea id="prompt" placeholder="Type a prompt for the active ACP session"></textarea>
      <div class="actions">
        <button class="primary" id="send">Send</button>
        <button id="mic">Mic</button>
        <button class="danger" id="interrupt">Interrupt</button>
      </div>
      <div class="hint">Ctrl+Enter or Cmd+Enter sends. Voice input requires a secure browser context.</div>
    </section>

    <section>
      <label>Sessions</label>
      <div class="agents" id="agents"></div>
    </section>
  </main>

  <script>
    const agentSelect = document.getElementById('agent');
    const promptInput = document.getElementById('prompt');
    const sendButton = document.getElementById('send');
    const micButton = document.getElementById('mic');
    const interruptButton = document.getElementById('interrupt');
    const statusEl = document.getElementById('status');
    const agentsEl = document.getElementById('agents');
    let knownAgents = [];
    let pollTimer = null;

    async function api(path, options = {}) {
      const response = await fetch(path, {
        headers: { 'Content-Type': 'application/json' },
        ...options,
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

    function renderStatus(payload) {
      knownAgents = payload.agents || [];
      const current = agentSelect.value || payload.default_agent || (knownAgents[0] && knownAgents[0].name) || '';
      agentSelect.innerHTML = '';
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

      agentsEl.innerHTML = '';
      if (knownAgents.length === 0) {
        const empty = document.createElement('div');
        empty.className = 'hint';
        empty.textContent = 'Start an ACP session in Neovim, then refresh this page.';
        agentsEl.appendChild(empty);
      } else {
        for (const agent of knownAgents) {
          const row = document.createElement('div');
          row.className = 'agent' + (agent.name === agentSelect.value ? ' active' : '');
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
            renderStatus({ agents: knownAgents, default_agent: agent.name });
          });
          agentsEl.appendChild(row);
        }
      }
      setStatus(new Date().toLocaleTimeString());
    }

    async function refreshStatus() {
      try {
        const payload = await api('/api/status');
        renderStatus(payload);
      } catch (err) {
        setStatus('Disconnected');
      }
    }

    async function sendPrompt() {
      const text = promptInput.value.trim();
      if (!text) return;
      sendButton.disabled = true;
      setStatus('Sending...');
      try {
        const res = await api('/api/send', {
          method: 'POST',
          body: JSON.stringify({ agent: agentSelect.value, text }),
        });
        promptInput.value = '';
        setStatus('Sent to ' + res.agent);
        await refreshStatus();
      } catch (err) {
        setStatus(err.message);
        alert(err.message);
      } finally {
        sendButton.disabled = false;
      }
    }

    async function interruptAgent() {
      interruptButton.disabled = true;
      setStatus('Interrupting...');
      try {
        const res = await api('/api/interrupt', {
          method: 'POST',
          body: JSON.stringify({ agent: agentSelect.value }),
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

    sendButton.addEventListener('click', sendPrompt);
    interruptButton.addEventListener('click', interruptAgent);
    promptInput.addEventListener('keydown', event => {
      if (event.key === 'Enter' && (event.ctrlKey || event.metaKey)) {
        event.preventDefault();
        sendPrompt();
      }
    });
    agentSelect.addEventListener('change', () => renderStatus({ agents: knownAgents, default_agent: agentSelect.value }));

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
    pollTimer = setInterval(refreshStatus, 1800);
    window.addEventListener('pagehide', () => {
      if (pollTimer) clearInterval(pollTimer);
    });
  </script>
</body>
</html>
]=]

local function route_path(path)
  return tostring(path or ""):match("^([^?]+)") or "/"
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

local function handle_request(req)
  if req.method == "OPTIONS" then
    return http_response("200 OK", "text/plain; charset=utf-8", "")
  end

  local path = route_path(req.path)
  if req.method == "GET" and (path == "/" or path == "/ui") then
    return http_response("200 OK", "text/html; charset=utf-8", WEB_UI)
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
    })
  end

  if req.method == "POST" and path == "/api/send" then
    local body, body_err = read_json_body(req)
    if not body then
      return json_response("400 Bad Request", { ok = false, error = body_err })
    end
    local ok, err, agent = send_prompt(body.agent or body.agent_name, body.text or body.prompt)
    if not ok then
      return json_response("400 Bad Request", { ok = false, error = err })
    end
    return json_response("200 OK", { ok = true, agent = agent })
  end

  if req.method == "POST" and path == "/api/interrupt" then
    local body, body_err = read_json_body(req)
    if not body then
      return json_response("400 Bad Request", { ok = false, error = body_err })
    end
    local ok, err, agent = interrupt_agent(body.agent or body.agent_name)
    if not ok then
      return json_response("400 Bad Request", { ok = false, error = err })
    end
    return json_response("200 OK", { ok = true, agent = agent })
  end

  return http_response("404 Not Found", "text/plain; charset=utf-8", "Not Found")
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
  client:read_start(function(err, data)
    if err or not data then
      pcall(function() client:close() end)
      return
    end

    buf = buf .. data
    if not request_is_complete(buf) then
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

      client:write(handle_request(req))
      close_client(client)
    end)
  end)
end

local function resolve_start_opts(opts)
  opts = opts or {}
  local cfg = config()
  local host = opts.host or cfg.host or (state.opts and state.opts.mcp_host) or "127.0.0.1"
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

  if fixed_port then
    return listen(fixed_port, false)
  end

  return listen_auto()
end

function M.stop()
  if M._server then
    pcall(function() M._server:close() end)
  end
  M._server = nil
  M.port = nil
  M.host = nil
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
  return "http://" .. display_host(M.host) .. ":" .. tostring(M.port) .. "/"
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

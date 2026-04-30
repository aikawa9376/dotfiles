local M = {}

local token_state = {
  copilot = {
    oauth_token = nil,
    github_token = nil,
  },
}

local function trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function decode_json(text)
  local ok, decoded
  if vim.json and vim.json.decode then
    ok, decoded = pcall(vim.json.decode, text)
  else
    ok, decoded = pcall(vim.fn.json_decode, text)
  end
  if ok and type(decoded) == "table" then
    return decoded
  end
  return nil
end

local function encode_json(value)
  if vim.json and vim.json.encode then
    return vim.json.encode(value)
  end
  return vim.fn.json_encode(value)
end

local function read_json_file(path)
  if not path or path == "" or vim.fn.filereadable(path) ~= 1 then
    return nil
  end

  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" then
    return nil
  end

  return decode_json(table.concat(lines, "\n"))
end

local function config_dir()
  local xdg = vim.env.XDG_CONFIG_HOME
  if type(xdg) == "string" and xdg ~= "" and vim.fn.isdirectory(xdg) == 1 then
    return xdg
  end

  if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
    local localapp = vim.env.LOCALAPPDATA
    if type(localapp) == "string" and localapp ~= "" then
      return localapp
    end
    return vim.fn.expand("~/AppData/Local")
  end

  return vim.fn.expand("~/.config")
end

local function find_oauth_token(payload)
  if type(payload) ~= "table" then
    return nil
  end

  for host, value in pairs(payload) do
    if tostring(host):match("github%.com") and type(value) == "table" then
      local token = trim(value.oauth_token)
      if token ~= "" then
        return token
      end
    end
  end

  for _, value in pairs(payload) do
    if type(value) == "table" then
      local token = trim(value.oauth_token)
      if token ~= "" then
        return token
      end
    end
  end

  return nil
end

local function get_copilot_oauth_token(force_reload)
  if force_reload then
    token_state.copilot.oauth_token = nil
  end

  local cached = trim(token_state.copilot.oauth_token)
  if cached ~= "" then
    return cached
  end

  local base = config_dir()
  local candidates = {
    base .. "/github-copilot/hosts.json",
    base .. "/github-copilot/apps.json",
  }

  for _, path in ipairs(candidates) do
    local payload = read_json_file(path)
    local token = find_oauth_token(payload)
    if token then
      token_state.copilot.oauth_token = token
      return token
    end
  end

  return nil, "Copilot OAuth token not found. Sign in with Copilot first."
end

local function merge_tables(defaults, overrides)
  return vim.tbl_deep_extend("force", defaults or {}, overrides or {})
end

local function parse_status(stdout)
  local body, status = tostring(stdout or ""):match("^(.*)\n(%d%d%d)$")
  if body then
    return body, tonumber(status)
  end
  return tostring(stdout or ""), nil
end

local function curl_request(opts, callback)
  if vim.fn.executable("curl") ~= 1 then
    callback(nil, "curl executable not found")
    return
  end
  if type(vim.system) ~= "function" then
    callback(nil, "vim.system is unavailable in this Neovim version")
    return
  end

  local cmd = {
    "curl",
    "-sS",
    "-L",
    "-X",
    tostring(opts.method or "GET"):upper(),
    tostring(opts.url),
    "-w",
    "\n%{http_code}",
  }

  local timeout_ms = tonumber(opts.timeout_ms)
  if timeout_ms and timeout_ms > 0 then
    cmd[#cmd + 1] = "--max-time"
    cmd[#cmd + 1] = string.format("%.3f", timeout_ms / 1000)
  end

  if opts.allow_insecure == true then
    cmd[#cmd + 1] = "-k"
  end

  local proxy = trim(opts.proxy)
  if proxy ~= "" then
    cmd[#cmd + 1] = "--proxy"
    cmd[#cmd + 1] = proxy
  end

  for name, value in pairs(opts.headers or {}) do
    if value ~= nil then
      cmd[#cmd + 1] = "-H"
      cmd[#cmd + 1] = tostring(name) .. ": " .. tostring(value)
    end
  end

  if opts.body ~= nil then
    cmd[#cmd + 1] = "--data-binary"
    cmd[#cmd + 1] = tostring(opts.body)
  end

  vim.system(cmd, { text = true }, function(result)
    local body, status = parse_status(result.stdout)
    callback({
      status = status,
      body = body,
      stderr = trim(result.stderr),
      exit_code = result.code,
    }, nil)
  end)
end

local function copilot_cfg(opts)
  local api = type(opts.api) == "table" and opts.api or {}
  local copilot = type(api.copilot) == "table" and api.copilot or {}

  return {
    endpoint = trim(api.endpoint) ~= "" and trim(api.endpoint) or "https://api.githubcopilot.com",
    token_url = trim(copilot.token_url) ~= "" and trim(copilot.token_url) or "https://api.github.com/copilot_internal/v2/token",
    model = trim(api.model) ~= "" and trim(api.model) or "gpt-4o-2024-11-20",
    timeout_ms = tonumber(api.timeout_ms or opts.timeout_ms) or 90000,
    proxy = api.proxy,
    allow_insecure = api.allow_insecure == true,
    use_response_api = api.use_response_api,
    token_refresh_skew_seconds = tonumber(copilot.token_refresh_skew_seconds) or 120,
    extra_headers = type(api.extra_headers) == "table" and vim.deepcopy(api.extra_headers) or {},
    extra_body = merge_tables({
      max_tokens = 20480,
    }, type(api.extra_body) == "table" and api.extra_body or nil),
  }
end

local function token_expired(token, skew_seconds)
  local expires_at = type(token) == "table" and tonumber(token.expires_at) or nil
  if not expires_at then
    return true
  end
  return expires_at <= (os.time() + (tonumber(skew_seconds) or 120))
end

local function response_error_message(response, fallback)
  local parsed = decode_json(response and response.body or "")
  if type(parsed) == "table" then
    local err = parsed.error
    if type(err) == "table" then
      local message = trim(err.message or err.error or err.code)
      if message ~= "" then
        return message
      end
    end

    local message = trim(parsed.message)
    if message ~= "" then
      return message
    end
  end

  local body = trim(response and response.body or "")
  if body ~= "" then
    return body
  end

  local stderr = trim(response and response.stderr or "")
  if stderr ~= "" then
    return stderr
  end

  return fallback
end

local function refresh_copilot_token(cfg, callback)
  local function attempt(force_reload_oauth)
    local cached = token_state.copilot.github_token
    if cached and not force_reload_oauth and not token_expired(cached, cfg.token_refresh_skew_seconds) then
      callback(cached, nil)
      return
    end

    local oauth_token, oauth_err = get_copilot_oauth_token(force_reload_oauth)
    if not oauth_token then
      callback(nil, oauth_err)
      return
    end

    curl_request({
      method = "GET",
      url = cfg.token_url,
      timeout_ms = cfg.timeout_ms,
      proxy = cfg.proxy,
      allow_insecure = cfg.allow_insecure,
      headers = {
        Authorization = "token " .. oauth_token,
        Accept = "application/json",
      },
    }, function(response, transport_err)
      if transport_err then
        callback(nil, transport_err)
        return
      end

      if response.status == 401 and not force_reload_oauth then
        token_state.copilot.oauth_token = nil
        token_state.copilot.github_token = nil
        attempt(true)
        return
      end

      if response.exit_code ~= 0 then
        callback(nil, response_error_message(response, "Copilot token refresh failed"))
        return
      end

      if response.status ~= 200 then
        callback(nil, response_error_message(response, "Copilot token refresh returned HTTP " .. tostring(response.status)))
        return
      end

      local parsed = decode_json(response.body)
      if not parsed or trim(parsed.token) == "" then
        callback(nil, "Copilot token response did not include a chat token")
        return
      end

      token_state.copilot.github_token = parsed
      callback(parsed, nil)
    end)
  end

  attempt(false)
end

local function use_response_api(cfg)
  if cfg.use_response_api ~= nil then
    return cfg.use_response_api == true
  end
  return cfg.model:match("gpt%-%d+%.?%d*%-codex") ~= nil
end

local function join_url(base, suffix)
  base = tostring(base or ""):gsub("/+$", "")
  return base .. suffix
end

local function flatten_content(content)
  if type(content) == "string" then
    return content
  end
  if type(content) ~= "table" then
    return nil
  end

  local out = {}
  for _, item in ipairs(content) do
    if type(item) == "string" then
      out[#out + 1] = item
    elseif type(item) == "table" then
      local text = item.text or item.content
      if type(text) == "string" and text ~= "" then
        out[#out + 1] = text
      end
    end
  end

  if #out == 0 then
    return nil
  end
  return table.concat(out, "")
end

local function extract_output_text(payload)
  if type(payload) ~= "table" then
    return nil
  end

  if type(payload.output_text) == "string" and payload.output_text ~= "" then
    return payload.output_text
  end

  if type(payload.choices) == "table" and type(payload.choices[1]) == "table" then
    local choice = payload.choices[1]
    local message = type(choice.message) == "table" and choice.message or {}
    local text = flatten_content(message.content) or message.text or choice.text
    if type(text) == "string" and text ~= "" then
      return text
    end
  end

  if type(payload.output) == "table" then
    local parts = {}
    for _, item in ipairs(payload.output) do
      if type(item) == "table" then
        if item.type == "message" and type(item.content) == "table" then
          local text = flatten_content(item.content)
          if text and text ~= "" then
            parts[#parts + 1] = text
          end
        elseif type(item.content) == "string" and item.content ~= "" then
          parts[#parts + 1] = item.content
        elseif type(item.text) == "string" and item.text ~= "" then
          parts[#parts + 1] = item.text
        end
      end
    end
    if #parts > 0 then
      return table.concat(parts, "\n")
    end
  end

  return nil
end

local function copilot_headers(token, cfg)
  return merge_tables({
    Authorization = "Bearer " .. token,
    Accept = "application/json",
    ["Content-Type"] = "application/json",
    ["User-Agent"] = "GitHubCopilotChat/0.26.7",
    ["Editor-Version"] = "vscode/1.105.1",
    ["Editor-Plugin-Version"] = "copilot-chat/0.26.7",
    ["Copilot-Integration-Id"] = "vscode-chat",
    ["Openai-Intent"] = "conversation-edits",
    ["X-Initiator"] = "user",
  }, cfg.extra_headers)
end

local function copilot_request_body(prompt, cfg)
  local extra_body = vim.deepcopy(cfg.extra_body or {})
  if use_response_api(cfg) then
    if extra_body.max_completion_tokens ~= nil and extra_body.max_output_tokens == nil then
      extra_body.max_output_tokens = extra_body.max_completion_tokens
      extra_body.max_completion_tokens = nil
    end
    if extra_body.max_tokens ~= nil and extra_body.max_output_tokens == nil then
      extra_body.max_output_tokens = extra_body.max_tokens
      extra_body.max_tokens = nil
    end

    return merge_tables({
      model = cfg.model,
      stream = false,
      input = {
        {
          role = "user",
          content = prompt,
        },
      },
      include = { "reasoning.encrypted_content" },
      reasoning = { summary = "detailed" },
      truncation = "disabled",
    }, extra_body)
  end

  return merge_tables({
    model = cfg.model,
    stream = false,
    messages = {
      {
        role = "user",
        content = prompt,
      },
    },
  }, extra_body)
end

local function normalized_provider(opts)
  local api = type(opts.api) == "table" and opts.api or {}
  local provider = trim(api.provider)
  if provider ~= "" then
    return provider:lower()
  end

  local agent = trim(opts.agent)
  if agent ~= "" then
    return agent:lower()
  end

  return "copilot"
end

local function request_copilot(prompt, opts, callback)
  local cfg = copilot_cfg(opts)
  local function attempt(force_token_refresh)
    if force_token_refresh then
      token_state.copilot.github_token = nil
    end

    refresh_copilot_token(cfg, function(token_payload, token_err)
      if token_err then
        callback(false, "", token_err)
        return
      end

      local base_url = trim(token_payload and token_payload.endpoints and token_payload.endpoints.api)
      if base_url == "" then
        base_url = cfg.endpoint
      end

      local url = join_url(base_url, use_response_api(cfg) and "/responses" or "/chat/completions")
      local body = encode_json(copilot_request_body(prompt, cfg))
      curl_request({
        method = "POST",
        url = url,
        timeout_ms = cfg.timeout_ms,
        proxy = cfg.proxy,
        allow_insecure = cfg.allow_insecure,
        headers = copilot_headers(token_payload.token, cfg),
        body = body,
      }, function(response, transport_err)
        if transport_err then
          callback(false, "", transport_err)
          return
        end

        if response.status == 401 and not force_token_refresh then
          token_state.copilot.github_token = nil
          attempt(true)
          return
        end

        if response.exit_code ~= 0 then
          callback(false, "", response_error_message(response, "Copilot API request failed"))
          return
        end

        if not response.status or response.status < 200 or response.status >= 300 then
          callback(false, "", response_error_message(response, "Copilot API returned HTTP " .. tostring(response.status)))
          return
        end

        local payload = decode_json(response.body)
        local text = extract_output_text(payload)
        if not text or trim(text) == "" then
          callback(false, "", "Copilot API returned an empty edit response")
          return
        end

        callback(true, text, "")
      end)
    end)
  end

  attempt(false)
end

function M.label(opts)
  local provider = normalized_provider(opts or {})
  if provider == "copilot" then
    return "Copilot API"
  end
  return provider ~= "" and (provider .. " API") or "API"
end

function M.request(prompt, _ctx, opts, callback)
  opts = opts or {}
  callback = callback or function() end

  local api = type(opts.api) == "table" and opts.api or {}
  if type(api.request) == "function" then
    local ok, result = pcall(api.request, prompt, _ctx, callback)
    if not ok then
      callback(false, "", result)
      return
    end
    if type(result) == "string" then
      callback(true, result, "")
      return
    end
    if type(result) == "table" then
      callback(result.ok ~= false, result.stdout or result.output or "", result.stderr or result.error or "")
    end
    return
  end

  local provider = normalized_provider(opts)
  if provider == "copilot" then
    request_copilot(prompt, opts, callback)
    return
  end

  callback(false, "", "unsupported edit_blocks.api provider: " .. tostring(provider))
end

return M

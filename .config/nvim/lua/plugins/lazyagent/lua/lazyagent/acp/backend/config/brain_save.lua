local M = {}

function M.setup(deps)
  local state = deps.state
  local skills_logic = deps.skills_logic
  local normalize_text = deps.normalize_text
  local item_body_text = deps.item_body_text

  local module = {}

  local function trim_text(text)
    local trimmed = normalize_text(text or "")
    trimmed = trimmed:gsub("^%s+", "")
    trimmed = trimmed:gsub("%s+$", "")
    return trimmed
  end

  local function brain_save_config()
    local cfg = state and state.opts and state.opts.acp and state.opts.acp.brain_save
    if cfg == true then
      return { enabled = true }
    end
    if type(cfg) == "table" then
      return cfg
    end
    return {}
  end

  local function resolve_brain_save_command()
    local cfg = brain_save_config()
    if cfg.enabled ~= true then
      return nil
    end
    if type(cfg.command) == "table" and not vim.tbl_isempty(cfg.command) then
      return vim.deepcopy(cfg.command), nil
    end
    if type(cfg.command) == "string" and cfg.command ~= "" then
      return cfg.command, nil
    end

    local binary = type(skills_logic.find_binary) == "function" and skills_logic.find_binary("ai-memory-cli") or nil
    if binary then
      return { binary, "save" }, nil
    end

    local bin_dir = type(skills_logic.resolve_bin_dir) == "function" and skills_logic.resolve_bin_dir() or nil
    local suffix = (bin_dir and bin_dir ~= "") and (" (checked " .. bin_dir .. ")") or ""
    return nil, "ai-memory-cli not found; set acp.brain_save.command or skills.bin_dir" .. suffix
  end

  local function collect_brain_turn_interactions(session, prompt, start_seq)
    local assistant_parts = {}
    for _, item in ipairs(session and session.conversation_timeline or {}) do
      if type(item) == "table" and (tonumber(item.seq) or 0) > (tonumber(start_seq) or 0) and item.kind == "assistant" then
        local body = trim_text(type(item_body_text) == "function" and item_body_text(item) or item.body)
        if body ~= "" then
          assistant_parts[#assistant_parts + 1] = body
        end
      end
    end

    local user_input = trim_text(prompt)
    local assistant_output = trim_text(table.concat(assistant_parts, "\n\n"))
    if user_input == "" or assistant_output == "" then
      return nil
    end

    return {
      {
        user_input = user_input,
        assistant_output = assistant_output,
      },
    }
  end

  local function notify_brain_save_failure(message, level)
    if not message or message == "" then
      return
    end
    vim.schedule(function()
      vim.notify("LazyAgent ACP brain save: " .. tostring(message), level or vim.log.levels.WARN)
    end)
  end

  local function maybe_save_turn_to_brain(session, prompt, start_seq)
    local interactions = collect_brain_turn_interactions(session, prompt, start_seq)
    if not interactions then
      return
    end

    local command, command_err = resolve_brain_save_command()
    if not command then
      if command_err and type(session) == "table" and session.brain_save_missing_command_warned ~= true then
        session.brain_save_missing_command_warned = true
        notify_brain_save_failure(command_err)
      end
      return
    end

    local stdout = {}
    local stderr = {}
    local job_id = vim.fn.jobstart(command, {
      cwd = session.root_dir or session.cwd or vim.fn.getcwd(),
      env = session.env or {},
      stdin = "pipe",
      stdout_buffered = true,
      stderr_buffered = true,
      on_stdout = function(_, data)
        if type(data) == "table" then
          for _, line in ipairs(data) do
            if line and line ~= "" then
              stdout[#stdout + 1] = line
            end
          end
        end
      end,
      on_stderr = function(_, data)
        if type(data) == "table" then
          for _, line in ipairs(data) do
            if line and line ~= "" then
              stderr[#stderr + 1] = line
            end
          end
        end
      end,
      on_exit = function(_, code)
        if code == 0 then
          return
        end
        local msg = table.concat(stderr, "\n")
        if msg == "" then
          msg = table.concat(stdout, "\n")
        end
        if msg == "" then
          msg = "exit code " .. tostring(code)
        end
        notify_brain_save_failure(msg)
      end,
    })

    if job_id <= 0 then
      notify_brain_save_failure("failed to start ai-memory-cli save")
      return
    end

    local payload = {
      session_id = session.session_id,
      cwd = session.root_dir or session.cwd,
      source = "lazyagent-acp",
      agent_name = session.agent_name,
      interactions = interactions,
    }
    vim.fn.chansend(job_id, vim.fn.json_encode(payload))
    vim.fn.chanclose(job_id, "stdin")
  end

  module.maybe_save_turn_to_brain = maybe_save_turn_to_brain

  return module
end

return M

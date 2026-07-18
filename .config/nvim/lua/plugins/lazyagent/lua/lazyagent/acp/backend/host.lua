local M = {}

function M.setup(deps)
  local ACPClient = deps.ACPClient
  local state = deps.state
  local acp_logic = deps.acp_logic
  local util = deps.util
  local build_transcript_path = deps.build_transcript_path
  local clamp_utf8_from_end = deps.clamp_utf8_from_end
  local ensure_parent_dir = deps.ensure_parent_dir
  local read_path_lines = deps.read_path_lines
  local reload_loaded_buffers_for_path = deps.reload_loaded_buffers_for_path
  local write_session_transcript = deps.write_session_transcript
  local sync_runtime_session = deps.sync_runtime_session
  local update_session_info = deps.update_session_info
  local update_usage_stats = deps.update_usage_stats
  local normalize_session_info = deps.normalize_session_info
  local assistant_heading_label = deps.assistant_heading_label
  local apply_initial_session_config = deps.apply_initial_session_config
  local normalize_available_commands = deps.normalize_available_commands
  local append_block = deps.append_block
  local append_stream_chunk = deps.append_stream_chunk
  local close_stream = deps.close_stream
  local render_content = deps.render_content
  local render_tool_content = deps.render_tool_content
  local render_tool_raw_output = deps.render_tool_raw_output
  local summarize_tool_block = deps.summarize_tool_block
  local extract_tool_paths = deps.extract_tool_paths
  local merge_tool_update = deps.merge_tool_update
  local tool_update_is_terminal = deps.tool_update_is_terminal
  local tool_heading = deps.tool_heading
  local resolve_permission_rule = deps.resolve_permission_rule
  local render_permission_preview = deps.render_permission_preview
  local maybe_call_mcp_tool = deps.maybe_call_mcp_tool
  local maybe_sync_acp_edit_targets = deps.maybe_sync_acp_edit_targets
  local sync_thread = deps.sync_thread or function() end
  local record_turn_event = deps.record_turn_event or function() end
  local terminal_seq = 0
  local resolve_permission_option
  local resolve_filesystem_path
  local nvim_bridge = require("lazyagent.nvim_bridge")
  local PathGuard = require("lazyagent.acp.backend.path_guard")
  local FileWriter = require("lazyagent.acp.backend.file_writer")
  local Terminals = require("lazyagent.acp.backend.terminals")
  local MessageStream = require("lazyagent.acp.backend.message_stream")
  local Notifications = require("lazyagent.acp.notifications")
  local PermissionStore = require("lazyagent.acp.permission_store")

  local function notify_attention(kind, session, message)
    return Notifications.emit(((state.opts or {}).acp or {}).notifications, kind, {
      agent_name = session and session.agent_name or nil,
      message = message,
    })
  end

  local function first_number(...)
    for idx = 1, select("#", ...) do
      local raw = select(idx, ...)
      if raw ~= nil then
        local value = tonumber(raw)
        if value ~= nil then
          return value
        end
      end
    end
    return nil
  end

  local function hook_reload_enabled()
    return ((((state.opts or {}).hooks or {}).reload_mode) or "hook") ~= "watch"
  end

  local module = {}

  local function next_terminal_id()
    terminal_seq = terminal_seq + 1
    return "lazyagent-term-" .. tostring(terminal_seq)
  end

  local function make_env_map(env_list)
    local env = vim.fn.environ()
    for _, entry in ipairs(env_list or {}) do
      if type(entry) == "table" and entry.name and entry.value ~= nil then
        env[entry.name] = tostring(entry.value)
      end
    end
    return nvim_bridge.inject_env(env)
  end

  local function append_terminal_output(session, terminal_id, data)
    if not data then return end
    local text = type(data) == "table" and table.concat(vim.tbl_filter(function(item)
      return item and item ~= ""
    end, data), "\n") or tostring(data)
    if text == "" then return end
    append_stream_chunk(session, "terminal:" .. terminal_id, "Terminal " .. terminal_id, text)
    if not text:match("\n$") then
      write_session_transcript(session, "\n")
    end
  end

  local function create_terminal(session, params, done)
    local terminal_id = next_terminal_id()
    local output_limit = tonumber(params.outputByteLimit) or (1024 * 1024)
    local cwd, cwd_err = resolve_filesystem_path(session, params.cwd or session.cwd, false)
    if not cwd then
      done(nil, cwd_err)
      return
    end
    local cwd_stat = (vim.uv or vim.loop).fs_stat(cwd)
    if not cwd_stat or cwd_stat.type ~= "directory" then
      done(nil, { code = -32602, message = "terminal/create cwd is not a directory: " .. cwd })
      return
    end
    local command = params.command
    if not command or command == "" then
      done(nil, { code = -32602, message = "terminal/create requires command" })
      return
    end

    local argv = { command }
    for _, arg in ipairs(params.args or {}) do
      table.insert(argv, tostring(arg))
    end

    local terminal = {
      id = terminal_id,
      command = vim.deepcopy(argv),
      cwd = cwd,
      created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      output_limit = output_limit,
      output = "",
      truncated = false,
      exit_status = nil,
      waiters = {},
      job_id = nil,
    }
    session.terminals[terminal_id] = terminal

    local function append_output(data)
      if terminal.released or not data then return end
      local parts = {}
      for _, chunk in ipairs(data) do
        if chunk and chunk ~= "" then
          table.insert(parts, chunk)
        end
      end
      if #parts == 0 then return end
      local text = table.concat(parts, "\n")
      if terminal.output ~= "" and not terminal.output:match("\n$") then
        terminal.output = terminal.output .. "\n"
      end
      terminal.output = terminal.output .. text
      terminal.output, terminal.truncated = clamp_utf8_from_end(terminal.output, terminal.output_limit)
      append_terminal_output(session, terminal_id, text)
    end

    local job_id = vim.fn.jobstart(argv, {
      cwd = cwd,
      env = make_env_map(params.env or {}),
      stdout_buffered = false,
      stderr_buffered = false,
      on_stdout = function(_, data)
        vim.schedule(function()
          append_output(data)
        end)
      end,
      on_stderr = function(_, data)
        vim.schedule(function()
          append_output(data)
        end)
      end,
      on_exit = function(_, code, signal)
        vim.schedule(function()
          if terminal.released then
            return
          end
          local status = {
            exitCode = code,
            signal = signal == 0 and vim.NIL or signal,
          }
          Terminals.finish(terminal, status)
          close_stream(session)
        end)
      end,
    })

    if job_id <= 0 then
      session.terminals[terminal_id] = nil
      done(nil, {
        code = -32000,
        message = "Failed to start terminal command: " .. command,
      })
      return
    end

    terminal.job_id = job_id
    done({ terminalId = terminal_id })
  end

  local function terminal_output(session, params)
    local terminal = session.terminals[params.terminalId or ""]
    if not terminal then
      return nil, { code = -32602, message = "Unknown terminalId: " .. tostring(params.terminalId) }
    end

    local result = {
      output = terminal.output,
      truncated = terminal.truncated == true,
    }
    if terminal.exit_status then
      result.exitStatus = terminal.exit_status
    end
    return result
  end

  local function terminal_wait_for_exit(session, params, done)
    local terminal = session.terminals[params.terminalId or ""]
    if not terminal then
      done(nil, { code = -32602, message = "Unknown terminalId: " .. tostring(params.terminalId) })
      return
    end

    if terminal.exit_status then
      done({
        exitCode = terminal.exit_status.exitCode,
        signal = terminal.exit_status.signal,
      })
      return
    end

    table.insert(terminal.waiters, done)
  end

  local function terminal_kill(session, params)
    local terminal = session.terminals[params.terminalId or ""]
    if not terminal then
      return nil, { code = -32602, message = "Unknown terminalId: " .. tostring(params.terminalId) }
    end
    if terminal.job_id then
      pcall(vim.fn.jobstop, terminal.job_id)
    end
    return vim.NIL
  end

  local function terminal_release(session, params)
    Terminals.release(session, params.terminalId or "")
    return vim.NIL
  end

  local function release_all_terminals(session)
    return Terminals.release_all(session)
  end

  resolve_permission_option = function(options, preferred_kind)
    if type(options) ~= "table" then return nil end
    if preferred_kind then
      for _, option in ipairs(options) do
        if option.kind == preferred_kind then
          return option
        end
      end
    end
    if preferred_kind and preferred_kind:match("^allow") then
      for _, option in ipairs(options) do
        if type(option.kind) == "string" and option.kind:match("^allow") then
          return option
        end
      end
    end
    if preferred_kind and preferred_kind:match("^reject") then
      for _, option in ipairs(options) do
        if type(option.kind) == "string" and option.kind:match("^reject") then
          return option
        end
      end
    end
    return nil
  end

  local function resolve_best_allow_option(options)
    return resolve_permission_option(options, "allow_always")
      or resolve_permission_option(options, "allow_once")
  end

  local function handle_permission_request(session, params, done)
    local acp_opts = state.opts and state.opts.acp
    local permission_cfg = type(acp_opts) == "table" and acp_opts.permissions or {}
    permission_cfg = type(permission_cfg) == "table" and permission_cfg or {}
    local store_opts = { base_dir = permission_cfg.dir }
    local latest_cfg = acp_logic.resolve_config(session.agent_cfg or {})
    session.auto_permission = latest_cfg.auto_permission
    session.permission_rules = vim.deepcopy(latest_cfg.permission_rules or {})
    vim.list_extend(session.permission_rules, PermissionStore.rules(session, store_opts))
    local tool = merge_tool_update(session, params.toolCall or {})
    local tool_path = (extract_tool_paths(tool) or {})[1]
    local permission_finished = false
    local function respond(outcome, metadata)
      if permission_finished then return false end
      if session.client and next(session.client.pending_permission_requests or {}) == nil then
        permission_finished = true
        session.pending_permission = nil
        return false
      end
      permission_finished = true
      session.pending_permission = nil
      metadata = metadata or {}
      metadata.path = metadata.path or tool_path
      if permission_cfg.audit ~= false then PermissionStore.audit(session, tool, outcome, metadata, store_opts) end
      done(outcome)
      pcall(function()
        require("lazyagent.logic.status").start_monitor(session.agent_name)
      end)
      return true
    end
    append_block(session, tool_heading(tool), tool.title or tool.toolCallId or "Permission requested", {
      kind = "tool",
      title = tool.title or tool.toolCallId or "Permission requested",
      summary = tool.title or tool.toolCallId or "Permission requested",
      toolCallId = tool.toolCallId,
      status = tool.status,
      path = (extract_tool_paths(tool) or {})[1],
    })
    maybe_call_mcp_tool("notify_waiting", {
      agent_name = session.agent_name,
      message = "Permission",
    })

    local rule_resolution = resolve_permission_rule(session, tool, params.options or {})
    local rule_matched = rule_resolution and rule_resolution.matched == true
    if rule_matched and rule_resolution.option then
      append_block(
        session,
        "System",
        string.format(
          "ACP permission rule `%s` matched and selected `%s`.",
          rule_resolution.label or "rule",
          rule_resolution.action or rule_resolution.option.kind or "option"
        )
      )
      respond({
        outcome = "selected",
        optionId = rule_resolution.option.optionId,
      }, {
        source = "rule",
        scope = rule_resolution.scope or "configured",
        rule = rule_resolution.label,
      })
      return
    elseif rule_matched then
      append_block(
        session,
        "System",
        string.format("ACP permission rule `%s` matched and requires manual confirmation.", rule_resolution.label or "rule")
      )
    end

    local preferred = session.auto_permission
    if not rule_matched and not preferred and session.agent_cfg and session.agent_cfg.yolo then
      preferred = "allow_once"
    end

    local auto = nil
    if not rule_matched then
      auto = resolve_permission_option(params.options or {}, preferred)
    end
    if not auto and not rule_matched and preferred == "allow_always" then
      auto = resolve_best_allow_option(params.options or {})
    end

    -- Auto-allow write/edit tools when a previous auto-fix was requested
    if not auto and not rule_matched then
      local ok, state_mod = pcall(function() return require("lazyagent.logic.state") end)
      if ok and state_mod and state_mod._fix_requested == true then
        local is_edit_tool = false
        if type(tool) == "table" then
          local kind = tostring(tool.kind or "")
          local tname = tostring(tool.toolName or tool.name or tool.title or ""):lower()
          if kind == "edit" or tname:match("write_text_file") or tname:match("write") then
            is_edit_tool = true
          end
        end
        if is_edit_tool then
          local allow_opt = resolve_permission_option(params.options or {}, "allow_once") or resolve_best_allow_option(params.options or {})
          if allow_opt then
            respond({ outcome = "selected", optionId = allow_opt.optionId }, { source = "auto_fix" })
            return
          end
        end
      end
    end

    if auto then
      respond({
        outcome = "selected",
        optionId = auto.optionId,
      }, { source = "auto" })
      return
    end

    local preview = render_permission_preview(tool)
    if preview ~= "" then
      append_block(session, "Edited Preview", preview)
    end

    local labels, choices = PermissionStore.choices(params.options or {})

    local function select_choice(choice)
      if not choice then
        local rejected = resolve_permission_option(params.options or {}, "reject_once")
        if rejected then
          return respond({ outcome = "selected", optionId = rejected.optionId }, { source = "manual", scope = "once" })
        end
        return respond({ outcome = "cancelled" }, { source = "manual", scope = "once" })
      end
      local audit_scope = choice.scope
      if choice.scope == "session" or choice.scope == "project" or choice.scope == "global" then
        local rule = PermissionStore.rule(session, tool, choice.option, choice.scope, tool_path)
        local remembered, remember_err = PermissionStore.remember(session, choice.scope, rule, store_opts)
        if remembered then
          append_block(session, "System", string.format("Remembered `%s` permission for %s scope.",
            choice.option.kind or "option", choice.scope))
        else
          audit_scope = "once"
          append_block(session, "System", "Failed to remember permission: " .. tostring(remember_err))
        end
      end
      return respond({
        outcome = "selected",
        optionId = choice.option.optionId,
      }, { source = "manual", scope = audit_scope })
    end

    local mobile_choices = {}
    for index, choice in ipairs(choices) do
      mobile_choices[index] = {
        label = labels[index],
        option_id = choice.option.optionId,
        option_kind = choice.option.kind,
        scope = choice.scope,
      }
    end
    session.pending_permission = {
      tool_call_id = tool.toolCallId,
      title = tool.title or tool.toolCallId or "Tool permission",
      kind = tool.kind,
      path = tool_path,
      choices = mobile_choices,
      respond = function(option_id, scope)
        for _, choice in ipairs(choices) do
          if choice.option.optionId == option_id and choice.scope == scope then return select_choice(choice) end
        end
        return nil, "permission choice is no longer available"
      end,
    }

    notify_attention("permission", session, tool.title or tool.toolCallId or "Tool permission")

    vim.schedule(function()
      vim.ui.select(labels, {
        prompt = string.format("%s permission: %s", session.agent_name, tool.title or tool.toolCallId or "tool"),
      }, function(_, idx)
        select_choice(idx and choices[idx] or nil)
        end)
    end)
  end

  local function select_auth_method(methods, done)
    local labels = {}
    for _, method in ipairs(methods or {}) do
      local label = tostring(method.name or method.id or "Authentication")
      if method.description and method.description ~= "" then
        label = label .. " — " .. tostring(method.description)
      end
      labels[#labels + 1] = label
    end
    vim.schedule(function()
      vim.ui.select(labels, { prompt = "ACP authentication method" }, function(_, idx)
        local selected = idx and methods[idx] or nil
        done(selected and selected.id or nil)
      end)
    end)
  end

  resolve_filesystem_path = function(session, path, allow_missing)
    if not session.path_guard then
      local guard, err = PathGuard.new({
        cwd = session.cwd,
        additional_directories = session.additional_directories,
      })
      if not guard then
        return nil, { code = -32000, message = err }
      end
      session.path_guard = guard
    end

    local resolved, err = session.path_guard:resolve(path, { allow_missing = allow_missing })
    if not resolved then
      return nil, { code = -32602, message = err }
    end
    return resolved
  end

  local function read_text_file(session, params)
    local path = params.path
    if not path or path == "" then
      return nil, { code = -32602, message = "fs/read_text_file requires path" }
    end

    local abs, path_err = resolve_filesystem_path(session, path, false)
    if not abs then
      return nil, path_err
    end
    local lines = read_path_lines(abs)
    if not lines then
      return nil, { code = -32602, message = "File not found: " .. abs }
    end

    local start_line = tonumber(params.line) or 1
    local limit = tonumber(params.limit)
    local start_idx = math.max(1, start_line)
    local end_idx = #lines
    if limit and limit >= 0 then
      end_idx = math.min(#lines, start_idx + limit - 1)
    end

    local slice = {}
    for idx = start_idx, end_idx do
      table.insert(slice, lines[idx])
    end

    return {
      content = table.concat(slice, "\n"),
    }
  end

  local function write_text_file(session, params)
    local path = params.path
    if not path or path == "" then
      return nil, { code = -32602, message = "fs/write_text_file requires path" }
    end

    local abs, path_err = resolve_filesystem_path(session, path, true)
    if not abs then
      return nil, path_err
    end
    local content = tostring(params.content or "")
    ensure_parent_dir(abs)

    local ok_watch, watch = pcall(require, "lazyagent.watch")
    if ok_watch and watch and type(watch.suspend) == "function" then
      pcall(watch.suspend, abs, 1500)
    end

    local write_result, err = FileWriter.write(abs, content)
    if not write_result then
      return nil, { code = -32000, message = tostring(err) }
    end

    if hook_reload_enabled() then
      reload_loaded_buffers_for_path(abs)
    end
    record_turn_event(session, "file", {
      path = abs,
      operation = write_result.existed and "modified" or "added",
      source = "acp_fs",
      tool_call_id = params.toolCallId or (params._meta and params._meta.toolCallId) or nil,
      before_size = #write_result.before_text,
      after_size = #content,
    })
    append_block(session, "Edited " .. vim.fn.fnamemodify(abs, ":."), "Updated via ACP fs/write_text_file")
    if hook_reload_enabled() and ((state.opts or {}).hooks or {}).open_on_edit == true then
      maybe_call_mcp_tool("open_last_changed", {
        agent_name = session and session.agent_name or nil,
        cwd = session and (session.root_dir or session.cwd) or vim.fn.getcwd(),
        path = abs,
        oldText = write_result.before_text,
        newText = content,
      })
    end
    return vim.NIL
  end

  local function on_client_update(session, params)
    if not params or not params.update then return end
    local update = params.update
    local kind = update.sessionUpdate
    local message_stream = MessageStream.identity(update)

    if kind == "agent_message_chunk" then
      local text = render_content(update.content)
      append_stream_chunk(session, message_stream.key, assistant_heading_label(session), text, {
        kind = message_stream.kind,
        messageId = message_stream.message_id,
      })
      local transcript_is_read = session.view
        and type(session.view.transcript_is_read) == "function"
        and session.view.transcript_is_read(session.pane_id)
      if transcript_is_read then
        if session.thread_record and session.thread_record.unread == true then
          sync_thread(session, { unread = false })
        end
      elseif state.open_agent ~= session.agent_name
          and session.thread_record
          and session.thread_record.unread ~= true
      then
        sync_thread(session, { unread = true })
      end
      return
    end

    if kind == "agent_thought_chunk" then
      append_stream_chunk(session, message_stream.key, "Thinking", render_content(update.content), {
        kind = message_stream.kind,
        messageId = message_stream.message_id,
      })
      return
    end

    if kind == "user_message_chunk" then
      append_stream_chunk(session, message_stream.key, "User", render_content(update.content), {
        kind = message_stream.kind,
        messageId = message_stream.message_id,
      })
      return
    end

    if kind == "plan" and type(update.entries) == "table" then
      local lines = {}
      for _, entry in ipairs(update.entries) do
        if type(entry) == "table" then
          table.insert(lines, string.format("- [%s] %s", entry.status or "pending", entry.content or ""))
        end
      end
      append_block(session, "Plan", table.concat(lines, "\n"))
      return
    end

    if kind == "available_commands_update" then
      session.available_commands = normalize_available_commands(update.availableCommands)
      sync_runtime_session(session)
      return
    end

    if kind == "config_option_update" then
      session.config_options = vim.deepcopy((session.client and session.client.config_options) or update.configOptions or {})
      sync_runtime_session(session)
      return
    end

    if kind == "current_mode_update" or kind == "current_model_update" then
      if kind == "current_mode_update" and type(session.mode_catalog) == "table" then
        session.mode_catalog.currentModeId = update.modeId or update.currentModeId or update.currentMode or session.mode_catalog.currentModeId
      elseif kind == "current_model_update" and type(session.model_catalog) == "table" then
        session.model_catalog.currentModelId = update.modelId or update.currentModelId or update.currentModel or session.model_catalog.currentModelId
      end
      session.config_options = vim.deepcopy((session.client and session.client.config_options) or session.config_options or {})
      sync_runtime_session(session)
      sync_thread(session, {
        mode = session.mode_catalog and session.mode_catalog.currentModeId or vim.NIL,
        model = session.model_catalog and session.model_catalog.currentModelId or vim.NIL,
        config = vim.deepcopy(session.config_options or {}),
      })
      return
    end

    if kind == "session_info_update" then
      update_session_info(session, update)
      sync_runtime_session(session)
      sync_thread(session, {
        title = session.session_info and session.session_info.title or session.agent_name,
        native_session_id = session.session_id or vim.NIL,
      })
      return
    end

    if kind == "usage_update" then
      -- Merge usage info into model catalog so UI can display context/usage
      local model_id = update.modelId or update.currentModelId or (update.model and update.model.modelId) or nil
      local usage = type(update.usage) == "table" and vim.deepcopy(update.usage) or {}
      if update.used ~= nil then
        usage.used = update.used
        usage.usedTokens = usage.usedTokens or update.used
      end
      if update.size ~= nil then
        usage.size = update.size
        usage.contextSize = usage.contextSize or update.size
      end

      if type(session.model_catalog) == "table" and type(session.model_catalog.availableModels) == "table" then
        for _, m in ipairs(session.model_catalog.availableModels) do
          if type(m) == "table" and (not model_id or m.modelId == model_id) then
            m._meta = m._meta or {}
            if next(usage) ~= nil then
              m._meta.usage = vim.deepcopy(usage)
              local used = first_number(
                update.used,
                update.usedTokens,
                update.contextUsedTokens,
                update.contextTokens,
                update.context_tokens,
                update.context_used_tokens,
                usage.used,
                usage.usedTokens,
                usage.contextUsedTokens,
                usage.contextTokens,
                usage.context_tokens,
                usage.context_used_tokens,
                usage.used_tokens
              )
              local total = first_number(
                update.size,
                update.contextSize,
                update.totalContextTokens,
                update.contextWindow,
                update.contextLimit,
                update.context_window,
                usage.size,
                usage.contextSize,
                usage.totalContextTokens,
                usage.contextWindow,
                usage.contextLimit,
                usage.context_window,
                m._meta.contextSize,
                m.contextSize
              )
              if used and total and total > 0 then
                m._meta.token_usage_used = used
                m._meta.token_usage_total = total
              end
            end
            if type(update.model) == "table" and type(update.model._meta) == "table" then
              for k, v in pairs(update.model._meta) do
                m._meta[k] = v
              end
            end
            if update.copilotUsage then
              m._meta.copilotUsage = tostring(update.copilotUsage)
            end
          end
        end
      end
      update_usage_stats(session, update, model_id)
      sync_runtime_session(session)
      return
    end

    if kind == "tool_call" or kind == "tool_call_update" then
      local tool = merge_tool_update(session, update)
      record_turn_event(session, "tool", {
        tool_call_id = tool.toolCallId,
        title = tool.title,
        kind = tool.kind,
        status = tool.status,
        paths = extract_tool_paths(tool),
        locations = vim.deepcopy(tool.locations or tool.location or {}),
      })
      local title = tool.title or tool.toolCallId or "tool"
      local body = render_tool_content(tool.content)
      if body == "" then
        body = render_tool_raw_output(tool.rawOutput)
      end
      local hide_pending = state and state.opts and state.opts.acp and state.opts.acp.hide_pending_messages == true
      local is_terminal = tool_update_is_terminal(tool)
      if not (hide_pending and not is_terminal) then
        if body ~= "" then
          append_block(session, tool_heading(tool), summarize_tool_block(tool, title, body), {
            kind = "tool",
            title = title,
            summary = summarize_tool_block(tool, title, body),
            toolCallId = tool.toolCallId,
            status = tool.status,
            path = (extract_tool_paths(tool) or {})[1],
          })
        else
          append_block(session, tool_heading(tool), title, {
            kind = "tool",
            title = title,
            summary = title,
            toolCallId = tool.toolCallId,
            status = tool.status,
            path = (extract_tool_paths(tool) or {})[1],
          })
        end
      end
      if is_terminal then
        if session.ephemeral ~= true and tool.kind == "edit" then
          util.fire_event("EditDone", { agent_name = session.agent_name, tool = tool })
        end
        if session.ephemeral ~= true then
          maybe_sync_acp_edit_targets(session, tool)
        end

        session.tool_calls[tool.toolCallId] = nil
      end
      return
    end
  end

  local function on_client_exit(session, code, signal, stderr_text)
    release_all_terminals(session)
    if session and session.ephemeral == true then
      return
    end
    if session and session.closing_intentionally == true then
      session.ready = false
      session.failed = false
      close_stream(session)
      sync_thread(session, { status = "closed", process_id = vim.NIL })
      return
    end
    session.ready = false
    session.failed = true
    close_stream(session)
    sync_runtime_session(session)
    sync_thread(session, { status = "failed", process_id = vim.NIL })
    local message = string.format("ACP agent exited (code=%s signal=%s)", tostring(code), tostring(signal))
    if stderr_text and stderr_text ~= "" then
      message = message .. "\n" .. stderr_text
    end
    append_block(session, "System", message)
    pcall(function()
      require("lazyagent.logic.status").set_waiting(session.agent_name, "Disconnected")
    end)
  end

  local function list_all_sessions_for_client(client, params, on_done, collected)
    collected = collected or {}
    client:list_sessions(params, function(result, err)
      if err then
        on_done(nil, err)
        return
      end

      result = type(result) == "table" and result or {}
      for _, item in ipairs(result.sessions or {}) do
        if type(item) == "table" and item.sessionId and item.sessionId ~= "" then
          collected[#collected + 1] = normalize_session_info(item.sessionId, item)
        end
      end

      if result.nextCursor and result.nextCursor ~= "" then
        local next_params = vim.tbl_extend("force", params or {}, {
          cursor = result.nextCursor,
        })
        list_all_sessions_for_client(client, next_params, on_done, collected)
        return
      end

      on_done(collected, nil)
    end)
  end

  local function create_ephemeral_session(base_session)
    local transcript_path = build_transcript_path((base_session.agent_name or "acp") .. "-native", 0)
    return {
      ephemeral = true,
      runtime_sync_disabled = true,
      pane_id = "",
      agent_name = base_session.agent_name,
      agent_cfg = vim.deepcopy(base_session.agent_cfg or {}),
      transcript_path = transcript_path,
      transcript_has_content = false,
      current_stream_key = nil,
      current_stream_heading = nil,
      current_stream_at_line_start = nil,
      prompt_queue = {},
      tool_calls = {},
      terminals = {},
      available_commands = {},
      config_options = {},
      on_ready_actions = {},
      permission_rules = vim.deepcopy(base_session.permission_rules or {}),
      auto_switch = vim.deepcopy(base_session.auto_switch or {}),
      manual_config_overrides = {},
      auto_switch_state = {},
      conversation_timeline = {},
      conversation_timeline_index = {},
      conversation_next_item_id = 0,
      tool_timeline = {},
      tool_timeline_index = {},
      ready = false,
      failed = false,
      busy = false,
      preparing_prompt = false,
      command = base_session.command,
      env = vim.deepcopy(base_session.env or {}),
      cwd = base_session.cwd or vim.fn.getcwd(),
      root_dir = base_session.root_dir,
      additional_directories = vim.deepcopy(base_session.additional_directories or {}),
      mcp_servers = vim.deepcopy(base_session.mcp_servers or {}),
      v2_adapter = vim.deepcopy(base_session.v2_adapter or { enabled = false }),
      mcp_url = base_session.mcp_url,
      protocol_log_path = base_session.protocol_log_path,
      auto_permission = base_session.auto_permission,
      default_mode = base_session.default_mode,
      initial_model = base_session.initial_model,
      fancy_mode = base_session.fancy_mode,
      table_layout = base_session.table_layout,
      smooth_scroll = vim.deepcopy(base_session.smooth_scroll or {}),
      release_buffer_on_hide = base_session.release_buffer_on_hide,
      footer_animation = false,
      protocol_log = base_session.protocol_log,
      show_context_notes = base_session.show_context_notes,
      show_session_summary = base_session.show_session_summary,
      buffer_background = base_session.buffer_background,
      buffer_inactive_background = base_session.buffer_inactive_background,
      transcript_max_lines = base_session.transcript_max_lines,
      render_markdown_max_lines = base_session.render_markdown_max_lines,
      transcript_compaction = vim.deepcopy(base_session.transcript_compaction or {}),
      runtime_compaction = vim.deepcopy(base_session.runtime_compaction or {}),
      initial_config_applied = true,
      session_info = {},
      usage_stats = {},
    }
  end

  local function stop_ephemeral_client(session, callback)
    release_all_terminals(session)
    local client = session and session.client or nil
    if not client then
      if callback then
        callback()
      end
      return
    end

    local done = function()
      client:stop()
      if callback then
        callback()
      end
    end

    if client:supports_session_close() and client.session_id and client.session_id ~= "" then
      client:close_session(client.session_id, function()
        done()
      end)
      return
    end

    done()
  end

  local function capture_native_session_for_session(session, native_session, on_done)
    local temp_session = create_ephemeral_session(session)
    local finished = false

    local function finish(snapshot, err)
      if finished then
        return
      end
      finished = true
      stop_ephemeral_client(temp_session, function()
        vim.schedule(function()
          on_done(snapshot, err)
        end)
      end)
    end

    temp_session.client = ACPClient.new({
      command = temp_session.command,
      cwd = temp_session.cwd,
      env = temp_session.env,
      mcp_servers = temp_session.mcp_servers,
      mcp_url = temp_session.mcp_url,
      protocol_log_path = temp_session.protocol_log_path,
      v2_adapter = temp_session.v2_adapter,
      client_info = {
        name = "lazyagent",
        title = "lazyagent.nvim",
        version = "0.1.0",
      },
      handlers = {},
      on_update = function(params)
        on_client_update(temp_session, params)
      end,
      on_exit = function(code, signal, stderr_text)
        on_client_exit(temp_session, code, signal, stderr_text)
      end,
    })

    temp_session.client:start(function(client, err)
      if err then
        finish(nil, err)
        return
      end

      client:load_session(native_session.sessionId, function(_, load_err)
        if load_err then
          finish(nil, load_err)
          return
        end

        temp_session.client = client
        temp_session.ready = true
        temp_session.failed = false
        temp_session.session_id = client.session_id
        update_session_info(temp_session, native_session)
        update_session_info(temp_session, {
          sessionId = client.session_id,
          cwd = temp_session.cwd,
        })

        local transcript = ""
        if vim.fn.filereadable(temp_session.transcript_path) == 1 then
          local ok, lines = pcall(vim.fn.readfile, temp_session.transcript_path)
          if ok and lines then
            transcript = table.concat(lines, "\n")
          end
        end

        local transcript_lines = transcript ~= "" and vim.split(transcript, "\n", { plain = true }) or {}
        if #transcript_lines > 0 and transcript_lines[#transcript_lines] == "" then
          table.remove(transcript_lines, #transcript_lines)
        end

        finish({
          provider_from = session.agent_name,
          carryover_label = string.format(
            "an ACP provider session%s",
            native_session.title and native_session.title ~= "" and (" (" .. native_session.title .. ")") or ""
          ),
          transcript_lines = transcript_lines,
          transcript_path = temp_session.transcript_path,
          conversation_timeline = vim.deepcopy(temp_session.conversation_timeline or {}),
          tool_timeline = vim.deepcopy(temp_session.tool_timeline or {}),
          session_info = vim.deepcopy(temp_session.session_info or {}),
        }, nil)
      end)
    end, {
        create_session = false,
      })
  end
  function module.start_client(session, opts)
    opts = opts or {}
    local drain_prompt_queue = opts.drain_prompt_queue
    local handlers = {
      request_permission = function(params, done)
        handle_permission_request(session, params, done)
      end,
      select_auth_method = function(methods, done)
        notify_attention("elicitation", session, "Choose an authentication method")
        select_auth_method(methods, done)
      end,
      read_text_file = function(params)
        return read_text_file(session, params)
      end,
      write_text_file = function(params)
        return write_text_file(session, params)
      end,
      create_terminal = function(params, done)
        create_terminal(session, params, done)
      end,
      terminal_output = function(params)
        return terminal_output(session, params)
      end,
      terminal_wait_for_exit = function(params, done)
        terminal_wait_for_exit(session, params, done)
      end,
      terminal_kill = function(params)
        return terminal_kill(session, params)
      end,
      terminal_release = function(params)
        return terminal_release(session, params)
      end,
    }

    session.client = ACPClient.new({
      command = session.command,
      cwd = session.cwd,
      additional_directories = session.additional_directories,
      env = session.env,
      mcp_servers = session.mcp_servers,
      mcp_url = session.mcp_url,
      protocol_log_path = session.protocol_log_path,
      v2_adapter = session.v2_adapter,
      client_info = {
        name = "lazyagent",
        title = "lazyagent.nvim",
        version = "0.1.0",
      },
      handlers = handlers,
      on_update = function(params)
        on_client_update(session, params)
      end,
      on_protocol_event = function(event)
        session.protocol_events = session.protocol_events or {}
        session.protocol_events[#session.protocol_events + 1] = vim.deepcopy(event)
        while #session.protocol_events > 200 do
          table.remove(session.protocol_events, 1)
        end
        sync_runtime_session(session)
      end,
      on_exit = function(code, signal, stderr_text)
        on_client_exit(session, code, signal, stderr_text)
      end,
    })

    session.client:start(function(client, err, session_result)
      if err then
        session.failed = true
        session.ready = false
        sync_runtime_session(session)
        sync_thread(session, { status = "failed", process_id = vim.NIL })
        append_block(session, "System", "Failed to start ACP session: " .. (err.message or tostring(err)))
        pcall(function()
          require("lazyagent.logic.status").set_waiting(session.agent_name, "ACP error")
        end)
        vim.schedule(function()
          vim.notify("LazyAgent ACP: " .. (err.message or tostring(err)), vim.log.levels.ERROR)
        end)
        return
      end

      session.client = client
      session.ready = true
      session.failed = false
      session.session_id = client.session_id
      update_session_info(session, {
        sessionId = client.session_id,
        cwd = session.cwd,
      })
      session.config_options = vim.deepcopy(client.config_options or (session_result and session_result.configOptions) or {})
      session.agent_info = vim.deepcopy(client.agent_info or {})
      session.agent_capabilities = vim.deepcopy(client.agent_capabilities or {})
      session.auth_methods = vim.deepcopy(client.auth_methods or {})
      session.protocol_events = client:get_protocol_events()
      session.model_catalog = vim.deepcopy((session_result and session_result.models) or {})
      session.mode_catalog = vim.deepcopy((session_result and session_result.modes) or {})
      session.resume_strategy = session_result
          and session_result._meta
          and session_result._meta.lazyagentResumeStrategy
        or "new"
      if session.resume_strategy == "local_carryover" and session.thread_carryover then
        session.pending_switch_history = vim.deepcopy(session.thread_carryover)
      end
      session.thread_carryover = nil
      local prompt_caps = client.agent_capabilities and client.agent_capabilities.promptCapabilities or {}
      session.prompt_supports_embedded_context = prompt_caps and prompt_caps.embeddedContext == true
      session.prompt_supports_image = prompt_caps and prompt_caps.image == true
      session.prompt_supports_audio = prompt_caps and prompt_caps.audio == true
      session.mcp_server_count = #client:_build_mcp_servers()
      sync_runtime_session(session)
      sync_thread(session, {
        status = "active",
        native_session_id = client.session_id,
        process_id = client.pid,
        model = session.model_catalog.currentModelId or session.initial_model or vim.NIL,
        mode = session.mode_catalog.currentModeId or session.default_mode or vim.NIL,
        config = vim.deepcopy(session.config_options or {}),
        metadata = { resume_strategy = session.resume_strategy },
      })
      local agent_name = client.agent_info and (client.agent_info.title or client.agent_info.name) or session.agent_name
      local message = string.format("ACP session ready: %s", agent_name)
      if session_result and session_result.sessionId then
        message = message .. "\nSession ID: " .. session_result.sessionId
      end
      if session.resume_strategy == "native_resume" then
        message = message .. "\nContinuation: native ACP resume"
      elseif session.resume_strategy == "native_load" then
        message = message .. "\nContinuation: native ACP load"
      elseif session.resume_strategy == "local_carryover" then
        message = message .. "\nContinuation: local transcript carryover (native resume/load unavailable)"
      end
      append_block(session, "System", message)
      apply_initial_session_config(session, function()
        local on_ready_actions = session.on_ready_actions or {}
        session.on_ready_actions = {}
        for _, callback in ipairs(on_ready_actions) do
          vim.schedule(function()
            pcall(callback)
          end)
        end
        if #session.prompt_queue > 0 then
          vim.schedule(function()
            if type(drain_prompt_queue) == "function" then
              drain_prompt_queue(session.pane_id)
            end
          end)
        end
      end)
    end, vim.deepcopy(session.session_bootstrap or {}))
  end

  module.terminal_release = terminal_release
  module.release_all_terminals = release_all_terminals
  module.read_text_file = read_text_file
  module.write_text_file = write_text_file
  module.list_all_sessions_for_client = list_all_sessions_for_client
  module.capture_native_session_for_session = capture_native_session_for_session

  return module
end

return M

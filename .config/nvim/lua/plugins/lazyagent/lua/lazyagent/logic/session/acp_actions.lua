local M = {}

function M.setup(deps)
  local state = deps.state
  local acp_logic = deps.acp_logic
  local agent_logic = deps.agent_logic
  local backend_logic = deps.backend_logic
  local cache_logic = deps.cache_logic
  local persistence = deps.persistence
  local tmux = require("lazyagent.tmux")
  local util = deps.util
  local current_editor_session_name = deps.current_editor_session_name
  local current_context_acp_agent = deps.current_context_acp_agent
  local active_acp_agents = deps.active_acp_agents
  local preferred_session_agent = deps.preferred_session_agent
  local resolve_acp_target_agent = deps.resolve_acp_target_agent
  local resolve_acp_switch_target_agent = deps.resolve_acp_switch_target_agent
  local resolve_active_acp_session = deps.resolve_active_acp_session
  local capture_switch_scratch_state = deps.capture_switch_scratch_state
  local resolve_switch_anchor = deps.resolve_switch_anchor
  local normalize_keep_line_limit = deps.normalize_keep_line_limit
  local split_conversation_checkpoint_lines = deps.split_conversation_checkpoint_lines
  local build_conversation_sidecar = deps.build_conversation_sidecar
  local write_provider_switch_snapshot = deps.write_provider_switch_snapshot
  local read_saved_conversation_lines = deps.read_saved_conversation_lines
  local select_saved_conversation = deps.select_saved_conversation
  local persist_conversation_capture = deps.persist_conversation_capture
  local force_close_session = deps.force_close_session
  local with_acp_session = deps.with_acp_session
  local ensure_session = deps.ensure_session
  local start_interactive_session = deps.start_interactive_session
  local backend_supports_persistence = deps.backend_supports_persistence

  local module = {}
  local RESTART_BUNDLE_VERSION = 1

  local function native_session_display_name(session_info)
    if type(session_info) ~= "table" then
      return "unknown ACP session"
    end
    local title = tostring(session_info.title or "")
    if title ~= "" then
      return title
    end
    return tostring(session_info.sessionId or "unknown ACP session")
  end

  local function format_native_session_label(session_info, current_session_id)
    local parts = {}
    local title = native_session_display_name(session_info)
    local status_label = tostring(session_info.statusLabel or session_info.status or "")
    if session_info.sessionId and session_info.sessionId ~= "" and session_info.sessionId == current_session_id then
      title = title .. " [current]"
    end
    if status_label ~= "" then
      title = string.format("%s [%s]", title, status_label)
    end
    parts[#parts + 1] = title

    local summary = tostring(session_info.summary or "")
    if summary ~= "" then
      parts[#parts + 1] = summary
    end

    local cwd = tostring(session_info.cwd or "")
    if cwd ~= "" then
      parts[#parts + 1] = cwd
    end

    local updated_at = tostring(session_info.updatedAt or "")
    if updated_at ~= "" then
      parts[#parts + 1] = updated_at
    end

    if session_info.sessionId and session_info.sessionId ~= "" and session_info.title and session_info.title ~= session_info.sessionId then
      parts[#parts + 1] = session_info.sessionId
    end

    return table.concat(parts, "  --  ")
  end

  local function split_transcript_lines(text)
    if not text or text == "" then
      return {}
    end
    local lines = vim.split(text, "\n", { plain = true })
    if #lines > 0 and lines[#lines] == "" then
      table.remove(lines, #lines)
    end
    return lines
  end

  local function normal_file_path(bufnr)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then
      return nil
    end
    local path = vim.api.nvim_buf_get_name(bufnr)
    if not path or path == "" then
      return nil
    end
    return vim.fn.fnamemodify(path, ":p")
  end

  local function modified_file_buffers()
    local items = {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].buftype == "" and vim.bo[bufnr].modified then
        items[#items + 1] = normal_file_path(bufnr) or ("[No Name " .. tostring(bufnr) .. "]")
      end
    end
    table.sort(items)
    return items
  end

  local function restart_bundle_dir()
    local dir = cache_logic.get_cache_dir() .. "/acp/restart"
    if vim.fn.isdirectory(dir) == 0 then
      vim.fn.mkdir(dir, "p")
    end
    return dir
  end

  local function restart_bundle_path(agent_name)
    local loop = vim.uv or vim.loop
    local stamp = loop and tostring(loop.hrtime()) or tostring(os.time())
    return string.format(
      "%s/%s-%s.json",
      restart_bundle_dir(),
      util.sanitize_filename_component(agent_name or "acp"),
      stamp
    )
  end

  local function write_restart_bundle(path, bundle)
    local ok, encoded = pcall(vim.fn.json_encode, bundle)
    if not ok or not encoded then
      return false
    end
    return pcall(vim.fn.writefile, { encoded }, path)
  end

  local function read_restart_bundle(path)
    if not path or path == "" or vim.fn.filereadable(path) == 0 then
      return nil
    end
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok or type(lines) ~= "table" or #lines == 0 then
      return nil
    end
    local ok_decode, bundle = pcall(vim.fn.json_decode, table.concat(lines, "\n"))
    if not ok_decode or type(bundle) ~= "table" then
      return nil
    end
    return bundle
  end

  local function build_restart_command(bundle_path_value, source_path)
    local argv = { vim.v.progpath }
    if source_path and source_path ~= "" then
      argv[#argv + 1] = source_path
    end
    argv[#argv + 1] = "+LazyAgentACPRestoreRestartState " .. vim.fn.fnameescape(bundle_path_value)
    return "exec " .. table.concat(vim.tbl_map(function(arg)
      return vim.fn.shellescape(tostring(arg))
    end, argv), " ")
  end

  local function cleanup_restart_bundle(bundle_path_value, transcript_path)
    if bundle_path_value and bundle_path_value ~= "" then
      pcall(vim.fn.delete, bundle_path_value)
    end
    if transcript_path and transcript_path ~= "" then
      pcall(vim.fn.delete, transcript_path)
    end
  end

  local function capture_restart_transcript(agent_name, session, backend_mod)
    if backend_mod and type(backend_mod.capture_pane_sync) == "function" then
      local text = backend_mod.capture_pane_sync(session.pane_id) or ""
      local lines = split_transcript_lines(text)
      if #lines > 0 then
        return lines
      end
    end

    local path = session and (session.acp_transcript_path or session.transcript_path) or nil
    if path and path ~= "" then
      return read_saved_conversation_lines(path) or {}
    end

    vim.notify(
      "LazyAgentACP: failed to capture the current transcript for '" .. tostring(agent_name) .. "'",
      vim.log.levels.WARN
    )
    return {}
  end

  local function build_restart_bundle(agent_name, session, backend_mod)
    local runtime_snapshot = type(backend_mod.get_runtime_snapshot) == "function"
      and backend_mod.get_runtime_snapshot(session.pane_id)
      or nil
    local scratch_state = capture_switch_scratch_state(agent_name)
    local anchor = resolve_switch_anchor(runtime_snapshot, scratch_state)
    local source_path = normal_file_path(anchor.source_bufnr)
    local source_cursor = nil
    if anchor.source_winid and vim.api.nvim_win_is_valid(anchor.source_winid) then
      source_cursor = vim.api.nvim_win_get_cursor(anchor.source_winid)
    end

    local transcript_lines = capture_restart_transcript(agent_name, session, backend_mod)
    local transcript_path = nil
    local metadata = {}
    if #transcript_lines > 0 then
      transcript_path = write_provider_switch_snapshot(agent_name, transcript_lines)
      if transcript_path then
        metadata = build_conversation_sidecar(agent_name, session, transcript_path, transcript_lines)
      end
    end

    local model_catalog = runtime_snapshot and runtime_snapshot.acp_model_catalog or session.model_catalog or {}
    local mode_catalog = runtime_snapshot and runtime_snapshot.acp_mode_catalog or session.mode_catalog or {}

    return {
      version = RESTART_BUNDLE_VERSION,
      kind = "lazyagent-acp-restart",
      created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      agent_name = agent_name,
      cwd = session.cwd or (source_path and util.git_root_for_path(source_path)) or vim.fn.getcwd(),
      source_path = source_path,
      source_cursor = source_cursor,
      scratch = {
        was_open = scratch_state and scratch_state.was_open == true or false,
        text = scratch_state and scratch_state.text or "",
      },
      transcript_path = transcript_path,
      conversation_timeline = metadata.conversation_timeline or {},
      tool_timeline = metadata.tool_timeline or {},
      carryover_label = string.format("the ACP conversation from before restart (%s)", agent_name),
      transition_message = string.format(
        "Restored ACP context for %s after restarting Neovim.",
        agent_name
      ),
      acp = {
        auto_permission = session.auto_permission,
        default_mode = (type(mode_catalog) == "table" and mode_catalog.currentModeId) or session.default_mode,
        initial_model = (type(model_catalog) == "table" and model_catalog.currentModelId) or session.initial_model,
      },
    }
  end

  local function resolve_tmux_pane()
    if vim.env.TMUX_PANE and vim.env.TMUX_PANE ~= "" then
      return vim.env.TMUX_PANE
    end

    local ok, lines = pcall(vim.fn.systemlist, { "tmux", "display-message", "-p", "-F", "#{pane_id}" })
    if not ok or vim.v.shell_error ~= 0 or type(lines) ~= "table" then
      return nil
    end
    local pane = lines[1]
    if type(pane) ~= "string" or pane == "" then
      return nil
    end
    return pane
  end

  local function restore_restart_anchor(bundle)
    local source_path = type(bundle.source_path) == "string" and bundle.source_path or nil
    if source_path and source_path ~= "" and vim.fn.filereadable(source_path) == 1 then
      local current_name = vim.api.nvim_buf_get_name(0)
      local current_path = current_name ~= "" and vim.fn.fnamemodify(current_name, ":p") or ""
      local target_path = vim.fn.fnamemodify(source_path, ":p")
      if current_path ~= target_path then
        pcall(vim.cmd.edit, vim.fn.fnameescape(target_path))
      end
    end

    local source_winid = vim.api.nvim_get_current_win()
    local source_bufnr = vim.api.nvim_get_current_buf()
    if type(bundle.source_cursor) == "table" and #bundle.source_cursor >= 2 and vim.api.nvim_win_is_valid(source_winid) then
      local line = math.max(1, tonumber(bundle.source_cursor[1]) or 1)
      local col = math.max(0, tonumber(bundle.source_cursor[2]) or 0)
      pcall(vim.api.nvim_win_set_cursor, source_winid, { line, col })
    end

    return {
      source_bufnr = vim.api.nvim_buf_is_valid(source_bufnr) and source_bufnr or nil,
      source_winid = vim.api.nvim_win_is_valid(source_winid) and source_winid or nil,
    }
  end

  function module.resume_acp_conversation(agent_name)
    local function start_with_path(path)
      if vim.fn.filereadable(path) == 0 then
        vim.notify("LazyAgentACPResumeConversation: file not found: " .. path, vim.log.levels.ERROR)
        return
      end

      local transcript_lines = read_saved_conversation_lines(path) or {}
      local metadata = cache_logic.read_conversation_metadata(path) or {}

      resolve_acp_target_agent(agent_name, function(chosen_agent)
        if not chosen_agent or chosen_agent == "" then
          return
        end

        local chosen_agent_cfg = agent_logic.get_interactive_agent(chosen_agent)
        local _, chosen_backend = backend_logic.resolve_backend_for_agent(chosen_agent, chosen_agent_cfg)
        local chosen_session = state.sessions[chosen_agent]
        if chosen_session and chosen_session.pane_id and chosen_backend
          and type(chosen_backend.is_busy) == "function"
          and chosen_backend.is_busy(chosen_session.pane_id)
        then
          vim.notify("LazyAgentACP: stop the current response before resuming a saved conversation", vim.log.levels.WARN)
          return
        end

        local temp_transcript_path = write_provider_switch_snapshot(metadata.agent_name or chosen_agent, transcript_lines)
        if not temp_transcript_path then
          vim.notify("LazyAgentACPResumeConversation: failed to prepare the saved conversation snapshot", vim.log.levels.WARN)
          return
        end

        local anchor_snapshot = nil
        local context_agent = current_context_acp_agent()
        local context_session = context_agent and state.sessions[context_agent] or nil
        if context_session and context_session.pane_id then
          local _, context_backend = backend_logic.resolve_backend_for_agent(context_agent, agent_logic.get_interactive_agent(context_agent))
          if context_backend and type(context_backend.get_runtime_snapshot) == "function" then
            anchor_snapshot = context_backend.get_runtime_snapshot(context_session.pane_id)
          end
        end
        local anchor = resolve_switch_anchor(anchor_snapshot, nil)

        local next_agent_cfg = vim.tbl_deep_extend("force", chosen_agent_cfg or {}, {
          source_bufnr = anchor.source_bufnr,
          origin_bufnr = anchor.source_bufnr,
          source_winid = anchor.source_winid,
          origin_winid = anchor.source_winid,
        })

        local transition_message = string.format(
          "Added conversation from %s. Previous conversation will be included on the next prompt.",
          vim.fn.fnamemodify(path, ":t")
        )

        local carryover_label = "a saved ACP conversation"
        if metadata.agent_name and metadata.agent_name ~= "" then
          carryover_label = string.format("%s (%s)", carryover_label, metadata.agent_name)
        end

        if chosen_session and chosen_session.pane_id then
          if not chosen_backend or type(chosen_backend.restore_switch_snapshot) ~= "function" then
            pcall(vim.fn.delete, temp_transcript_path)
            vim.notify("LazyAgentACPResumeConversation: backend does not support ACP conversation restore", vim.log.levels.WARN)
            return
          end

          chosen_backend.restore_switch_snapshot(chosen_session.pane_id, {
            provider_from = metadata.agent_name,
            carryover_label = carryover_label,
            transcript_lines = transcript_lines,
            transcript_path = temp_transcript_path,
            conversation_timeline = metadata.conversation_timeline or {},
            tool_timeline = metadata.tool_timeline or {},
            transition_message = transition_message,
            preserve_transcript = true,
          })
          return
        end

        ensure_session(chosen_agent, next_agent_cfg, false, function(new_pane_id)
          local _, next_backend = backend_logic.resolve_backend_for_agent(chosen_agent, next_agent_cfg)
          if not next_backend or type(next_backend.restore_switch_snapshot) ~= "function" then
            pcall(vim.fn.delete, temp_transcript_path)
            vim.notify("LazyAgentACPResumeConversation: backend does not support ACP conversation restore", vim.log.levels.WARN)
            return
          end

          next_backend.restore_switch_snapshot(new_pane_id, {
            provider_from = metadata.agent_name,
            carryover_label = carryover_label,
            transcript_lines = transcript_lines,
            transcript_path = temp_transcript_path,
            conversation_timeline = metadata.conversation_timeline or {},
            tool_timeline = metadata.tool_timeline or {},
            transition_message = transition_message,
          })
        end)
      end)
    end

    select_saved_conversation("Resume ACP conversation:", start_with_path)
  end

  local function start_native_acp_session(agent_name, native_session, mode)
    resolve_active_acp_session(agent_name, function(chosen_agent)
      local current_session = state.sessions[chosen_agent]
      if not current_session or not current_session.pane_id then
        vim.notify("LazyAgentACP: no active session found for '" .. tostring(chosen_agent) .. "'", vim.log.levels.WARN)
        return
      end

      local current_agent_cfg = agent_logic.get_interactive_agent(chosen_agent)
      local _, current_backend = backend_logic.resolve_backend_for_agent(chosen_agent, current_agent_cfg)
      if not current_backend then
        vim.notify("LazyAgentACP: failed to resolve backend for '" .. tostring(chosen_agent) .. "'", vim.log.levels.ERROR)
        return
      end
      if type(current_backend.is_busy) == "function" and current_backend.is_busy(current_session.pane_id) then
        vim.notify("LazyAgentACP: stop the current response before loading a provider session", vim.log.levels.WARN)
        return
      end

      local runtime_snapshot = type(current_backend.get_runtime_snapshot) == "function"
        and current_backend.get_runtime_snapshot(current_session.pane_id)
        or nil
      local current_session_id = runtime_snapshot and runtime_snapshot.acp_session_id or nil
      if current_session_id and native_session.sessionId == current_session_id then
        vim.notify("LazyAgentACP: that provider session is already active", vim.log.levels.INFO)
        return
      end

      local scratch_state = capture_switch_scratch_state(chosen_agent)
      local anchor = resolve_switch_anchor(runtime_snapshot, scratch_state)
      local next_agent_cfg = vim.tbl_deep_extend("force", current_agent_cfg or {}, {
        source_bufnr = anchor.source_bufnr,
        origin_bufnr = anchor.source_bufnr,
        source_winid = anchor.source_winid,
        origin_winid = anchor.source_winid,
        acp = {
          session_bootstrap = {
            session_mode = mode,
            session_id = native_session.sessionId,
          },
        },
      })

      force_close_session(chosen_agent)
      ensure_session(chosen_agent, next_agent_cfg, false, function()
        if scratch_state and scratch_state.was_open then
          start_interactive_session({
            agent_name = chosen_agent,
            reuse = true,
            initial_input = scratch_state.text,
            source_bufnr = anchor.source_bufnr,
            origin_bufnr = anchor.source_bufnr,
            source_winid = anchor.source_winid,
            origin_winid = anchor.source_winid,
          })
        end
      end)
    end)
  end

  local function add_native_acp_session(agent_name, native_session)
    with_acp_session(agent_name, function(chosen_agent, pane_id, backend_mod)
      if not backend_mod or type(backend_mod.capture_native_session) ~= "function" or type(backend_mod.restore_switch_snapshot) ~= "function" then
        vim.notify("LazyAgentACP: backend does not support native ACP session import", vim.log.levels.WARN)
        return
      end

      if type(backend_mod.is_busy) == "function" and backend_mod.is_busy(pane_id) then
        vim.notify("LazyAgentACP: stop the current response before adding a provider session", vim.log.levels.WARN)
        return
      end

      local runtime_snapshot = type(backend_mod.get_runtime_snapshot) == "function"
        and backend_mod.get_runtime_snapshot(pane_id)
        or nil
      local current_session_id = runtime_snapshot and runtime_snapshot.acp_session_id or nil
      if current_session_id and native_session.sessionId == current_session_id then
        vim.notify("LazyAgentACP: that provider session is already active", vim.log.levels.INFO)
        return
      end

      backend_mod.capture_native_session(pane_id, native_session, function(snapshot, err)
        if err then
          vim.notify("LazyAgentACP: failed to import provider session: " .. (err.message or tostring(err)), vim.log.levels.ERROR)
          return
        end

        local session_name = native_session_display_name(native_session)
        backend_mod.restore_switch_snapshot(pane_id, {
          provider_from = chosen_agent,
          carryover_label = string.format("an ACP provider session (%s)", session_name),
          transcript_lines = snapshot and snapshot.transcript_lines or {},
          transcript_path = snapshot and snapshot.transcript_path or nil,
          conversation_timeline = snapshot and snapshot.conversation_timeline or {},
          tool_timeline = snapshot and snapshot.tool_timeline or {},
          transition_message = string.format(
            "Added conversation from ACP session %s. Previous conversation will be included on the next prompt.",
            session_name
          ),
          preserve_transcript = true,
        })
      end)
    end)
  end

  function module.pick_acp_sessions(agent_name)
    with_acp_session(agent_name, function(chosen_agent, pane_id, backend_mod)
      if not backend_mod or type(backend_mod.list_sessions) ~= "function" then
        vim.notify("LazyAgentACP: backend does not expose native ACP sessions", vim.log.levels.WARN)
        return
      end

      local runtime_snapshot = type(backend_mod.get_runtime_snapshot) == "function"
        and backend_mod.get_runtime_snapshot(pane_id)
        or {}
      local capabilities = runtime_snapshot and runtime_snapshot.acp_agent_capabilities or {}
      local session_caps = runtime_snapshot and runtime_snapshot.acp_session_capabilities or {}
      local supports_load = capabilities and capabilities.loadSession == true
      local supports_resume = type(session_caps) == "table" and session_caps.resume ~= nil
      local current_session_id = runtime_snapshot and runtime_snapshot.acp_session_id or nil

      backend_mod.list_sessions(pane_id, function(items, err)
        if err then
          vim.notify("LazyAgentACP: failed to list provider sessions: " .. (err.message or tostring(err)), vim.log.levels.ERROR)
          return
        end
        if not items or vim.tbl_isempty(items) then
          vim.notify("LazyAgentACP: no provider sessions found", vim.log.levels.INFO)
          return
        end

        vim.ui.select(items, {
          prompt = "Choose ACP provider session:",
          format_item = function(item)
            return format_native_session_label(item, current_session_id)
          end,
        }, function(native_session)
          if not native_session then
            return
          end

          local actions = {}
          if supports_load or supports_resume then
            actions[#actions + 1] = {
              label = "Import as LazyAgent thread",
              action = function()
                if type(backend_mod.import_native_session) ~= "function" then
                  vim.notify("LazyAgentACP: backend does not support thread import", vim.log.levels.WARN)
                  return
                end
                local thread, created = backend_mod.import_native_session(pane_id, native_session)
                if not thread then
                  vim.notify("LazyAgentACP: failed to import native session", vim.log.levels.ERROR)
                  return
                end
                vim.notify(
                  created == false
                      and string.format("LazyAgent ACP thread already exists: %s", thread.title)
                    or string.format("Imported LazyAgent ACP thread: %s", thread.title),
                  vim.log.levels.INFO
                )
              end,
            }
          end
          if supports_load then
            actions[#actions + 1] = {
              label = "Add to current conversation",
              action = function()
                add_native_acp_session(chosen_agent, native_session)
              end,
            }
            actions[#actions + 1] = {
              label = "Load into ACP buffer",
              action = function()
                start_native_acp_session(chosen_agent, native_session, "load")
              end,
            }
          end
          if supports_resume then
            actions[#actions + 1] = {
              label = "Resume natively",
              action = function()
                start_native_acp_session(chosen_agent, native_session, "resume")
              end,
            }
          end

          if #actions == 0 then
            vim.notify("LazyAgentACP: this provider exposes sessions but no native load or resume action", vim.log.levels.WARN)
            return
          end

          if #actions == 1 then
            actions[1].action()
            return
          end

          vim.ui.select(actions, {
            prompt = "ACP session action:",
            format_item = function(item)
              return item.label
            end,
          }, function(choice)
            if choice and choice.action then
              choice.action()
            end
          end)
        end)
      end)
    end)
  end

  function module.detach_session(agent_name)
    local function detach(chosen)
      if not chosen or chosen == "" then return end

      local s = state.sessions[chosen]
      if not s or not s.pane_id then
        vim.notify("LazyAgentDetach: no active session for '" .. chosen .. "'", vim.log.levels.WARN)
        return
      end

      local _, backend_mod = backend_logic.resolve_backend_for_agent(chosen, nil)
      local persistable = backend_supports_persistence(s.backend)

      if persistable then
        s.force_resume = true
        persistence.update_session(chosen, s.pane_id, s.cwd)
      end

      if state.open_agent == chosen and deps.window.is_open() then
        local bufnr = deps.window.get_bufnr()
        local preserve_scratch = acp_logic.is_acp_backend(s.backend)
        deps.window.close({ keep_buffer = preserve_scratch })
        if not preserve_scratch and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_delete(bufnr, { force = true })
        end
        state.open_agent = nil
      end

      if not s.hidden then
        if backend_mod and type(backend_mod.break_pane) == "function" then
          if type(backend_mod.get_pane_info) == "function" then
            backend_mod.get_pane_info(s.pane_id, function(info)
              if info then
                s.last_size = info
              end
              backend_mod.break_pane(s.pane_id)
              s.hidden = true
              local label = persistable and "detached and persisted" or "detached for this Neovim session"
              vim.notify("Agent '" .. chosen .. "' " .. label .. ".", vim.log.levels.INFO)
            end)
          else
            backend_mod.break_pane(s.pane_id)
            s.hidden = true
            local label = persistable and "detached and persisted" or "detached for this Neovim session"
            vim.notify("Agent '" .. chosen .. "' " .. label .. ".", vim.log.levels.INFO)
          end
        end
      else
        vim.notify("Agent '" .. chosen .. "' is already detached.", vim.log.levels.INFO)
      end
    end

    agent_logic.resolve_target_agent(agent_name, nil, detach)
  end

  function module.pick_acp_config(agent_name, category)
    with_acp_session(agent_name, function(_, pane_id, backend_mod)
      if not backend_mod or type(backend_mod.show_config_picker) ~= "function" then
        vim.notify("LazyAgentACP: backend does not expose config pickers", vim.log.levels.WARN)
        return
      end
      backend_mod.show_config_picker(pane_id, category)
    end)
  end

  function module.pick_acp_model(agent_name)
    module.pick_acp_config(agent_name, "model")
  end

  function module.pick_acp_mode(agent_name)
    module.pick_acp_config(agent_name, "mode")
  end

  function module.switch_acp_provider(agent_name, target_agent)
    resolve_acp_target_agent(agent_name, function(current_agent)
      if not current_agent or current_agent == "" then
        return
      end

      local current_session = state.sessions[current_agent]
      if not current_session or not current_session.pane_id then
        vim.notify("LazyAgentACP: no active session found for '" .. tostring(current_agent) .. "'", vim.log.levels.WARN)
        return
      end

      local current_agent_cfg = agent_logic.get_interactive_agent(current_agent)
      local _, current_backend = backend_logic.resolve_backend_for_agent(current_agent, current_agent_cfg)
      if not current_backend then
        vim.notify("LazyAgentACP: failed to resolve backend for '" .. tostring(current_agent) .. "'", vim.log.levels.ERROR)
        return
      end
      if type(current_backend.is_busy) == "function" and current_backend.is_busy(current_session.pane_id) then
        vim.notify("LazyAgentACP: stop the current response before switching providers", vim.log.levels.WARN)
        return
      end
      if type(current_backend.capture_pane_sync) ~= "function" then
        vim.notify("LazyAgentACP: backend does not support provider switching", vim.log.levels.WARN)
        return
      end

      resolve_acp_switch_target_agent(current_agent, target_agent, function(next_agent)
        if not next_agent or next_agent == "" then
          return
        end

        local transcript = current_backend.capture_pane_sync(current_session.pane_id) or ""
        local transcript_lines = transcript ~= "" and vim.split(transcript, "\n", { plain = true }) or {}
        if #transcript_lines > 0 and transcript_lines[#transcript_lines] == "" then
          table.remove(transcript_lines, #transcript_lines)
        end

        local transcript_path = nil
        local metadata = nil
        if #transcript_lines > 0 then
          transcript_path = write_provider_switch_snapshot(current_agent, transcript_lines)
          if transcript_path then
            metadata = build_conversation_sidecar(current_agent, current_session, transcript_path, transcript_lines)
          else
            vim.notify("LazyAgentACP: failed to snapshot the current conversation for provider switching", vim.log.levels.WARN)
          end
        end

        local scratch_state = capture_switch_scratch_state(current_agent)
        local runtime_snapshot = type(current_backend.get_runtime_snapshot) == "function"
          and current_backend.get_runtime_snapshot(current_session.pane_id)
          or nil
        local anchor = resolve_switch_anchor(runtime_snapshot, scratch_state)
        local transition_message = string.format(
          "Switched ACP provider from %s to %s. Previous conversation will be included on the next prompt.",
          current_agent,
          next_agent
        )

        local next_agent_cfg = vim.tbl_deep_extend("force", agent_logic.get_interactive_agent(next_agent) or {}, {
          source_bufnr = anchor.source_bufnr,
          origin_bufnr = anchor.source_bufnr,
          source_winid = anchor.source_winid,
          origin_winid = anchor.source_winid,
        })
        local next_backend_name = select(1, backend_logic.resolve_backend_for_agent(next_agent, next_agent_cfg))
        local switch_view = nil
        if current_session.backend == "buffer_acp"
          and next_backend_name == "buffer_acp"
          and type(current_backend.capture_switch_view) == "function"
        then
          switch_view = current_backend.capture_switch_view(current_session.pane_id)
        end
        if switch_view then
          next_agent_cfg.acp_reuse_view = switch_view
        else
          force_close_session(current_agent)
        end

        if state.sessions[next_agent] and state.sessions[next_agent].pane_id then
          force_close_session(next_agent)
        end

        ensure_session(next_agent, next_agent_cfg, false, function(new_pane_id)
          local _, next_backend = backend_logic.resolve_backend_for_agent(next_agent, next_agent_cfg)
          if next_backend and type(next_backend.restore_switch_snapshot) == "function" then
            next_backend.restore_switch_snapshot(new_pane_id, {
              provider_from = current_agent,
              carryover_label = string.format("the previous ACP provider (%s)", current_agent),
              transcript_lines = transcript_lines,
              transcript_path = transcript_path,
              conversation_timeline = metadata and metadata.conversation_timeline or {},
              tool_timeline = metadata and metadata.tool_timeline or {},
              transition_message = transition_message,
            })
          end

          if scratch_state and scratch_state.was_open then
            start_interactive_session({
              agent_name = next_agent,
              reuse = true,
              initial_input = scratch_state.text,
              source_bufnr = anchor.source_bufnr,
              origin_bufnr = anchor.source_bufnr,
              source_winid = anchor.source_winid,
              origin_winid = anchor.source_winid,
            })
          end

          if switch_view then
            force_close_session(current_agent)
          end
        end)
      end)
    end)
  end

  function module.restart_acp_session(agent_name)
    resolve_active_acp_session(agent_name, function(chosen_agent)
      local session = state.sessions[chosen_agent]
      if not session or not session.pane_id or session.pane_id == "" then
        vim.notify("LazyAgentACP: no active session found for '" .. tostring(chosen_agent) .. "'", vim.log.levels.WARN)
        return
      end

      local current_agent_cfg = agent_logic.get_interactive_agent(chosen_agent)
      local _, backend_mod = backend_logic.resolve_backend_for_agent(chosen_agent, current_agent_cfg)
      if not backend_mod then
        vim.notify("LazyAgentACP: failed to resolve backend for '" .. tostring(chosen_agent) .. "'", vim.log.levels.ERROR)
        return
      end
      if type(backend_mod.is_busy) == "function" and backend_mod.is_busy(session.pane_id) then
        vim.notify("LazyAgentACP: stop the current response before restarting Neovim", vim.log.levels.WARN)
        return
      end

      local modified = modified_file_buffers()
      if #modified > 0 then
        local preview = table.concat(vim.list_slice(modified, 1, math.min(#modified, 3)), ", ")
        local suffix = #modified > 3 and " ..." or ""
        vim.notify(
          "LazyAgentACP: save modified buffers before restarting Neovim (" .. preview .. suffix .. ")",
          vim.log.levels.WARN
        )
        return
      end

      local tmux_pane = resolve_tmux_pane()
      if not tmux_pane then
        vim.notify("LazyAgentACP: ACP restart currently requires running Neovim inside tmux", vim.log.levels.WARN)
        return
      end

      local bundle = build_restart_bundle(chosen_agent, session, backend_mod)
      local bundle_path_value = restart_bundle_path(chosen_agent)
      if not write_restart_bundle(bundle_path_value, bundle) then
        cleanup_restart_bundle(bundle_path_value, bundle.transcript_path)
        vim.notify("LazyAgentACP: failed to write the ACP restart bundle", vim.log.levels.ERROR)
        return
      end

      local command = build_restart_command(bundle_path_value, bundle.source_path)
      local ok = tmux.run({
        "respawn-pane",
        "-k",
        "-t",
        tmux_pane,
        "-c",
        bundle.cwd or vim.fn.getcwd(),
        command,
      })
      if not ok then
        cleanup_restart_bundle(bundle_path_value, bundle.transcript_path)
        vim.notify("LazyAgentACP: failed to restart the current tmux pane", vim.log.levels.ERROR)
      end
    end)
  end

  function module.restore_acp_restart_state(bundle_path_value)
    local bundle = read_restart_bundle(bundle_path_value)
    if not bundle then
      vim.notify("LazyAgentACP: restart bundle is missing or invalid", vim.log.levels.ERROR)
      return
    end

    pcall(vim.fn.delete, bundle_path_value)

    vim.schedule(function()
      local agent_name = tostring(bundle.agent_name or "")
      if agent_name == "" then
        vim.notify("LazyAgentACP: restart bundle did not contain an ACP agent", vim.log.levels.ERROR)
        return
      end

      local agent_cfg = agent_logic.get_interactive_agent(agent_name)
      if not agent_cfg then
        vim.notify("LazyAgentACP: unknown ACP agent in restart bundle: " .. agent_name, vim.log.levels.ERROR)
        return
      end

      local anchor = restore_restart_anchor(bundle)
      local next_agent_cfg = vim.tbl_deep_extend("force", agent_cfg or {}, {
        source_bufnr = anchor.source_bufnr,
        origin_bufnr = anchor.source_bufnr,
        source_winid = anchor.source_winid,
        origin_winid = anchor.source_winid,
        acp = {
          auto_permission = bundle.acp and bundle.acp.auto_permission or nil,
          default_mode = bundle.acp and bundle.acp.default_mode or nil,
          initial_model = bundle.acp and bundle.acp.initial_model or nil,
        },
      })

      ensure_session(agent_name, next_agent_cfg, false, function(new_pane_id)
        local _, backend_mod = backend_logic.resolve_backend_for_agent(agent_name, next_agent_cfg)
        if backend_mod and type(backend_mod.restore_switch_snapshot) == "function" then
          local transcript_lines = read_saved_conversation_lines(bundle.transcript_path) or {}
          local transcript_path = bundle.transcript_path
          if transcript_path and transcript_path ~= "" and vim.fn.filereadable(transcript_path) ~= 1 then
            transcript_path = nil
          end
          backend_mod.restore_switch_snapshot(new_pane_id, {
            provider_from = agent_name,
            carryover_label = bundle.carryover_label or string.format("the ACP conversation from before restart (%s)", agent_name),
            transcript_lines = transcript_lines,
            transcript_path = transcript_path,
            conversation_timeline = bundle.conversation_timeline or {},
            tool_timeline = bundle.tool_timeline or {},
            transition_message = bundle.transition_message
              or string.format("Restored ACP context for %s after restarting Neovim.", agent_name),
          })
        elseif bundle.transcript_path and bundle.transcript_path ~= "" then
          pcall(vim.fn.delete, bundle.transcript_path)
        end

        if bundle.scratch and bundle.scratch.was_open then
          start_interactive_session({
            agent_name = agent_name,
            reuse = true,
            initial_input = bundle.scratch.text or "",
            source_bufnr = anchor.source_bufnr,
            origin_bufnr = anchor.source_bufnr,
            source_winid = anchor.source_winid,
            origin_winid = anchor.source_winid,
          })
        end
      end)
    end)
  end

  function module.available_acp_switch_targets(agent_name)
    local current_agent = agent_name
    if not current_agent or current_agent == "" then
      current_agent = current_context_acp_agent()
    end
    if (not current_agent or current_agent == "") and #active_acp_agents() == 1 then
      current_agent = active_acp_agents()[1]
    end
    if not current_agent or current_agent == "" then
      current_agent = preferred_session_agent(current_editor_session_name())
    end

    local candidates = {}
    for _, name in ipairs(agent_logic.available_acp_agents()) do
      if name ~= current_agent then
        candidates[#candidates + 1] = name
      end
    end
    return candidates
  end

  function module.pick_acp_commands(agent_name)
    with_acp_session(agent_name, function(_, pane_id, backend_mod)
      if not backend_mod or type(backend_mod.show_command_palette) ~= "function" then
        vim.notify("LazyAgentACP: backend does not expose a command palette", vim.log.levels.WARN)
        return
      end
      backend_mod.show_command_palette(pane_id)
    end)
  end

  function module.show_acp_tool_timeline(agent_name)
    with_acp_session(agent_name, function(_, pane_id, backend_mod)
      if not backend_mod or type(backend_mod.show_tool_timeline) ~= "function" then
        vim.notify("LazyAgentACP: backend does not expose a tool timeline", vim.log.levels.WARN)
        return
      end
      backend_mod.show_tool_timeline(pane_id)
    end)
  end

  function module.pick_acp_resources(agent_name)
    with_acp_session(agent_name, function(_, pane_id, backend_mod)
      if not backend_mod or type(backend_mod.show_resource_browser) ~= "function" then
        vim.notify("LazyAgentACP: backend does not expose a resource browser", vim.log.levels.WARN)
        return
      end
      backend_mod.show_resource_browser(pane_id)
    end)
  end

  function module.show_acp_capabilities(agent_name)
    with_acp_session(agent_name, function(_, pane_id, backend_mod)
      if not backend_mod or type(backend_mod.show_capabilities) ~= "function" then
        vim.notify("LazyAgentACP: backend does not expose a capability report", vim.log.levels.WARN)
        return
      end
      backend_mod.show_capabilities(pane_id)
    end)
  end

  function module.show_acp_doctor(agent_name)
    with_acp_session(agent_name, function(_, pane_id, backend_mod)
      if not backend_mod or type(backend_mod.show_doctor) ~= "function" then
        vim.notify("LazyAgentACP: backend does not expose ACP doctor diagnostics", vim.log.levels.WARN)
        return
      end
      backend_mod.show_doctor(pane_id)
    end)
  end

  function module.show_acp_context_budget(agent_name)
    with_acp_session(agent_name, function(_, pane_id, backend_mod)
      if not backend_mod or type(backend_mod.show_context_budget) ~= "function" then
        vim.notify("LazyAgentACP: backend does not expose a context budget report", vim.log.levels.WARN)
        return
      end
      backend_mod.show_context_budget(pane_id)
    end)
  end

  function module.show_acp_tool_review(agent_name)
    with_acp_session(agent_name, function(_, pane_id, backend_mod)
      if not backend_mod or type(backend_mod.show_tool_review) ~= "function" then
        vim.notify("LazyAgentACP: backend does not expose a tool review report", vim.log.levels.WARN)
        return
      end
      backend_mod.show_tool_review(pane_id)
    end)
  end

  function module.toggle_acp_follow(agent_name)
    with_acp_session(agent_name, function(_, pane_id, backend_mod)
      if not backend_mod or type(backend_mod.toggle_follow_agent) ~= "function" then
        vim.notify("LazyAgentACP: backend does not support Follow Agent", vim.log.levels.WARN)
        return
      end
      local enabled, err = backend_mod.toggle_follow_agent(pane_id)
      if enabled == nil then
        vim.notify("LazyAgentACP: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      vim.notify("LazyAgent ACP Follow Agent: " .. (enabled and "ON" or "OFF"), vim.log.levels.INFO)
    end)
  end

  function module.open_raw_transcript(agent_name)
    with_acp_session(agent_name, function(chosen, pane_id, backend_mod)
      local session = state.sessions[chosen]
      local path = session and (session.acp_transcript_path or session.transcript_path) or nil

      if (not path or path == "") and backend_mod and type(backend_mod.get_runtime_snapshot) == "function" then
        local snapshot = backend_mod.get_runtime_snapshot(pane_id)
        path = snapshot and (snapshot.acp_transcript_path or snapshot.transcript_path) or nil
        if session and path and path ~= "" then
          session.acp_transcript_path = path
        end
      end

      if not path or path == "" or vim.fn.filereadable(path) ~= 1 then
        vim.notify("LazyAgentACP: raw transcript is unavailable for '" .. tostring(chosen) .. "'", vim.log.levels.WARN)
        return
      end

      util.open_in_normal_win(path)
      vim.cmd("setlocal nowrap")
    end)
  end

  function module.open_full_transcript(agent_name)
    with_acp_session(agent_name, function(chosen, pane_id, backend_mod)
      if backend_mod and type(backend_mod.open_fullscreen_transcript) == "function" then
        if backend_mod.open_fullscreen_transcript(pane_id) then
          return
        end
      end

      vim.notify("LazyAgentACP: fullscreen transcript view is unavailable for '" .. tostring(chosen) .. "'", vim.log.levels.WARN)
    end)
  end

  function module.save_conversation_checkpoint(arg1, arg2)
    local agent_name, keep_line_limit
    if normalize_keep_line_limit(arg1) then
      keep_line_limit = normalize_keep_line_limit(arg1)
      agent_name = arg2
    elseif tonumber(arg1) then
      vim.notify("LazyAgentConversation: keep line count must be a positive number", vim.log.levels.WARN)
      return
    elseif normalize_keep_line_limit(arg2) then
      keep_line_limit = normalize_keep_line_limit(arg2)
      agent_name = arg1
    elseif tonumber(arg2) then
      vim.notify("LazyAgentConversation: keep line count must be a positive number", vim.log.levels.WARN)
      return
    else
      agent_name = arg1
    end

    resolve_active_acp_session(agent_name, function(chosen)
      local session = state.sessions[chosen]
      if not session or not session.pane_id or session.pane_id == "" then
        vim.notify("LazyAgentConversation: no active ACP session found for '" .. tostring(chosen) .. "'", vim.log.levels.WARN)
        return
      end

      local _, backend_mod = backend_logic.resolve_backend_for_agent(chosen, agent_logic.get_interactive_agent(chosen))
      if not backend_mod or type(backend_mod.capture_pane) ~= "function" then
        vim.notify("LazyAgentConversation: backend cannot capture this ACP session", vim.log.levels.WARN)
        return
      end
      if type(backend_mod.clear_transcript) ~= "function" then
        vim.notify("LazyAgentConversation: backend cannot clear this ACP transcript", vim.log.levels.WARN)
        return
      end

      backend_mod.capture_pane(session.pane_id, function(text)
        vim.schedule(function()
          if not text or text == "" then
            vim.notify("LazyAgentConversation: captured conversation was empty for agent '" .. tostring(chosen) .. "'", vim.log.levels.INFO)
            return
          end

          local current = state.sessions[chosen]
          if not current or not current.pane_id or current.pane_id == "" then
            return
          end

          local lines = vim.split(text, "\n")
          local lines_to_save = lines
          local lines_to_keep = {}
          if keep_line_limit then
            lines_to_save, lines_to_keep = split_conversation_checkpoint_lines(lines, keep_line_limit)
            if #lines_to_save == 0 then
              vim.notify(
                "LazyAgentConversation: no older User-bounded transcript found beyond the newest "
                  .. keep_line_limit
                  .. " lines",
                vim.log.levels.INFO
              )
              return
            end
          end

          local path = persist_conversation_capture(chosen, current, lines_to_save, {
            merge_with_last_save = current.merge_conversation_on_next_save,
          })
          if not path or path == "" then
            return
          end

          local replacement = keep_line_limit and table.concat(lines_to_keep, "\n") or nil
          if not backend_mod.clear_transcript(current.pane_id, replacement) then
            vim.notify("LazyAgentConversation: saved conversation but failed to update ACP transcript", vim.log.levels.ERROR)
            return
          end

          current.merge_conversation_on_next_save = true
          local msg = "LazyAgentConversation: saved conversation to " .. path .. " and cleared ACP transcript"
          if keep_line_limit then
            msg = "LazyAgentConversation: saved older conversation to "
              .. path
              .. " and kept "
              .. #lines_to_keep
              .. " recent ACP lines"
          end
          vim.notify(msg, vim.log.levels.INFO)
        end)
      end)
    end)
  end

  return module
end

return M

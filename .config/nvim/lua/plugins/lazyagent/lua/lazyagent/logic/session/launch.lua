local M = {}

function M.setup(deps)
  local state = deps.state
  local acp_logic = deps.acp_logic
  local agent_logic = deps.agent_logic
  local backend_logic = deps.backend_logic
  local keymaps_logic = deps.keymaps_logic
  local send_logic = deps.send_logic
  local skills_logic = deps.skills_logic
  local window = deps.window
  local persistence = deps.persistence
  local util = deps.util
  local call_watch = deps.call_watch
  local maybe_disable_watchers = deps.maybe_disable_watchers
  local current_editor_session_name = deps.current_editor_session_name
  local mark_session_scope = deps.mark_session_scope

  local module = {}

  local function watch_enabled_for_session(agent_cfg, backend_name)
    if agent_cfg and agent_cfg.watch ~= nil then
      return agent_cfg.watch
    end
    if acp_logic.is_acp_backend(backend_name) then
      return (((state.opts or {}).hooks or {}).reload_mode == "watch")
    end
    return true
  end

  local function auto_follow_mode_for_session(agent_cfg, backend_name)
    if acp_logic.is_acp_backend(backend_name) then
      return nil
    end
    return (agent_cfg and agent_cfg.auto_follow) or (state.opts and state.opts.auto_follow)
  end

  local function serialize_launch_command(command)
    if type(command) == "table" then
      return vim.json.encode(command)
    end
    return tostring(command or "")
  end

  function module.backend_supports_persistence(backend_name)
    return not acp_logic.is_acp_backend(backend_name)
  end

  local function merge_env(base, extra)
    local merged = vim.tbl_extend("force", {}, base or {})
    for key, value in pairs(extra or {}) do
      merged[key] = value
    end
    return merged
  end

  local function resolve_source_bufnr(agent_cfg)
    local bufnr = agent_cfg and (agent_cfg.source_bufnr or agent_cfg.origin_bufnr) or nil
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      return bufnr
    end
    return vim.api.nvim_get_current_buf()
  end

  local function resolve_root_dir(agent_cfg)
    local source_bufnr = resolve_source_bufnr(agent_cfg)
    local source_path = vim.api.nvim_buf_get_name(source_bufnr)
    return util.git_root_for_path(source_path) or vim.fn.getcwd()
  end

  local function build_acp_split_opts(agent_name, agent_cfg, launch_spec, split_opts)
    local root_dir = resolve_root_dir(agent_cfg)
    local env = merge_env(agent_cfg and agent_cfg.env, split_opts.env)
    local acp = acp_logic.resolve(agent_name, agent_cfg)

    return {
      agent_name = agent_name,
      agent_cfg = agent_cfg,
      command = launch_spec.command,
      source_bufnr = resolve_source_bufnr(agent_cfg),
      source_winid = agent_cfg and (agent_cfg.source_winid or agent_cfg.origin_winid) or nil,
      cwd = root_dir,
      root_dir = root_dir,
      env = env,
      auto_permission = acp.auto_permission,
      default_mode = acp.default_mode,
      initial_model = acp.initial_model,
      fancy_mode = acp.fancy_mode,
      table_layout = acp.table_layout,
      release_buffer_on_hide = acp.release_buffer_on_hide,
      footer_animation = acp.footer_animation,
      buffer_background = acp.buffer_background,
      buffer_inactive_background = acp.buffer_inactive_background,
      transcript_max_lines = acp.transcript_max_lines,
      transcript_compaction = vim.deepcopy(acp.transcript_compaction or {}),
      runtime_compaction = vim.deepcopy(acp.runtime_compaction or {}),
      permission_rules = acp.permission_rules,
      auto_switch = acp.auto_switch,
      session_bootstrap = vim.deepcopy(acp.session_bootstrap),
      reuse_view = agent_cfg and agent_cfg.acp_reuse_view or nil,
    }
  end

  function module.ensure_session(agent_name, agent_cfg, reuse, on_ready)
    local launch_spec, launch_err = agent_logic.resolve_launch_spec(agent_name, agent_cfg)
    local root_dir = resolve_root_dir(agent_cfg)
    local skills_launch = skills_logic.prepare(agent_name, agent_cfg, {
      root_dir = root_dir,
    })
    if launch_spec and skills_launch and skills_launch.append_args and not vim.tbl_isempty(skills_launch.append_args) then
      launch_spec = vim.tbl_deep_extend("force", {}, launch_spec, {
        command = skills_logic.apply_command(launch_spec.command, skills_launch.append_args),
      })
    end
    local existing_session = state.sessions[agent_name]
    if not launch_spec and not (existing_session and existing_session.pane_id) then
      vim.notify("LazyAgent: " .. tostring(launch_err or "launch command is not configured"), vim.log.levels.ERROR)
      return
    end

    local backend_name, backend_mod = backend_logic.resolve_backend_for_agent(agent_name, agent_cfg)
    local requested_launch_cmd = launch_spec and launch_spec.command or nil
    local requested_launch_key = serialize_launch_command(requested_launch_cmd)

    if module.backend_supports_persistence(backend_name)
      and not (state.sessions[agent_name] and state.sessions[agent_name].pane_id)
    then
      local persisted_pane = persistence.get_session(agent_name)
      if persisted_pane and persisted_pane ~= "" then
        if backend_mod and type(backend_mod.pane_exists) == "function" and backend_mod.pane_exists(persisted_pane) then
          local watch_enabled_val = watch_enabled_for_session(agent_cfg, backend_name)
          state.sessions[agent_name] = {
            pane_id = persisted_pane,
            last_output = "",
            backend = backend_name,
            watch_enabled = watch_enabled_val,
            launch_cmd = requested_launch_key,
            hidden = true,
            cwd = vim.fn.getcwd(),
            session_scope = current_editor_session_name(),
          }
          if watch_enabled_val then
            call_watch("enable")
          end
          local follow_mode = auto_follow_mode_for_session(agent_cfg, backend_name)
          if follow_mode then
            call_watch("start_follow", {
              mode = (type(follow_mode) == "string") and follow_mode or "split",
              dir = vim.fn.getcwd(),
            })
          end
          if backend_mod and type(backend_mod.configure_pane) == "function" then
            local refocus = (agent_cfg and agent_cfg.refocus_on_send) or (state.opts and state.opts.refocus_on_send) or false
            backend_mod.configure_pane(persisted_pane, { refocus_on_send = refocus })
          end
        else
          persistence.remove_session(agent_name)
        end
      end
    end

    if reuse and state.sessions[agent_name] and state.sessions[agent_name].pane_id and state.sessions[agent_name].pane_id ~= "" then
      if acp_logic.is_acp_backend(backend_name)
        and backend_name == "buffer_acp"
        and not state.sessions[agent_name].hidden
        and backend_mod
        and type(backend_mod.get_pane_info) == "function"
      then
        local pane_info = backend_mod.get_pane_info(state.sessions[agent_name].pane_id)
        if not pane_info then
          state.sessions[agent_name].hidden = true
        end
      end

      if agent_cfg.stay_hidden and not state.sessions[agent_name].hidden then
        if backend_mod and type(backend_mod.break_pane) == "function" then
          backend_mod.break_pane(state.sessions[agent_name].pane_id)
          state.sessions[agent_name].hidden = true
        end
      end

      if state.sessions[agent_name].hidden then
        local should_keep_hidden = agent_cfg.stay_hidden
        if should_keep_hidden == nil and state.sessions[agent_name].mode == "instant" then
          should_keep_hidden = true
        end

        if should_keep_hidden then
          on_ready(state.sessions[agent_name].pane_id)
          return
        end

        if backend_mod and type(backend_mod.join_pane) == "function" then
          if type(backend_mod.configure_pane) == "function" then
            local refocus = (agent_cfg and agent_cfg.refocus_on_send) or (state.opts and state.opts.refocus_on_send) or false
            backend_mod.configure_pane(state.sessions[agent_name].pane_id, {
              refocus_on_send = refocus,
              source_winid = agent_cfg and (agent_cfg.source_winid or agent_cfg.origin_winid) or nil,
            })
          end
          local size_arg = agent_cfg.pane_size or 30
          backend_mod.join_pane(state.sessions[agent_name].pane_id, size_arg, agent_cfg.is_vertical or false, function(success)
            if success then
              state.sessions[agent_name].hidden = false
              state.sessions[agent_name].mode = nil
              vim.defer_fn(function()
                on_ready(state.sessions[agent_name].pane_id)
              end, 50)
            else
              vim.notify("LazyAgent: failed to restore session pane", vim.log.levels.ERROR)
              on_ready(state.sessions[agent_name].pane_id)
            end
          end)
          return
        end
      end

      state.sessions[agent_name].watch_enabled = watch_enabled_for_session(agent_cfg, backend_name)

      mark_session_scope(agent_name)

      if state.sessions[agent_name].watch_enabled then
        call_watch("enable")
      end

      if not state.sessions[agent_name].watch_enabled then
        maybe_disable_watchers()
      end

      if state.sessions[agent_name].launch_cmd and requested_launch_key and state.sessions[agent_name].launch_cmd ~= requested_launch_key then
        -- fall through to create a new session
      else
        if backend_mod and type(backend_mod.pane_exists) == "function" then
          if backend_mod.pane_exists(state.sessions[agent_name].pane_id) then
            if type(backend_mod.configure_pane) == "function" then
              local refocus = (agent_cfg and agent_cfg.refocus_on_send) or (state.opts and state.opts.refocus_on_send) or false
              backend_mod.configure_pane(state.sessions[agent_name].pane_id, {
                refocus_on_send = refocus,
                source_winid = agent_cfg and (agent_cfg.source_winid or agent_cfg.origin_winid) or nil,
              })
            end
            on_ready(state.sessions[agent_name].pane_id)
            return
          end
        else
          on_ready(state.sessions[agent_name].pane_id)
          return
        end
      end
    end

    local split_opts
    split_opts = {
      on_split = function(pane_id)
        if not pane_id or pane_id == "" then
          vim.notify("Failed to create pane for agent " .. tostring(agent_name), vim.log.levels.ERROR)
          return
        end

        local watch_enabled_val = watch_enabled_for_session(agent_cfg, backend_name)

        local mode = nil
        if agent_cfg and agent_cfg.stay_hidden then mode = "instant" end
        if agent_cfg and agent_cfg.mode then mode = agent_cfg.mode end
        local resolved_acp = acp_logic.resolve(agent_name, agent_cfg)

        state.sessions[agent_name] = {
          pane_id = pane_id,
          last_output = "",
          backend = backend_name,
          watch_enabled = watch_enabled_val,
          launch_cmd = requested_launch_key,
          cwd = root_dir,
          session_scope = current_editor_session_name(),
          footer_animation = resolved_acp.footer_animation,
          fancy_mode = resolved_acp.fancy_mode,
          buffer_background = resolved_acp.buffer_background,
          buffer_inactive_background = resolved_acp.buffer_inactive_background,
          release_buffer_on_hide = resolved_acp.release_buffer_on_hide,
          transcript_max_lines = resolved_acp.transcript_max_lines,
          transcript_compaction = vim.deepcopy(resolved_acp.transcript_compaction or {}),
          runtime_compaction = vim.deepcopy(resolved_acp.runtime_compaction or {}),
          hidden = (agent_cfg.stay_hidden == true),
          mode = mode,
        }
        if watch_enabled_val then
          call_watch("enable")
        end

        local follow_mode = auto_follow_mode_for_session(agent_cfg, backend_name)
        if follow_mode then
          call_watch("start_follow", {
            mode = (type(follow_mode) == "string") and follow_mode or "split",
            dir = vim.fn.getcwd(),
          })
        end

        if backend_mod and type(backend_mod.configure_pane) == "function" then
          local refocus = (agent_cfg and agent_cfg.refocus_on_send) or (state.opts and state.opts.refocus_on_send) or false
          backend_mod.configure_pane(pane_id, {
            refocus_on_send = refocus,
            source_winid = agent_cfg and (agent_cfg.source_winid or agent_cfg.origin_winid) or nil,
          })
        end

        local resume_enabled = (agent_cfg and agent_cfg.resume) or (state.opts and state.opts.resume)
        if resume_enabled and module.backend_supports_persistence(backend_name) then
          persistence.update_session(agent_name, pane_id, state.sessions[agent_name].cwd)
        end

        if agent_cfg.stay_hidden and not split_opts.target_session then
          if backend_mod and type(backend_mod.break_pane) == "function" then
            backend_mod.break_pane(pane_id)
            state.sessions[agent_name].hidden = true
          end
        end

        local init_send = agent_cfg and agent_cfg.initial_send
        if not acp_logic.is_acp_backend(backend_name) then
          init_send = init_send or (state.opts and state.opts.mcp_mode and state.opts.mcp_initial_send)
        end
        if init_send and init_send ~= "" then
          local delay_ms = (agent_cfg and agent_cfg.initial_send_delay) or (state.opts and state.opts.initial_send_delay) or 3000
          vim.defer_fn(function()
            local s = state.sessions[agent_name]
            if not s or not s.pane_id then return end
            local _, bmod = backend_logic.resolve_backend_for_agent(agent_name, agent_cfg)
            if bmod and type(bmod.paste_and_submit) == "function" then
              bmod.paste_and_submit(s.pane_id, init_send, agent_cfg.submit_keys, {})
            end
          end, delay_ms)
        end

        vim.defer_fn(function()
          util.fire_event("SessionStarted", { agent_name = agent_name, pane_id = pane_id })
          on_ready(pane_id)
        end, 200)
      end,
    }

    if agent_cfg.stay_hidden then
      split_opts.target_session = "lazyagent-pool"
    end

    local function do_split()
      split_opts.env = split_opts.env or {}
      if skills_launch and skills_launch.env then
        split_opts.env = merge_env(split_opts.env, skills_launch.env)
      end
      do
        local ok, server = pcall(function() return vim.v.servername end)
        if ok and server and server ~= "" then
          split_opts.env.NVIM_LISTEN_ADDRESS = split_opts.env.NVIM_LISTEN_ADDRESS or server
        else
          local e = (vim.env and vim.env.NVIM_LISTEN_ADDRESS) or nil
          if e and e ~= "" then
            split_opts.env.NVIM_LISTEN_ADDRESS = split_opts.env.NVIM_LISTEN_ADDRESS or e
          end
        end
      end

      if acp_logic.is_acp_backend(backend_name) then
        split_opts.acp = build_acp_split_opts(agent_name, agent_cfg, launch_spec, split_opts)
        backend_mod.split(nil, agent_cfg.pane_size or 30, agent_cfg.is_vertical or false, split_opts)
        return
      end

      if state.opts and state.opts.mcp_mode and state.opts._mcp_url then
        split_opts.env.LAZYAGENT_MCP_URL = state.opts._mcp_url
      end

      local launch_cmd = requested_launch_cmd
      if state.opts and state.opts.mcp_mode then
        local cache_dir = (state.opts.cache and state.opts.cache.dir) or (vim.fn.stdpath("cache") .. "/lazyagent")
        local agent_cache_dir = cache_dir .. "/agents/" .. string.lower(agent_name or "")
        pcall(vim.fn.mkdir, agent_cache_dir, "p")

        local is_gemini = (agent_name == "Gemini")
          or (agent_cfg and agent_cfg.cmd and tostring(agent_cfg.cmd):lower():match("gemini"))

        if is_gemini then
          if state.opts._mcp_type == "http" and state.opts._mcp_url then
            local write_url = state.opts._mcp_url
            local gem_entry = { mcpServers = { lazyagent = { url = write_url, httpUrl = write_url, type = "http" } } }
            local sys_path = agent_cache_dir .. "/system-defaults.json"
            local function try_read(p)
              local fh = io.open(p, "r")
              if not fh then return nil end
              local ok, parsed = pcall(vim.fn.json_decode, fh:read("*a"))
              fh:close()
              if ok and type(parsed) == "table" then return parsed end
              return nil
            end
            local g_system = try_read("/etc/gemini-cli/system-defaults.json")
            local sys_data
            if g_system then
              sys_data = {}
              local user_default = try_read(vim.fn.expand("~/.gemini/settings.json"))
              for k, v in pairs(g_system) do sys_data[k] = v end
              if user_default then for k, v in pairs(user_default) do sys_data[k] = v end end
              sys_data.mcpServers = sys_data.mcpServers or {}
              for k, v in pairs(gem_entry.mcpServers) do sys_data.mcpServers[k] = v end
              if sys_data.general and type(sys_data.general) == "table" then
                sys_data.general.disableAutoUpdate = nil
                sys_data.general.disableUpdateNag = nil
              end
            else
              sys_data = { mcpServers = gem_entry.mcpServers }
            end
            local hooks_dir = agent_cache_dir .. "/hooks"
            sys_data.hooks = {
              BeforeAgent = {{
                matcher = "",
                hooks = {{ name = "notify-start", type = "command", command = hooks_dir .. "/notify-start.sh", timeout = 10000 }},
              }},
              AfterAgent = {{
                matcher = "",
                hooks = {{ name = "notify-done", type = "command", command = hooks_dir .. "/notify-done.sh", timeout = 10000 }},
              }},
              AfterTool = {{
                matcher = "write_file|replace",
                hooks = {{ name = "open-file", type = "command", command = hooks_dir .. "/open-file.sh", timeout = 10000 }},
              }},
            }

            local fw = io.open(sys_path, "w")
            if fw then fw:write(vim.fn.json_encode(sys_data)); fw:close() end
            split_opts.env.GEMINI_CLI_SYSTEM_DEFAULTS_PATH = sys_path
          end

          do
            local function read_text(p)
              local fh = io.open(p, "r")
              if not fh then return nil end
              local s = fh:read("*a")
              fh:close()
              return s
            end
            local agent_md = read_text(agent_cache_dir .. "/AGENTS.md") or ""
            local existing_sys = read_text(agent_cache_dir .. "/system.md") or ""
            local sys_content
            if agent_md ~= "" then
              sys_content = agent_md
            else
              sys_content = (existing_sys ~= "" and existing_sys) or (read_text(cache_dir .. "/default_instructions.md") or "")
            end
            local system_md_path = agent_cache_dir .. "/system.md"
            local sf = io.open(system_md_path, "w")
            if sf then sf:write(sys_content); sf:close() end
            vim.notify(string.format("[lazyagent] wrote system.md -> %s (%d bytes)", system_md_path, #sys_content), vim.log.levels.DEBUG)
            split_opts.env.GEMINI_SYSTEM_MD = system_md_path
          end
        end

        if agent_name == "Copilot" or (agent_cfg and agent_cfg.cmd and tostring(agent_cfg.cmd):match("copilot")) then
          split_opts.env.COPILOT_CONFIG_DIR = agent_cache_dir
          split_opts.env.COPILOT_CUSTOM_INSTRUCTIONS_DIRS = agent_cache_dir
          launch_cmd = (launch_cmd or "") .. " --additional-mcp-config " .. vim.fn.shellescape("@" .. agent_cache_dir .. "/mcp-config.json")
          launch_cmd = launch_cmd .. " --plugin-dir " .. vim.fn.shellescape(agent_cache_dir)
        end
      end
      backend_mod.split(launch_cmd, agent_cfg.pane_size or 30, agent_cfg.is_vertical or false, split_opts)
    end

    if not acp_logic.is_acp_backend(backend_name) and state.opts and state.opts.mcp_mode and not state.opts._mcp_url then
      local max_attempts = 50
      local attempts = 0
      local function wait_for_mcp()
        attempts = attempts + 1
        if state.opts._mcp_url then
          do_split()
        elseif attempts < max_attempts then
          vim.defer_fn(wait_for_mcp, 100)
        else
          vim.notify("LazyAgent: MCP server URL not ready; starting agent without MCP", vim.log.levels.WARN)
          do_split()
        end
      end
      wait_for_mcp()
    else
      do_split()
    end
  end

  function module.start_interactive_session(opts)
    opts = opts or {}
    local agent_name = opts.agent_name or opts.name
    if not agent_name or agent_name == "" then
      local hint = opts.name or opts.agent_hint or nil
      agent_logic.resolve_target_agent(nil, hint, function(chosen)
        if not chosen or chosen == "" then return end
        opts.agent_name = chosen
        module.start_interactive_session(opts)
      end)
      return
    end

    local base_agent_cfg = agent_logic.get_interactive_agent(agent_name)
    local agent_cfg = vim.tbl_deep_extend("force", base_agent_cfg or {}, opts or {})
    local origin_bufnr = opts.source_bufnr or opts.origin_bufnr or vim.api.nvim_get_current_buf()
    local origin_winid = opts.source_winid or opts.origin_winid or vim.api.nvim_get_current_win()
    agent_cfg.source_bufnr = origin_bufnr
    agent_cfg.origin_bufnr = origin_bufnr
    agent_cfg.source_winid = origin_winid
    agent_cfg.origin_winid = origin_winid

    local launch_spec, launch_err = agent_logic.resolve_launch_spec(agent_name, agent_cfg)
    local has_running_session = state.sessions[agent_name] and state.sessions[agent_name].pane_id
    if not launch_spec and not has_running_session then
      vim.notify("interactive agent " .. tostring(agent_name) .. ": " .. tostring(launch_err or "launch command is not configured"), vim.log.levels.ERROR)
      return
    end

    local reuse = opts.reuse ~= false
    if opts.reuse == nil and agent_cfg and agent_cfg.yolo then
      reuse = false
    end
    local backend_name = select(1, backend_logic.resolve_backend_for_agent(agent_name, agent_cfg))
    local preserve_scratch = acp_logic.is_acp_backend(backend_name)
    module.ensure_session(agent_name, agent_cfg, reuse, function(pane_id)
      if opts.open_input == false then
        send_logic.send_and_close_if_needed(agent_name, pane_id, opts.initial_input, agent_cfg, reuse, origin_bufnr)
        return
      end

      local bufnr = window.ensure_scratch_buffer(window.get_scratch_bufnr(agent_name), {
        agent_name = agent_name,
        filetype = agent_cfg.scratch_filetype or "lazyagent",
        source_bufnr = origin_bufnr,
      })
      pcall(function() vim.b[bufnr].lazyagent_agent = agent_name end)

      keymaps_logic.register_scratch_keymaps(bufnr, {
        agent_name = agent_name,
        agent_cfg = agent_cfg,
        pane_id = pane_id,
        reuse = reuse,
        source_bufnr = origin_bufnr,
      })

      state.open_agent = agent_name
      local open_opts = { window_type = agent_cfg.window_type or state.opts.window_type }
      if agent_cfg and agent_cfg.start_in_insert_on_focus ~= nil then
        open_opts.start_in_insert_on_focus = agent_cfg.start_in_insert_on_focus
      else
        open_opts.start_in_insert_on_focus = (state.opts and state.opts.start_in_insert_on_focus) or false
      end
      open_opts.is_vertical = agent_cfg.is_vertical or false
      open_opts.parent_winid = origin_winid

      if opts.window_opts then
        open_opts.window_opts = opts.window_opts
      end
      if opts.title then
        open_opts.title = opts.title
      end
      open_opts.agent_name = agent_name
      open_opts.close_on_focus_lost = preserve_scratch
      open_opts.on_close = function()
        if state.open_agent == agent_name then
          state.open_agent = nil
        end
      end

      window.open(bufnr, open_opts)

      if opts.initial_input and opts.initial_input ~= "" then
        vim.schedule(function()
          if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(opts.initial_input, "\n"))
          end
        end)
      end
    end)
  end

  return module
end

return M

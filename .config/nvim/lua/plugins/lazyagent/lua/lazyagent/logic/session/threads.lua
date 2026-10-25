local M = {}
local identity = require("lazyagent.logic.session.identity")
local process = require("lazyagent.acp.process")
local cockpit = require("lazyagent.acp.cockpit")

function M.setup(deps)
  local state = deps.state
  local agent_logic = deps.agent_logic
  local backend_logic = deps.backend_logic
  local acp_logic = deps.acp_logic
  local start_interactive_session = deps.start_interactive_session
  local close_session = deps.close_session
  local force_close_session = deps.force_close_session or close_session
  local resolve_active_acp_session = deps.resolve_active_acp_session
  local editor_registry = deps.editor_registry or require("lazyagent.acp.editor_registry")
  local module = {}
  local reopening_threads = {}
  local thread_label

  local function normalize_path(path)
    path = tostring(path or "")
    if path == "" then return nil end
    return vim.fn.fnamemodify(path, ":p"):gsub("/$", "")
  end

  local function thread_workspace(thread)
    local metadata = type(thread and thread.metadata) == "table" and thread.metadata or {}
    local worktree = metadata.worktree_state == "active" and metadata.worktree_path or nil
    return normalize_path(worktree or (thread and thread.cwd))
  end

  local function path_in_workspace(path, workspace)
    path = normalize_path(path)
    workspace = normalize_path(workspace)
    return path ~= nil and workspace ~= nil and (path == workspace or path:sub(1, #workspace + 1) == workspace .. "/")
  end

  local function session_thread_id(session_key, session)
    local thread_id = identity.thread_id(session_key, session)
    if thread_id then return thread_id end
    local active_backend = session and state.backends and state.backends[session.backend] or nil
    if active_backend and type(active_backend.get_runtime_snapshot) == "function" and session.pane_id then
      local snapshot = active_backend.get_runtime_snapshot(session.pane_id)
      return snapshot and snapshot.acp_thread_id or nil
    end
    return nil
  end

  local function local_session_key(thread_id)
    for session_key, session in pairs(state.sessions or {}) do
      if session_thread_id(session_key, session) == thread_id and session.pane_id and session.pane_id ~= "" then
        return session_key, session
      end
    end
    return nil, nil
  end

  local function source_anchor(thread)
    local workspace = thread_workspace(thread)
    if not workspace then return nil, nil end
    local candidates = {}
    local seen = {}
    local function add(path)
      path = normalize_path(path)
      if path and not seen[path] and path_in_workspace(path, workspace) and vim.fn.isdirectory(path) == 0 then
        seen[path] = true
        candidates[#candidates + 1] = path
      end
    end

    local editor = type(thread.metadata) == "table" and thread.metadata.editor or nil
    add(editor and editor.source_path)
    for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do add(info.name) end
    local turns = thread.change_journal and thread.change_journal.turns or {}
    for turn_index = #turns, 1, -1 do
      local changes = turns[turn_index].changes or {}
      for change_index = #changes, 1, -1 do
        local relative = changes[change_index].path
        if relative and relative ~= "" then add(workspace .. "/" .. relative) end
      end
      if #candidates > 0 then break end
    end
    if #candidates == 0 and vim.fn.isdirectory(workspace) == 1 then
      local files = vim.fn.systemlist({ "git", "-C", workspace, "ls-files" })
      if vim.v.shell_error == 0 then add(files[1] and (workspace .. "/" .. files[1]) or nil) end
    end
    if #candidates == 0 then
      local name = "LazyAgent Workspace Anchor [" .. tostring(thread.thread_id) .. "]"
      local bufnr = vim.fn.bufnr(name)
      if bufnr < 0 then
        bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(bufnr, name)
        vim.bo[bufnr].buftype = "nofile"
        vim.bo[bufnr].bufhidden = "hide"
        vim.bo[bufnr].swapfile = false
      end
      vim.b[bufnr].lazyagent_workspace_root = workspace
      return bufnr, nil
    end

    local bufnr = vim.fn.bufnr(candidates[1])
    if bufnr < 0 then bufnr = vim.fn.bufadd(candidates[1]) end
    local winid = vim.fn.bufwinid(bufnr)
    if winid < 0 then winid = nil end
    return bufnr, winid
  end

  local function thread_has_changes(thread)
    local turns = thread and thread.change_journal and thread.change_journal.turns or {}
    for index = #turns, 1, -1 do
      if type(turns[index].changes) == "table" and #turns[index].changes > 0 then
        return true
      end
    end
    return false
  end

  local function configured_provider(provider_id)
    if provider_id and provider_id ~= "" then
      return provider_id
    end
    local providers = agent_logic.available_acp_agents()
    if #providers == 1 then
      return providers[1]
    end
    return nil, providers
  end

  local function backend_for_provider(provider_id)
    local cfg = provider_id and agent_logic.get_interactive_agent(provider_id) or nil
    local backend_name, backend = backend_logic.resolve_backend_for_agent(provider_id, cfg)
    if backend and acp_logic.is_acp_backend(backend_name) then
      return backend, cfg
    end
    return state.backends and (state.backends.buffer_acp or state.backends.tmux_acp) or nil, cfg
  end

  local function thread_backend(thread_id, provider_id)
    local session_key, session = local_session_key(thread_id)
    if session then
      local active_backend = state.backends and state.backends[session.backend] or nil
      if not active_backend then
        active_backend = backend_for_provider(identity.provider_id(session_key, session))
      end
      if active_backend and type(active_backend.get_thread) == "function" then
        local thread = active_backend.get_thread(thread_id, { include_live = true })
        if thread then
          return active_backend, thread
        end
      end
    end

    local backend = backend_for_provider(provider_id)
    if backend and thread_id and type(backend.get_thread) == "function" then
      local thread = backend.get_thread(thread_id)
      if thread then
        return backend, thread
      end
    end
    for _, candidate in ipairs({ state.backends and state.backends.buffer_acp, state.backends and state.backends.tmux_acp }) do
      if candidate and type(candidate.get_thread) == "function" then
        local thread = candidate.get_thread(thread_id)
        if thread then
          return candidate, thread
        end
      end
    end
    return backend, nil
  end

  local function active_mutation_error(thread, action)
    if thread and thread.process_id ~= nil then
      vim.notify(
        string.format("LazyAgent ACP: close thread %s before %s", thread.thread_id:sub(1, 8), action),
        vim.log.levels.WARN
      )
      return true
    end
    return false
  end

  local function owner_options()
    return { owner_pid = vim.fn.getpid(), owner_instance_id = state.editor_instance_id }
  end

  local function same_process_owner(before, after)
    if not before or not after or before.process_id ~= after.process_id then return false end
    local old = before.metadata or {}
    local new = after.metadata or {}
    return old.process_identity == new.process_identity and vim.deep_equal(old.editor, new.editor)
  end

  local function recover_stopped_thread(backend, thread)
    if thread.status ~= "active" or local_session_key(thread.thread_id)
      or cockpit.thread_status(thread, nil, owner_options()) ~= "closed"
    then
      return thread
    end
    return backend.update_thread(thread.thread_id, {
      status = "closed", process_id = vim.NIL,
    }, { expected_process_id = thread.process_id or vim.NIL, preserve_updated_at = true })
  end

  local function claim_restart_thread(backend, thread, expected_process_id)
    expected_process_id = tonumber(expected_process_id)
    if not expected_process_id or tonumber(thread.process_id) ~= expected_process_id then
      return nil, "owner_changed"
    end
    local recovered = backend.update_thread(thread.thread_id, {
      status = "closed",
      process_id = vim.NIL,
    }, { expected_process_id = expected_process_id })
    if recovered then return recovered end
    if type(backend.get_thread) == "function" then
      local latest = backend.get_thread(thread.thread_id, { include_live = true })
      if latest and (latest.status ~= "active" or latest.process_id == nil) then return latest end
    end
    return nil, "owner_changed"
  end

  function module.close_disconnected_thread(thread_id, on_closed, opts)
    opts = opts or {}
    local backend, thread = thread_backend(thread_id)
    if not backend or not thread then
      vim.notify("LazyAgent ACP: thread not found: " .. tostring(thread_id), vim.log.levels.WARN)
      return false
    end
    thread = vim.deepcopy(thread)
    if thread.status ~= "active" or local_session_key(thread_id) then
      vim.notify("LazyAgent ACP: selected thread is not disconnected", vim.log.levels.INFO)
      return false
    end
    local status = cockpit.thread_status(thread, nil, owner_options())
    local function finish()
      local updated, err = backend.update_thread(thread.thread_id, {
        status = "closed", process_id = vim.NIL,
      }, { expected_process_id = thread.process_id or vim.NIL })
      if not updated then
        vim.notify("LazyAgent ACP: failed to recover disconnected thread: " .. tostring(
          type(err) == "table" and err.code or err
        ), vim.log.levels.ERROR)
        return false
      end
      vim.notify("LazyAgent ACP: thread is now closed and can be resumed", vim.log.levels.INFO)
      if on_closed then on_closed() end
      return true
    end
    if status == "closed" then return finish() end
    local info = process.inspect(thread.process_id)
    if info.alive ~= true or tonumber(thread.process_id) == vim.fn.getpid() then
      vim.notify("LazyAgent ACP: cannot safely stop this process: " .. tostring(info.error or thread.process_id), vim.log.levels.WARN)
      return false
    end
    local function same_owner(latest)
      return same_process_owner(thread, latest) and not local_session_key(thread_id)
    end
    local function stop()
      local latest = backend.get_thread(thread_id)
      if not same_owner(latest) then
        vim.notify("LazyAgent ACP: thread ownership changed; refresh before retrying", vim.log.levels.WARN)
        return
      end
      local current = process.inspect(thread.process_id)
      if current.alive == false or (info.identity and current.identity and info.identity ~= current.identity) then
        finish()
        return
      end
      if current.alive ~= true then return end
      local ok, result, err = pcall((vim.uv or vim.loop).kill, tonumber(thread.process_id), opts.kill and "sigkill" or "sigterm")
      if not ok or result ~= 0 then
        vim.notify("LazyAgent ACP: failed to stop process: " .. tostring(err or result), vim.log.levels.WARN)
        return
      end
      local attempts = 0
      local function await_exit()
        local remaining = process.inspect(thread.process_id)
        if remaining.alive == false or (info.identity and remaining.identity and info.identity ~= remaining.identity) then
          finish()
        elseif attempts < 40 then
          attempts = attempts + 1
          -- Explicit stop must also work for agents that ignore SIGTERM. Check
          -- the captured owner again before escalating; never signal the editor.
          if attempts == 20 and not opts.kill then
            if not same_owner(backend.get_thread(thread_id)) then
              vim.notify("LazyAgent ACP: thread ownership changed; refresh before retrying", vim.log.levels.WARN)
              return
            end
            local killed, result, err = pcall((vim.uv or vim.loop).kill, tonumber(thread.process_id), "sigkill")
            if not killed or result ~= 0 then
              vim.notify("LazyAgent ACP: failed to kill process: " .. tostring(err or result), vim.log.levels.WARN)
              return
            end
          end
          vim.defer_fn(await_exit, 50)
        else
          vim.notify("LazyAgent ACP: process has not exited; history is kept and the thread remains active", vim.log.levels.WARN)
        end
      end
      await_exit()
    end
    if opts.confirmed then stop(); return true end
    local action = "Stop process and close thread"
    vim.ui.select({ "Cancel", action }, {
      prompt = "Stop ACP process " .. tostring(thread.process_id)
        .. (status == "external" and " in another Neovim" or "") .. "? History will be kept.",
    }, function(choice)
      if choice == action then stop() end
    end)
    return true
  end

  local function delete_thread_record(backend, thread)
    local deleted, err = backend.delete_thread(thread.thread_id, { expected_process_id = thread.process_id or vim.NIL })
    if deleted ~= true then
      vim.notify("LazyAgent ACP: delete failed: " .. tostring(err), vim.log.levels.ERROR)
      return false
    end
    if thread.transcript_path and thread.transcript_path ~= "" then
      pcall(vim.fn.delete, thread.transcript_path)
    end
    return true
  end

  function module.open_thread(thread_id, opts)
    opts = opts or {}
    local backend, thread = thread_backend(thread_id)
    if not backend or not thread then
      vim.notify("LazyAgent ACP: thread not found: " .. tostring(thread_id), vim.log.levels.WARN)
      return false
    end
    local cfg = agent_logic.get_interactive_agent(thread.provider_id)
    if not cfg then
      vim.notify("LazyAgent ACP: provider is not configured: " .. tostring(thread.provider_id), vim.log.levels.WARN)
      return false
    end
    local local_key, local_session = local_session_key(thread.thread_id)
    local local_backend = local_session and state.backends and state.backends[local_session.backend]
    local snapshot = local_backend and type(local_backend.get_runtime_snapshot) == "function"
      and local_backend.get_runtime_snapshot(local_session.pane_id) or nil
    if local_key and snapshot and snapshot.acp_failed == true
      and cockpit.thread_status(thread, snapshot, owner_options()) == "closed"
    then
      if reopening_threads[thread_id] then return true end
      reopening_threads[thread_id] = true
      close_session(local_key)
      local attempts = 0
      local function reopen()
        local key, current = local_session_key(thread_id)
        if not key then
          reopening_threads[thread_id] = nil
          module.open_thread(thread_id, opts)
        elseif current == local_session and attempts < 30 then
          attempts = attempts + 1
          vim.defer_fn(reopen, 100)
        else
          reopening_threads[thread_id] = nil
          vim.notify("LazyAgent ACP: session cleanup is not complete; refresh before resuming", vim.log.levels.WARN)
        end
      end
      reopen()
      return true
    end
    if thread.status == "active" and thread.process_id ~= nil and not local_key and opts.restart_process_id ~= nil then
      local claimed, claim_err = claim_restart_thread(backend, thread, opts.restart_process_id)
      if not claimed then return false, claim_err end
      thread = claimed
    end
    if not local_key and thread.status == "active" then
      local recovered, recover_err = recover_stopped_thread(backend, thread)
      if not recovered then return false, recover_err end
      thread = recovered
    end
    if thread.status == "active" and thread.process_id ~= nil and not local_key then
      vim.notify(
        "LazyAgent ACP: process is still running; use Cockpit x to stop a disconnected thread, or stop it in its owning Neovim",
        vim.log.levels.WARN
      )
      return false
    end
    if thread.metadata and thread.metadata.worktree_state == "active" then
      local _, restore_err = require("lazyagent.acp.worktree").restore(thread)
      if restore_err then
        vim.notify("LazyAgent ACP: " .. restore_err, vim.log.levels.ERROR)
        return false
      end
    end
    local workspace = thread_workspace(thread)
    local source_bufnr, context_winid = source_anchor(thread)
    local placement_winid = opts.placement_winid
    if placement_winid and not vim.api.nvim_win_is_valid(placement_winid) then
      placement_winid = nil
    end
    local launch_opts = {
      agent_name = local_key or thread.provider_id,
      acp_thread_title = thread.title,
      root_dir = workspace,
      cwd = workspace,
      source_bufnr = source_bufnr,
      source_winid = placement_winid or context_winid,
      origin_winid = placement_winid or vim.api.nvim_get_current_win(),
      reuse = true,
      stay_hidden = opts.stay_hidden == true,
      open_input = false,
      focus_agent_view = opts.focus_agent_view ~= false,
      relocate_agent_view = opts.relocate_agent_view == true,
      on_ready = opts.on_ready,
      initial_input = opts.initial_input,
      acp_reuse_view = opts.reuse_view,
    }
    if opts.open_input == true then launch_opts.open_input = true end
    if not local_key then
      launch_opts.acp_thread_id = thread.thread_id
    end
    if opts.activation_mode == "load" or opts.activation_mode == "resume" then
      if not thread.native_session_id or thread.native_session_id == "" then
        vim.notify("LazyAgent ACP: this thread has no native session to activate", vim.log.levels.WARN)
        return false
      end
      launch_opts.acp = {
        session_bootstrap = {
          session_mode = opts.activation_mode,
          session_id = thread.native_session_id,
        },
      }
    end
    start_interactive_session(launch_opts)
    return true
  end

  function module.branch_thread(thread_id, turn_id, opts)
    opts = opts or {}
    local backend, stored = thread_backend(thread_id)
    if not backend or not stored or type(backend.branch_thread_checkpoint) ~= "function" then
      vim.notify("LazyAgent ACP: local branch is unavailable", vim.log.levels.WARN)
      return nil
    end
    local thread = type(backend.get_thread) == "function"
        and backend.get_thread(thread_id, { include_live = true })
      or stored
    local turns = thread and thread.change_journal and thread.change_journal.turns or {}
    if not turn_id then
      for index = #turns, 1, -1 do
        if turns[index].state ~= "active" then turn_id = turns[index].turn_id; break end
      end
    end
    if not turn_id then
      vim.notify("LazyAgent ACP: no completed turn is available to branch", vim.log.levels.INFO)
      return nil
    end
    local branch, err = backend.branch_thread_checkpoint(thread_id, turn_id, { kind = opts.kind })
    if not branch then
      vim.notify("LazyAgent ACP: local branch failed: " .. tostring(err), vim.log.levels.ERROR)
      return nil
    end
    vim.notify("LazyAgent ACP: created local branch " .. branch.thread_id:sub(1, 8), vim.log.levels.INFO)
    if opts.open == true then module.open_thread(branch.thread_id, opts) end
    return branch
  end

  function module.new_thread(provider_id, opts)
    opts = opts or {}
    local provider, providers = configured_provider(provider_id)
    if not provider then
      if type(providers) ~= "table" or #providers == 0 then
        vim.notify("LazyAgent ACP: no ACP provider is configured", vim.log.levels.WARN)
        return false
      end
      vim.ui.select(providers, { prompt = "New thread provider:" }, function(choice)
        if choice then
          module.new_thread(choice, opts)
        end
      end)
      return true
    end
    local backend = backend_for_provider(provider)
    if not backend or type(backend.create_thread) ~= "function" then
      vim.notify("LazyAgent ACP: thread store is unavailable", vim.log.levels.ERROR)
      return false
    end
    local thread, err = backend.create_thread({
      provider_id = provider,
      cwd = normalize_path(opts.workspace) or vim.fn.getcwd(),
      title = provider,
      status = "closed",
    })
    if not thread then
      vim.notify("LazyAgent ACP: failed to create thread: " .. tostring(err), vim.log.levels.ERROR)
      return false
    end
    return module.open_thread(thread.thread_id)
  end

  function module.new_thread_in_workspace(provider_id, workspace)
    workspace = normalize_path(workspace)
    if not workspace or vim.fn.isdirectory(workspace) ~= 1 then
      vim.notify("LazyAgent ACP: workspace is unavailable: " .. tostring(workspace), vim.log.levels.WARN)
      return false
    end
    return module.new_thread(provider_id, { workspace = workspace })
  end

  function module.request_new_agent(workspace, provider_id)
    workspace = normalize_path(workspace)
    if not workspace then
      vim.notify("LazyAgent ACP: move to a project before creating an agent", vim.log.levels.INFO)
      return false
    end
    local provider, providers = configured_provider(provider_id)
    if not provider then
      if type(providers) ~= "table" or #providers == 0 then
        vim.notify("LazyAgent ACP: no ACP provider is configured", vim.log.levels.WARN)
        return false
      end
      vim.ui.select(providers, { prompt = "New agent provider:" }, function(choice)
        if choice then module.request_new_agent(workspace, choice) end
      end)
      return true
    end

    local targets = editor_registry.targets(workspace)
    if #targets == 0 then
      vim.notify(
        "LazyAgent ACP: no Neovim currently has this workspace open: " .. vim.fn.fnamemodify(workspace, ":~"),
        vim.log.levels.INFO
      )
      return false
    end
    local function request(target)
      local accepted, err = editor_registry.request_create_agent(target, provider, workspace)
      if not accepted then
        vim.notify("LazyAgent ACP: failed to create agent: " .. tostring(err), vim.log.levels.ERROR)
        return false
      end
      vim.notify(
        "LazyAgent ACP: creating " .. provider .. " in " .. tostring(target.label or "target Neovim"),
        vim.log.levels.INFO
      )
      return true
    end
    if #targets == 1 then return request(targets[1]) end
    vim.ui.select(targets, {
      prompt = "Create agent in Neovim:",
      format_item = function(target) return target.label end,
    }, function(target)
      if target then request(target) end
    end)
    return true
  end

  function module.new_worktree_thread(provider_id)
    local provider, providers = configured_provider(provider_id)
    if not provider then
      vim.ui.select(providers or {}, { prompt = "Worktree thread provider:" }, function(choice)
        if choice then module.new_worktree_thread(choice) end
      end)
      return true
    end
    local backend = backend_for_provider(provider)
    if not backend or type(backend.create_thread) ~= "function" then return false end
    local root = vim.fn.getcwd()
    vim.ui.input({ prompt = "Worktree branch: " }, function(branch)
      if not branch or branch == "" then return end
      local dirname = vim.fn.fnamemodify(root, ":t") .. "-" .. branch:gsub("[^%w._-]", "-")
      local default_path = vim.fn.fnamemodify(root, ":h") .. "/" .. dirname
      vim.ui.input({ prompt = "Worktree path: ", default = default_path }, function(path)
        if not path or path == "" then return end
        local metadata, create_err = require("lazyagent.acp.worktree").create({
          root = root, path = path, branch = branch,
        })
        if not metadata then
          vim.notify("LazyAgent ACP worktree: " .. tostring(create_err), vim.log.levels.ERROR)
          return
        end
        local thread, thread_err = backend.create_thread({
          provider_id = provider, cwd = metadata.worktree_path, title = branch, status = "closed", metadata = metadata,
        })
        if not thread then
          vim.notify("LazyAgent ACP thread: " .. tostring(thread_err), vim.log.levels.ERROR)
          return
        end
        module.open_thread(thread.thread_id)
      end)
    end)
    return true
  end

  function module.cleanup_worktree(thread_id)
    local backend, thread = thread_backend(thread_id)
    if not backend or not thread then return false end
    local metadata, cleanup_err = require("lazyagent.acp.worktree").cleanup(thread)
    if not metadata then
      vim.notify("LazyAgent ACP worktree: " .. tostring(cleanup_err), vim.log.levels.ERROR)
      return false
    end
    return backend.update_thread(thread_id, { cwd = metadata.original_root, metadata = metadata }) ~= nil
  end

  function module.archive_thread(thread_id)
    local backend, thread = thread_backend(thread_id)
    if not backend or not thread or active_mutation_error(thread, "archiving") then
      return false
    end
    local updated, err = backend.archive_thread(thread.thread_id)
    if not updated then
      vim.notify("LazyAgent ACP: archive failed: " .. tostring(err), vim.log.levels.ERROR)
      return false
    end
    return true
  end

  function module.restore_thread(thread_id)
    local backend, thread = thread_backend(thread_id)
    if not backend or not thread then
      return false
    end
    return backend.restore_thread(thread.thread_id) ~= nil
  end

  function module.rename_thread(thread_id, title)
    local backend, thread = thread_backend(thread_id)
    if not backend or not thread then
      return false
    end
    local updated, err = backend.rename_thread(thread.thread_id, title)
    if not updated then
      vim.notify("LazyAgent ACP: rename failed: " .. tostring(err), vim.log.levels.ERROR)
      return false
    end
    local session_key = local_session_key(thread.thread_id)
    if session_key then
      pcall(function() require("lazyagent.logic.status").refresh_session_title(session_key) end)
    end
    return true
  end

  function module.prompt_rename_thread(thread_id, on_done)
    local _, thread = thread_backend(thread_id)
    if not thread then return false end
    vim.ui.input({ prompt = "Thread title: ", default = thread.title }, function(title)
      if title == nil then return end
      title = vim.trim(title)
      if title == "" then
        vim.notify("LazyAgent ACP: thread title is required", vim.log.levels.WARN)
        return
      end
      local renamed = module.rename_thread(thread.thread_id, title)
      if renamed then
        vim.notify("LazyAgent ACP thread renamed: " .. title, vim.log.levels.INFO)
        if on_done then on_done() end
      end
    end)
    return true
  end

  function module.rename_active_thread(title, agent_name)
    if type(resolve_active_acp_session) ~= "function" then return false end
    resolve_active_acp_session(agent_name, function(session_key)
      local session = state.sessions and state.sessions[session_key] or nil
      local thread_id = session_thread_id(session_key, session)
      if not thread_id then
        vim.notify("LazyAgent ACP: active thread is unavailable", vim.log.levels.WARN)
        return
      end
      if title == nil then
        module.prompt_rename_thread(thread_id)
        return
      end
      local normalized = vim.trim(tostring(title))
      if normalized == "" then
        vim.notify("LazyAgent ACP: thread title is required", vim.log.levels.WARN)
        return
      end
      if module.rename_thread(thread_id, normalized) then
        vim.notify("LazyAgent ACP thread renamed: " .. normalized, vim.log.levels.INFO)
      end
    end)
    return true
  end

  function module.delete_thread(thread_id)
    local backend, thread = thread_backend(thread_id)
    if not backend or not thread or active_mutation_error(thread, "deleting") then
      return false
    end
    return delete_thread_record(backend, thread)
  end

  function module.force_delete_thread(thread_id, on_deleted)
    local local_key = local_session_key(thread_id)
    if local_key then force_close_session(local_key) end
    local backend, thread = thread_backend(thread_id)
    if not backend or not thread then
      return false
    end
    local function remove()
      local latest = backend.get_thread(thread_id)
      if not latest then return false end
      if active_mutation_error(latest, "deleting") then return false end
      local deleted = delete_thread_record(backend, latest)
      if deleted and on_deleted then on_deleted() end
      return deleted
    end
    if thread.status == "active" and thread.process_id ~= nil then
      return module.close_disconnected_thread(thread_id, remove, { confirmed = true, kill = true })
    end
    return remove()
  end

  function module.show_thread_changes(thread_id)
    if thread_id and thread_id ~= "" then
      local backend, thread = thread_backend(thread_id)
      if not backend or not thread or type(backend.show_thread_changes) ~= "function" then
        vim.notify("LazyAgent ACP: thread changes are unavailable", vim.log.levels.WARN)
        return false
      end
      local opened, err = backend.show_thread_changes(thread.thread_id)
      if not opened then
        vim.notify("LazyAgent ACP: " .. tostring(err), vim.log.levels.INFO)
        return false
      end
      return true
    end

    local threads = {}
    local seen = {}
    for session_key, session in pairs(state.sessions or {}) do
      local id = session_thread_id(session_key, session)
      if id and not seen[id] and session.pane_id and session.pane_id ~= "" then
        seen[id] = true
        local _, thread = thread_backend(id, identity.provider_id(session_key, session))
        if thread and thread.status == "active" and thread_has_changes(thread) then
          threads[#threads + 1] = thread
        end
      end
    end
    table.sort(threads, function(left, right)
      local left_updated = tostring(left.updated_at or "")
      local right_updated = tostring(right.updated_at or "")
      if left_updated == right_updated then
        return tostring(left.thread_id) < tostring(right.thread_id)
      end
      return left_updated > right_updated
    end)
    if #threads == 0 then
      vim.notify("LazyAgent ACP: no live file changes belong to this Neovim", vim.log.levels.INFO)
      return false
    end
    if #threads == 1 then
      return module.show_thread_changes(threads[1].thread_id)
    end
    vim.ui.select(threads, { prompt = "LazyAgent ACP changed threads:", format_item = thread_label }, function(thread)
      if thread then
        module.show_thread_changes(thread.thread_id)
      end
    end)
    return true
  end

  function module.open_thread_transcript(thread_id)
    local _, thread = thread_backend(thread_id)
    local path = thread and thread.transcript_path or nil
    if not path or path == "" or vim.fn.filereadable(path) ~= 1 then
      vim.notify("LazyAgent ACP: raw transcript is unavailable", vim.log.levels.WARN)
      return false
    end
    vim.cmd("tabnew")
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local bufnr = vim.api.nvim_get_current_buf()
    local winid = vim.api.nvim_get_current_win()
    vim.bo[bufnr].filetype = "markdown"
    vim.bo[bufnr].readonly = true
    vim.wo[winid].wrap = false
    return true
  end

  thread_label = function(thread)
    local marker = thread.status == "archived" and "archive" or thread.status
    local unread = thread.unread == true and " • unread" or ""
    return string.format("%s · %s [%s%s]", thread.title, thread.provider_id, marker, unread)
  end

  function module.pick_threads(provider_id)
    local backend = backend_for_provider(provider_id)
    if not backend or type(backend.list_threads) ~= "function" then
      return false
    end
    local threads, err = backend.list_threads({ include_archived = true })
    if not threads then
      vim.notify("LazyAgent ACP: thread list failed: " .. tostring(err), vim.log.levels.ERROR)
      return false
    end
    if provider_id and provider_id ~= "" then
      threads = vim.tbl_filter(function(thread)
        return thread.provider_id == provider_id
      end, threads)
    end
    vim.ui.select(threads, {
      prompt = "LazyAgent ACP threads:",
      format_item = thread_label,
    }, function(thread)
      if not thread then
        return
      end
      local actions = { "Open", "Rename" }
      local latest_turn = require("lazyagent.acp.change_review").latest_turn(thread)
      if latest_turn then
        actions[#actions + 1] = "Review changes"
        actions[#actions + 1] = "Branch latest turn"
      end
      actions[#actions + 1] = thread.status == "archived" and "Restore" or "Archive"
      actions[#actions + 1] = "Delete"
      vim.ui.select(actions, { prompt = thread_label(thread) .. ":" }, function(action)
        if action == "Open" then
          module.open_thread(thread.thread_id)
        elseif action == "Rename" then
          module.prompt_rename_thread(thread.thread_id)
        elseif action == "Review changes" then
          module.show_thread_changes(thread.thread_id)
        elseif action == "Branch latest turn" then
          module.branch_thread(thread.thread_id, latest_turn.turn_id)
        elseif action == "Archive" then
          module.archive_thread(thread.thread_id)
        elseif action == "Restore" then
          module.restore_thread(thread.thread_id)
        elseif action == "Delete" then
          vim.ui.select({ "Cancel", "Delete" }, { prompt = "Delete thread permanently?" }, function(confirm)
            if confirm == "Delete" then
              module.delete_thread(thread.thread_id)
            end
          end)
        end
      end)
    end)
    return true
  end

  function module.pick_named_threads()
    local backend = backend_for_provider()
    if not backend or type(backend.list_threads) ~= "function" then
      vim.notify("LazyAgent ACP: named threads are unavailable", vim.log.levels.WARN)
      return false
    end
    local threads, err = backend.list_threads({ include_archived = true })
    if not threads then
      vim.notify("LazyAgent ACP: named thread list failed: " .. tostring(err), vim.log.levels.ERROR)
      return false
    end
    threads = vim.tbl_filter(function(thread)
      local metadata = type(thread.metadata) == "table" and thread.metadata or {}
      return metadata.title_source == "manual" and vim.trim(tostring(thread.title or "")) ~= ""
    end, threads)
    table.sort(threads, function(left, right)
      local left_updated = tostring(left.updated_at or "")
      local right_updated = tostring(right.updated_at or "")
      if left_updated == right_updated then
        return tostring(left.title or ""):lower() < tostring(right.title or ""):lower()
      end
      return left_updated > right_updated
    end)
    if #threads == 0 then
      vim.notify("LazyAgent ACP: no manually named threads", vim.log.levels.INFO)
      return false
    end

    vim.ui.select(threads, {
      prompt = "Resume named LazyAgent ACP thread:",
      kind = "lazyagent-acp-names",
      previewer = "builtin",
      fzf_opts = {
        ["--delimiter"] = "\t",
        ["--with-nth"] = "2..",
      },
      format_item = function(thread)
        local path = tostring(thread.transcript_path or "")
        if path == "" then path = "[no-transcript]" end
        local workspace = vim.fn.fnamemodify(tostring(thread.cwd or ""), ":~")
        local details = {
          tostring(thread.title),
          tostring(thread.provider_id or "Agent"),
          tostring(thread.status or "closed"),
        }
        if workspace ~= "" then details[#details + 1] = workspace end
        return path .. "\t" .. table.concat(details, "  ·  ")
      end,
    }, function(thread)
      if thread then module.open_thread(thread.thread_id) end
    end)
    return true
  end

  function module.open_cockpit()
    local backend = backend_for_provider(nil)
    if not backend or type(backend.list_threads) ~= "function" then
      vim.notify("LazyAgent ACP: thread store is unavailable", vim.log.levels.ERROR)
      return false
    end
    local origin_bufnr = vim.api.nvim_get_current_buf()
    local current_open_thread_id = identity.thread_id(
      state.open_agent,
      state.open_agent and state.sessions and state.sessions[state.open_agent] or nil
    )
    local current_root = vim.b[origin_bufnr].lazyagent_workspace_root
    if type(current_root) ~= "string" or current_root == "" then
      current_root = require("lazyagent.util").git_root_for_path(vim.api.nvim_buf_get_name(origin_bufnr))
        or vim.fn.getcwd()
    end
    current_root = normalize_path(current_root)
    vim.cmd("tabnew")
    local bufnr = vim.api.nvim_get_current_buf()
    vim.bo[bufnr].buflisted = false
    vim.api.nvim_buf_set_name(bufnr, "LazyAgent ACP Cockpit [" .. tostring(bufnr) .. "]")
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = "lazyagent_acp_cockpit"

    local cockpit_winid = vim.api.nvim_get_current_win()
    local line_map = {}
    local controls = {}
    local group_rows = {}
    local expanded_groups = {}
    local collapsed_groups = {}
    local attention_only = false
    local snoozed = {}
    local fingerprints, fingerprint_pending, fingerprint_checks = {}, {}, {}
    local review_jobs = {}
    local pending_refresh = false
    local stored_threads = {}
    local query = ""
    local body_search
    local body_query = ""
    local view_name
    local view_store = require("lazyagent.acp.cockpit_views").new({ dir =
      (((state.opts or {}).cache or {}).dir or (vim.fn.stdpath("cache") .. "/lazyagent")) .. "/acp/cockpit-views" })
    local warned_conflicts = ""
    local thread_agents = {}
    local runtimes = {}
    local preview_bufnr
    local preview_renderer
    local preview_winid
    local preview_enabled = true
    local preview_mode = "summary"
    local detail_section = "overview"
    local preview_layout = require("lazyagent.acp.cockpit").normalize_preview_layout(
      ((state.opts or {}).acp or {}).cockpit_preview_layout or (state.opts or {}).cockpit_preview_layout
    )
    local preview_thread_id
    local preview_signature
    local preview_timer
    local preview_delay_timer = (vim.uv or vim.loop).new_timer()
    local preview_generation = 0
    local preview_pending = false
    local refreshing = false
    local creating_preview = false
    local original_acp_winhighlights = {}
    local refresh
    local maybe_mark_preview_read
    local preview_augroup = vim.api.nvim_create_augroup(
      "LazyAgentACPCockpitPreview" .. tostring(bufnr),
      { clear = true }
    )
    local preview_scroll_autocmd

    local function stored_thread(thread_id)
      for _, thread in ipairs(stored_threads or {}) do
        if thread.thread_id == thread_id then return thread end
      end
      return nil
    end

    local function create_preview()
      if preview_winid and vim.api.nvim_win_is_valid(preview_winid) then return true end
      if creating_preview then return false end
      if not vim.api.nvim_win_is_valid(cockpit_winid) then return false end
      creating_preview = true
      if not preview_bufnr or not vim.api.nvim_buf_is_valid(preview_bufnr) then
        preview_bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(preview_bufnr, "LazyAgent ACP Cockpit Preview [" .. tostring(preview_bufnr) .. "]")
        vim.bo[preview_bufnr].buftype = "nofile"
        vim.bo[preview_bufnr].bufhidden = "wipe"
        vim.bo[preview_bufnr].swapfile = false
        vim.bo[preview_bufnr].filetype = "lazyagent_acp"
        preview_renderer = require("lazyagent.acp.transcript_preview").attach(preview_bufnr)
        for _, key in ipairs({ "K", "<Tab>", "C", "gC", "g/", "Q", "A", "t", "m", "Z", "V", "u", "w", "S", "F", "gF" }) do
          vim.keymap.set("n", key, function()
            if not vim.api.nvim_buf_is_valid(bufnr) then return end
            local mapping = vim.api.nvim_buf_call(bufnr, function() return vim.fn.maparg(key, "n", false, true) end)
            if type(mapping.callback) == "function" then mapping.callback() end
          end, { buffer = preview_bufnr, silent = true })
        end
      end
      vim.api.nvim_set_current_win(cockpit_winid)
      local selected = stored_thread(line_map[vim.api.nvim_win_get_cursor(cockpit_winid)[1]])
      local agent_cfg = selected and agent_logic.get_interactive_agent(selected.provider_id) or nil
      if preview_layout == "horizontal" then
        local preview_height = preview_mode == "mirror"
            and math.max(12, math.floor(vim.o.lines * 0.35))
          or 10
        vim.cmd("belowright " .. tostring(preview_height) .. "split")
      else
        local cockpit_width = vim.api.nvim_win_get_width(cockpit_winid)
        local preview_width = require("lazyagent.acp.cockpit").preview_width(
          agent_cfg and agent_cfg.pane_size,
          cockpit_width
        )
        vim.cmd("rightbelow " .. tostring(preview_width) .. "vsplit")
      end
      preview_winid = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(preview_winid, preview_bufnr)
      vim.wo[preview_winid].winfixheight = preview_layout == "horizontal"
      vim.wo[preview_winid].winfixwidth = preview_layout == "split"
      vim.wo[preview_winid].wrap = true
      vim.wo[preview_winid].linebreak = true
      vim.wo[preview_winid].breakindent = true
      vim.wo[preview_winid].conceallevel = 2
      vim.wo[preview_winid].concealcursor = "nvic"
      vim.wo[preview_winid].signcolumn = "no"
      vim.wo[preview_winid].statuscolumn = ""
      vim.wo[preview_winid].foldcolumn = "0"
      vim.wo[preview_winid].foldenable = false
      vim.wo[preview_winid].number = false
      vim.wo[preview_winid].relativenumber = false
      vim.wo[preview_winid].winhighlight = "Normal:NormalFloat,NormalNC:NormalFloat,EndOfBuffer:NormalFloat"
      local fillchars = vim.api.nvim_get_option_value("fillchars", { win = preview_winid })
      local visible_fillchars = vim.tbl_filter(function(part)
        return not vim.startswith(part, "eob:")
      end, vim.split(fillchars or "", ",", { trimempty = true }))
      visible_fillchars[#visible_fillchars + 1] = "eob: "
      vim.api.nvim_set_option_value("fillchars", table.concat(visible_fillchars, ","), { win = preview_winid })
      vim.wo[preview_winid].statusline = "%#DiagnosticInfo# LazyAgent Cockpit PREVIEW %*"
      if preview_scroll_autocmd then
        pcall(vim.api.nvim_del_autocmd, preview_scroll_autocmd)
      end
      preview_scroll_autocmd = vim.api.nvim_create_autocmd({ "CursorMoved", "WinScrolled" }, {
        group = preview_augroup,
        callback = function(args)
          local event_win = args.event == "WinScrolled" and tonumber(args.match) or vim.api.nvim_get_current_win()
          if event_win == preview_winid and maybe_mark_preview_read then
            vim.schedule(maybe_mark_preview_read)
          end
        end,
      })
      vim.api.nvim_set_current_win(cockpit_winid)
      creating_preview = false
      return true
    end

    local function selected_thread_id()
      if not vim.api.nvim_win_is_valid(cockpit_winid) then return nil end
      return line_map[vim.api.nvim_win_get_cursor(cockpit_winid)[1]]
    end

    local function winhighlight_parts(value)
      local parts = {}
      local indexes = {}
      for _, part in ipairs(vim.split(value or "", ",", { trimempty = true })) do
        local key, target = part:match("^([^:]+):(.+)$")
        if key and target then
          indexes[key] = #parts + 1
          parts[#parts + 1] = { key = key, target = target }
        end
      end
      return parts, indexes
    end

    local function winhighlight_target(value, key)
      local parts, indexes = winhighlight_parts(value)
      local index = indexes[key]
      return index and parts[index].target or nil
    end

    local function set_winhighlight_target(winid, key, target)
      local current = vim.wo[winid].winhighlight
      local parts, indexes = winhighlight_parts(current)
      local index = indexes[key]
      if target then
        if index then
          parts[index].target = target
        else
          parts[#parts + 1] = { key = key, target = target }
        end
      elseif index then
        table.remove(parts, index)
      end
      local rendered = vim.tbl_map(function(part)
        return part.key .. ":" .. part.target
      end, parts)
      vim.wo[winid].winhighlight = table.concat(rendered, ",")
    end

    local function update_acp_backgrounds()
      local selected_id = selected_thread_id()
      local selected_agent = thread_agents[selected_id]
      if not selected_agent and selected_id then
        selected_agent = local_session_key(selected_id)
      end
      for _, winid in ipairs(vim.api.nvim_list_wins()) do
        local acp_bufnr = vim.api.nvim_win_get_buf(winid)
        local ok, agent_name = pcall(vim.api.nvim_buf_get_var, acp_bufnr, "lazyagent_acp_agent")
        if ok and type(agent_name) == "string" and agent_name ~= "" then
          local original = original_acp_winhighlights[winid]
          if not original or original.bufnr ~= acp_bufnr then
            original = {
              bufnr = acp_bufnr,
              normal_nc = winhighlight_target(vim.wo[winid].winhighlight, "NormalNC"),
            }
            original_acp_winhighlights[winid] = original
          end
          local active_target = winhighlight_target(vim.wo[winid].winhighlight, "Normal") or "Normal"
          set_winhighlight_target(winid, "NormalNC", agent_name == selected_agent and active_target or "NormalNC")
        end
      end
    end

    local function restore_acp_backgrounds()
      for winid, original in pairs(original_acp_winhighlights) do
        if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == original.bufnr then
          pcall(set_winhighlight_target, winid, "NormalNC", original.normal_nc)
        end
      end
      original_acp_winhighlights = {}
    end

    local function selected_workspace()
      local selected = stored_thread(selected_thread_id())
      if selected then return thread_workspace(selected) end
      if vim.api.nvim_win_is_valid(cockpit_winid) then
        local row = vim.api.nvim_win_get_cursor(cockpit_winid)[1]
        for index = row, 1, -1 do
          if group_rows[index] then return group_rows[index] end
        end
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, row, false)
        for index = #lines, 1, -1 do
          local label = lines[index]:match("^## (.+)$")
          if label then
            for _, thread in ipairs(stored_threads or {}) do
              local workspace = thread_workspace(thread)
              if workspace and vim.fn.fnamemodify(workspace, ":~") == label then return workspace end
            end
            break
          end
        end
      end
      return current_root
    end

    local function mirror_snapshot(thread, known_signature)
      local agent_name = thread_agents[thread.thread_id]
      local session = agent_name and state.sessions and state.sessions[agent_name] or nil
      local active_backend = session and state.backends and state.backends[session.backend]
        or (session and backend_for_provider(agent_name) or nil)
      if session and active_backend and type(active_backend.get_view_snapshot) == "function" then
        local snapshot = active_backend.get_view_snapshot(session.pane_id)
        if snapshot then
          return snapshot.lines or {}, table.concat({
            "live", tostring(thread.thread_id), tostring(snapshot.changedtick or 0), tostring(snapshot.line_count or 0),
          }, ":")
        end
      end

      local path = thread.transcript_path
      if path and path ~= "" and vim.fn.filereadable(path) == 1 then
        local signature = table.concat({
          "file", tostring(thread.thread_id), tostring(vim.fn.getftime(path)), tostring(vim.fn.getfsize(path)),
        }, ":")
        if signature == known_signature then return nil, signature end
        local ok, lines = pcall(vim.fn.readfile, path)
        if ok and lines then
          return lines, signature
        end
      end
      return { "_No persisted transcript is available for this thread._" }, "empty:" .. tostring(thread.thread_id)
    end

    maybe_mark_preview_read = function()
      if preview_mode ~= "mirror"
        or not preview_thread_id
        or not preview_winid
        or not vim.api.nvim_win_is_valid(preview_winid)
        or not preview_bufnr
        or not vim.api.nvim_buf_is_valid(preview_bufnr)
      then
        return false
      end
      local thread = stored_thread(preview_thread_id)
      if not thread or thread.unread ~= true then return false end
      local line_count = math.max(1, vim.api.nvim_buf_line_count(preview_bufnr))
      local info = vim.fn.getwininfo(preview_winid)[1]
      local cursor = vim.api.nvim_win_get_cursor(preview_winid)[1]
      if cursor < line_count and (not info or tonumber(info.botline) < line_count) then
        return false
      end

      local agent_name = thread_agents[thread.thread_id]
      local session = agent_name and state.sessions and state.sessions[agent_name] or nil
      local active_backend = session and state.backends and state.backends[session.backend]
        or (session and backend_for_provider(agent_name) or nil)
        or backend
      if type(active_backend.mark_thread_read) ~= "function"
        or not active_backend.mark_thread_read(thread.thread_id)
      then
        return false
      end
      thread.unread = false
      vim.schedule(function()
        if refresh and vim.api.nvim_buf_is_valid(bufnr) then refresh() end
      end)
      return true
    end

    local function update_preview(thread_id, force)
      if not preview_enabled or not create_preview() then return end
      local thread = stored_thread(thread_id or selected_thread_id())
      local lines = { "# Thread Preview", "", "_Move to a thread to preview its latest response._" }
      if thread then
        local title = require("lazyagent.acp.cockpit").prompt_title(thread) or thread.thread_id:sub(1, 8)
        title = vim.fn.strcharpart(title:gsub("%s+", " "), 0, 72)
        if preview_mode == "mirror" then
          local signature
          local known_signature = not force and preview_thread_id == thread.thread_id and preview_signature or nil
          lines, signature = mirror_snapshot(thread, known_signature)
          if not lines or known_signature == signature then return end
          preview_thread_id = thread.thread_id
          preview_signature = signature
          if #lines == 0 then lines = { "_The transcript is currently empty._" } end
          if preview_winid and vim.api.nvim_win_is_valid(preview_winid) then
            vim.wo[preview_winid].winbar = "%#DiagnosticInfo# PREVIEW %*· Mirror · "
              .. tostring(thread.provider_id or "Agent"):gsub("%%", "%%%%") .. " · " .. title:gsub("%%", "%%%%") .. " "
          end
        elseif preview_mode == "details" then
          preview_thread_id, preview_signature = thread.thread_id, nil
          local _, current_thread = thread_backend(thread.thread_id)
          thread = current_thread or thread
          lines = require("lazyagent.acp.cockpit_details").render(thread, runtimes[thread.thread_id], detail_section, {
            owner_pid = vim.fn.getpid(), owner_instance_id = state.editor_instance_id,
            snoozed = snoozed, fingerprints = fingerprints, fingerprint_pending = fingerprint_pending,
          })
          vim.wo[preview_winid].winbar = "%#DiagnosticInfo# PREVIEW %*· " .. detail_section .. " "
        else
          lines = { "# " .. tostring(thread.provider_id or "Agent") .. " · " .. title, "" }
          local height = preview_winid and vim.api.nvim_win_is_valid(preview_winid)
              and vim.api.nvim_win_get_height(preview_winid)
            or 10
          local response = require("lazyagent.acp.cockpit").latest_response(thread, math.max(1, height - 3))
          if #response == 0 then response = { "_No assistant response yet._" } end
          vim.list_extend(lines, response)
          if preview_winid and vim.api.nvim_win_is_valid(preview_winid) then
            vim.wo[preview_winid].winbar = "%#DiagnosticInfo# PREVIEW %*· Latest response "
          end
        end
      end
      preview_thread_id = thread and thread.thread_id or nil
      local previous_count = vim.api.nvim_buf_line_count(preview_bufnr)
      local follow = preview_winid and vim.api.nvim_win_is_valid(preview_winid)
        and vim.api.nvim_win_get_cursor(preview_winid)[1] >= previous_count
      vim.bo[preview_bufnr].modifiable = true
      preview_renderer.set(lines, { transcript = thread ~= nil and preview_mode == "mirror", provider = thread and thread.provider_id })
      vim.bo[preview_bufnr].modifiable = false
      vim.bo[preview_bufnr].modified = false
      if follow and preview_winid and vim.api.nvim_win_is_valid(preview_winid) then
        pcall(vim.api.nvim_win_set_cursor, preview_winid, { math.max(1, #lines), 0 })
      end
      if preview_mode == "mirror" then
        vim.schedule(maybe_mark_preview_read)
      end
    end

    local function cancel_preview_delay()
      preview_generation = preview_generation + 1
      preview_pending = false
      if preview_delay_timer then preview_delay_timer:stop() end
    end

    local function schedule_preview()
      cancel_preview_delay()
      if not preview_enabled or not preview_delay_timer then return end
      local generation = preview_generation
      local thread_id = selected_thread_id()
      preview_pending = true
      preview_delay_timer:start(500, 0, vim.schedule_wrap(function()
        if generation ~= preview_generation then return end
        preview_pending = false
        if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_win_is_valid(cockpit_winid)
          or vim.api.nvim_win_get_tabpage(cockpit_winid) ~= vim.api.nvim_get_current_tabpage()
          or selected_thread_id() ~= thread_id
        then return end
        update_preview(thread_id)
      end))
    end

    local function cockpit_width()
      local windows = vim.fn.win_findbuf(bufnr)
      local winid = windows[1]
      return math.max(40, (winid and vim.api.nvim_win_get_width(winid) or vim.o.columns) - 1)
    end

    local function invalidate_fingerprint(root)
      local check = fingerprint_checks[root]
      if check then
        check.checked_at = 0
        if check.pending then check.invalidated = true end
      end
    end
    local function check_fingerprints()
      for _, thread in ipairs(stored_threads) do
        local result = thread.metadata and thread.metadata.test_result
        local review = thread.metadata and thread.metadata.cockpit_review
        local root = thread.cwd
        local needs_test = result and type(result.fingerprint) == "string" and result.status ~= "running"
        local needs_review = require("lazyagent.acp.cockpit_review").enabled(thread)
          and review.state == "done" and type(review.fingerprint) == "string"
        if root and (needs_test or needs_review) then
          local check = fingerprint_checks[root]
          if not check or (not check.pending and os.time() - check.checked_at >= 5) then
            check = { pending = true, checked_at = os.time() }
            fingerprint_checks[root], fingerprint_pending[root] = check, true
            check.job = require("lazyagent.acp.workspace_fingerprint").capture(root, function(fingerprint)
              check.pending, check.job = false, nil
              check.checked_at = check.invalidated and 0 or os.time()
              fingerprints[root], fingerprint_pending[root] = not check.invalidated and fingerprint or nil, nil
              if vim.api.nvim_buf_is_valid(bufnr) then pending_refresh = true end
            end)
          end
        end
      end
    end
    refresh = function()
      if refreshing or creating_preview then return end
      refreshing = true
      local selected_id = selected_thread_id()
      local list_err
      stored_threads, list_err = backend.list_threads({ include_archived = true })
      if not stored_threads then
        refreshing = false
        vim.notify("LazyAgent ACP cockpit: " .. tostring(list_err), vim.log.levels.ERROR)
        return
      end
      stored_threads = require("lazyagent.acp.cockpit").prune_empty(backend, stored_threads)
      local lines
      runtimes = {}
      thread_agents = {}
      for agent_name, active in pairs(state.sessions or {}) do
        if active.pane_id and active.pane_id ~= "" then
          local active_backend = backend_for_provider(agent_name)
          if active_backend and type(active_backend.get_runtime_snapshot) == "function" then
            local snapshot = active_backend.get_runtime_snapshot(active.pane_id)
            if snapshot and snapshot.acp_thread_id then
              snapshot.agent_status = active.agent_status
              snapshot.pane_id = active.pane_id
              snapshot.lazyagent_team = vim.deepcopy(active.lazyagent_team or nil)
              runtimes[snapshot.acp_thread_id] = snapshot
              thread_agents[snapshot.acp_thread_id] = agent_name
            end
          end
        end
      end
      for index, thread in ipairs(stored_threads) do
        if not runtimes[thread.thread_id] then
          stored_threads[index] = recover_stopped_thread(backend, thread) or thread
        end
      end
      check_fingerprints()
      local highlights
      local live_open_thread_id = identity.thread_id(
        state.open_agent,
        state.open_agent and state.sessions and state.sessions[state.open_agent] or nil
      )
      if live_open_thread_id then
        current_open_thread_id = live_open_thread_id
      elseif current_open_thread_id and not runtimes[current_open_thread_id] then
        current_open_thread_id = nil
      end
      local render_opts = {
        query = query, view_name = view_name,
        width = cockpit_width(),
        open_thread_id = current_open_thread_id,
        owner_pid = vim.fn.getpid(),
        owner_instance_id = state.editor_instance_id,
        current_root = current_root,
        expanded_groups = expanded_groups,
        history_limit = (((state.opts or {}).acp or {}).cockpit_history_limit),
        process_cache = {},
        attention_only = attention_only, snoozed = snoozed, collapsed_groups = collapsed_groups,
        fingerprints = fingerprints, fingerprint_pending = fingerprint_pending,
      }
      lines, line_map, highlights, controls, group_rows = require("lazyagent.acp.cockpit").render(
        require("lazyagent.acp.cockpit").filter(stored_threads, query, runtimes, render_opts),
        runtimes,
        render_opts
      )
      local conflicts = require("lazyagent.acp.cockpit").conflicts(stored_threads)
      local conflict_hash = vim.fn.sha256(vim.inspect(conflicts))
      if next(conflicts) and conflict_hash ~= warned_conflicts then
        warned_conflicts = conflict_hash
        vim.notify("LazyAgent ACP: active threads share changed files in the same workspace", vim.log.levels.WARN)
      elseif not next(conflicts) then
        warned_conflicts = ""
      end
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.bo[bufnr].modifiable = false
      vim.bo[bufnr].modified = false
      require("lazyagent.acp.cockpit").apply_highlights(bufnr, highlights)
      local restored_selection = false
      if selected_id and vim.api.nvim_win_is_valid(cockpit_winid) then
        for line, id in pairs(line_map) do
          if id == selected_id then
            vim.api.nvim_win_set_cursor(cockpit_winid, { line, 0 })
            restored_selection = true
            break
          end
        end
      end
      if preview_pending then
        schedule_preview()
      else
        update_preview(restored_selection and selected_id or selected_thread_id())
      end
      update_acp_backgrounds()
      refreshing = false
    end

    local function jump_live(delta, attention)
      local rows = {}
      for line, id in pairs(line_map) do
        local thread = stored_thread(id)
        if (not attention and thread_agents[id]) or (attention and thread and cockpit.needs_attention(thread, runtimes[id], {
          owner_pid = vim.fn.getpid(), owner_instance_id = state.editor_instance_id,
          snoozed = snoozed, fingerprints = fingerprints, fingerprint_pending = fingerprint_pending,
        })) then rows[#rows + 1] = line end
      end
      table.sort(rows)
      if #rows == 0 then
        vim.notify(attention and "LazyAgent ACP: no threads need attention" or "LazyAgent ACP: no live threads", vim.log.levels.INFO)
        return
      end
      local current = vim.api.nvim_win_get_cursor(cockpit_winid)[1]
      local target
      if delta > 0 then
        for _, line in ipairs(rows) do if line > current then target = line; break end end
        target = target or rows[1]
      else
        for index = #rows, 1, -1 do if rows[index] < current then target = rows[index]; break end end
        target = target or rows[#rows]
      end
      vim.api.nvim_win_set_cursor(cockpit_winid, { target, 0 })
      schedule_preview()
      update_acp_backgrounds()
    end

    vim.keymap.set("n", "f", function()
      attention_only = not attention_only
      view_name = nil
      cancel_preview_delay()
      refresh()
      local rows = vim.tbl_keys(line_map)
      table.sort(rows)
      if rows[1] then vim.api.nvim_win_set_cursor(cockpit_winid, { rows[1], 0 }); schedule_preview() end
    end, { buffer = bufnr, silent = true, desc = "Toggle attention-only Cockpit" })
    vim.keymap.set("n", "]e", function() jump_live(1, true) end, { buffer = bufnr, desc = "Next thread needing attention" })
    vim.keymap.set("n", "[e", function() jump_live(-1, true) end, { buffer = bufnr, desc = "Previous thread needing attention" })
    vim.keymap.set("n", "za", function()
      local path = selected_workspace()
      if not path then return end
      collapsed_groups[path] = not collapsed_groups[path]
      cancel_preview_delay()
      refresh()
      for row, group in pairs(group_rows) do
        if group == path then vim.api.nvim_win_set_cursor(cockpit_winid, { row, 0 }); break end
      end
    end, { buffer = bufnr, desc = "Collapse or expand workspace" })
    vim.keymap.set("n", "Z", function()
      local id = selected_thread_id()
      local thread = stored_thread(id)
      if not thread then return end
      local attention = cockpit.attention(thread, runtimes[id], {
        owner_pid = vim.fn.getpid(), owner_instance_id = state.editor_instance_id, fingerprints = fingerprints,
      })
      if snoozed[id] then snoozed[id] = nil
      else snoozed[id] = { signature = attention.signature, until_at = os.time() + 900 } end
      refresh()
    end, { buffer = bufnr, desc = "Snooze attention for 15 minutes or unsnooze" })
    vim.keymap.set("n", "m", function()
      local id = selected_thread_id()
      local target_backend, thread = thread_backend(id)
      local completion = thread and thread.metadata and thread.metadata.cockpit_completion
      if not target_backend or not completion then return end
      target_backend.update_thread(id, { metadata = { cockpit_ack_completion = completion.id } }, { preserve_updated_at = true })
      refresh()
    end, { buffer = bufnr, desc = "Acknowledge completed response" })
    vim.keymap.set("n", "V", function()
      cancel_preview_delay()
      preview_enabled, preview_mode, detail_section = true, "details", "since"
      refresh()
    end, { buffer = bufnr, desc = "Show changes since last check" })
    vim.keymap.set("n", "gC", function()
      local id = selected_thread_id()
      local target_backend = thread_backend(id)
      if not id or not target_backend or type(target_backend.show_thread_changes_since_check) ~= "function" then return end
      local opened, err = target_backend.show_thread_changes_since_check(id)
      if not opened then vim.notify(tostring(err), vim.log.levels.WARN) end
    end, { buffer = bufnr, desc = "Compare recorded code since last check" })
    vim.keymap.set("n", "u", function()
      local id = selected_thread_id()
      local target_backend = thread_backend(id)
      if not id or not target_backend or type(target_backend.mark_thread_observed) ~= "function" then return end
      local updated, err = target_backend.mark_thread_observed(id)
      if not updated then
        vim.notify(type(err) == "table" and (err.message or err.code) or tostring(err), vim.log.levels.WARN)
      end
      refresh()
    end, { buffer = bufnr, desc = "Mark recorded history checked without approving changes" })
    vim.keymap.set("n", "w", function()
      local id = selected_thread_id()
      local target_backend, thread = thread_backend(id)
      if not thread or type(target_backend.set_thread_review_state) ~= "function" then return end
      local Review = require("lazyagent.acp.cockpit_review")
      local version = Review.version(thread)
      local tracked = Review.enabled(thread)
      local choices = tracked and {
        { state = "not_started", label = "Not started" },
        { state = "reviewing", label = "Reviewing" },
        { state = "changes_requested", label = "Changes requested" },
        { state = "done", label = "Review done" },
        { state = "off", label = "Disable review tracking for this session" },
      } or { { state = "not_started", label = "Enable review tracking for this session" } }
      vim.ui.select(choices, { prompt = "Review tracking:", format_item = function(item) return item.label end }, function(choice)
        if not choice or not vim.api.nvim_buf_is_valid(bufnr) then return end
        local function save(fingerprint)
          if not vim.api.nvim_buf_is_valid(bufnr) then return end
          local updated, err = target_backend.set_thread_review_state(id, choice.state, {
            fingerprint = fingerprint, expected_version = choice.state == "done" and version or nil,
            require_enabled = tracked and choice.state ~= "off",
          })
          if not updated then
            vim.notify(type(err) == "table" and (err.message or err.code) or tostring(err), vim.log.levels.WARN)
          end
          invalidate_fingerprint(thread.cwd)
          pending_refresh = true
        end
        if choice.state ~= "done" then save(); refresh(); return end
        local job
        job = require("lazyagent.acp.workspace_fingerprint").capture(thread.cwd, function(fingerprint, err)
          if job then review_jobs[job] = nil end
          if fingerprint then save(fingerprint)
          elseif vim.api.nvim_buf_is_valid(bufnr) then vim.notify(tostring(err), vim.log.levels.WARN) end
        end)
        if job then review_jobs[job] = true end
      end)
    end, { buffer = bufnr, desc = "Set thread review state" })
    vim.keymap.set("n", "K", function()
      cancel_preview_delay()
      preview_enabled = true
      preview_mode = preview_mode == "details" and "summary" or "details"
      if preview_mode == "details" then invalidate_fingerprint(selected_workspace()) end
      refresh()
    end, { buffer = bufnr, desc = "Toggle thread details" })
    vim.keymap.set("n", "<Tab>", function()
      local sections = { "overview", "changes", "tests", "queue", "since" }
      local index = 1
      for i, section in ipairs(sections) do if section == detail_section then index = i end end
      detail_section = sections[index % #sections + 1]
      cancel_preview_delay()
      preview_enabled, preview_mode = true, "details"
      if detail_section == "tests" then invalidate_fingerprint(selected_workspace()) end
      refresh()
    end, { buffer = bufnr, desc = "Next thread detail section" })
    vim.keymap.set("n", "C", function()
      local id = selected_thread_id()
      if id then module.show_thread_changes(id) end
    end, { buffer = bufnr, desc = "Review selected thread changes" })
    vim.keymap.set("n", "Q", function()
      local key, session = local_session_key(selected_thread_id())
      local target_backend = key and state.backends[session.backend]
      if target_backend and type(target_backend.show_prompt_queue) == "function" then
        target_backend.show_prompt_queue(session.pane_id)
      end
    end, { buffer = bufnr, desc = "Manage selected thread prompt queue" })
    vim.keymap.set("n", "A", function()
      local key, session = local_session_key(selected_thread_id())
      local target_backend = key and state.backends[session.backend]
      if not target_backend or type(target_backend.get_pending_permission) ~= "function" then return end
      local pending = target_backend.get_pending_permission(session.pane_id)
      if not pending then
        vim.notify("LazyAgent ACP: no active permission request; questions and authentication use the shared input dialog", vim.log.levels.INFO)
        return
      end
      vim.ui.select(pending.choices, {
        prompt = pending.title,
        format_item = function(choice) return choice.label end,
      }, function(choice)
        if not choice then return end
        local current = target_backend.get_pending_permission(session.pane_id)
        if not current or current.request_id ~= pending.request_id then
          vim.notify("LazyAgent ACP: permission request changed or expired", vim.log.levels.WARN)
          return
        end
        local accepted, err = target_backend.respond_permission(session.pane_id, choice.option_id, choice.scope, pending.request_id)
        if not accepted then vim.notify(tostring(err), vim.log.levels.WARN) end
        pending_refresh = true
      end)
    end, { buffer = bufnr, desc = "Respond to current permission request" })

    vim.keymap.set("n", "<CR>", function()
      local control = controls[vim.api.nvim_win_get_cursor(cockpit_winid)[1]]
      if control then
        expanded_groups[control.path] = not control.expanded
        cancel_preview_delay()
        refresh()
        if control.expanded then
          for row, item in pairs(controls) do
            if item.path == control.path then
              vim.api.nvim_win_set_cursor(cockpit_winid, { row, 0 })
              break
            end
          end
        end
        return
      end
      local thread_id = selected_thread_id()
      if not thread_id then return end
      cancel_preview_delay()
      preview_enabled = true
      preview_mode = preview_mode == "mirror" and "summary" or "mirror"
      preview_signature = nil
      if preview_winid and vim.api.nvim_win_is_valid(preview_winid) then
        if preview_layout == "horizontal" then
          local height = preview_mode == "mirror" and math.max(12, math.floor(vim.o.lines * 0.35)) or 10
          vim.api.nvim_win_set_height(preview_winid, height)
        end
      end
      update_preview(thread_id, true)
    end, { buffer = bufnr, silent = true, desc = "Toggle ACP thread latest response or mirror" })
    local function open_selected_thread(focus_agent_view)
      local thread_id = selected_thread_id()
      if thread_id then
        cancel_preview_delay()
        if preview_winid and vim.api.nvim_win_is_valid(preview_winid) then
          preview_enabled = false
          vim.api.nvim_win_close(preview_winid, true)
          preview_winid = nil
        end
        module.open_thread(thread_id, {
          placement_winid = cockpit_winid,
          focus_agent_view = focus_agent_view,
          relocate_agent_view = true,
        })
      end
    end
    local function capability_runtime(thread)
      if not thread then return nil end
      if runtimes[thread.thread_id] then return runtimes[thread.thread_id] end
      for _, runtime in pairs(runtimes) do
        if runtime.acp_provider_id == thread.provider_id then return runtime end
      end
      return nil
    end
    local function open_selected_thread_explicit(mode)
      local thread = stored_thread(selected_thread_id())
      local supported = false
      for _, action in ipairs(require("lazyagent.acp.cockpit").explicit_activation_actions(
        thread, capability_runtime(thread)
      )) do
        if action.mode == mode then supported = true; break end
      end
      if not supported then
        vim.notify("LazyAgent ACP: this explicit activation is not supported by the connected provider", vim.log.levels.WARN)
        return
      end
      module.open_thread(thread.thread_id, {
        placement_winid = cockpit_winid,
        focus_agent_view = true,
        relocate_agent_view = true,
        activation_mode = mode,
      })
    end
    vim.keymap.set("n", "o", function()
      open_selected_thread(false)
    end, { buffer = bufnr, silent = true, desc = "Open or resume ACP cockpit thread" })
    vim.keymap.set("n", "O", function()
      open_selected_thread(true)
    end, { buffer = bufnr, silent = true, desc = "Open or resume and focus ACP cockpit thread" })
    vim.keymap.set("n", "L", function() open_selected_thread_explicit("load") end, {
      buffer = bufnr, silent = true, desc = "Load ACP thread with native history replay",
    })
    vim.keymap.set("n", "M", function() open_selected_thread_explicit("resume") end, {
      buffer = bufnr, silent = true, desc = "Resume ACP thread without native replay",
    })
    vim.keymap.set("n", "n", function()
      module.request_new_agent(selected_workspace())
    end, { buffer = bufnr, silent = true, desc = "Create an ACP agent in the project Neovim" })
    vim.keymap.set("n", "i", function()
      local id = selected_thread_id()
      local agent_name = id and thread_agents[id] or nil
      local thread = id and stored_thread(id) or nil
      if not agent_name or not thread then
        vim.notify("LazyAgent ACP: this thread is not live; press o to resume it", vim.log.levels.INFO)
        return
      end
      start_interactive_session({
        agent_name = agent_name,
        acp_thread_title = thread.title,
        reuse = true,
        window_type = "float",
        window_opts = { width_ratio = 0.55, height = 10 },
        start_in_insert_on_focus = true,
        source_bufnr = bufnr,
        source_winid = cockpit_winid,
        title = " Message · " .. tostring(thread.provider_id or "Agent") .. " ",
      })
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(bufnr) then refresh() end
      end, 50)
    end, { buffer = bufnr, silent = true, desc = "Message selected live ACP thread" })
    vim.keymap.set("n", "<C-y>", function()
      local thread = stored_thread(selected_thread_id())
      local ref = require("lazyagent.acp.cockpit").agent_ref(thread)
      if not ref then return end
      vim.fn.setreg('"', ref)
      pcall(vim.fn.setreg, "+", ref)
      vim.notify("Copied LazyAgent ref: " .. ref, vim.log.levels.INFO)
    end, { buffer = bufnr, silent = true, desc = "Copy selected ACP agent reference" })
    vim.keymap.set("n", "]a", function() jump_live(1) end, {
      buffer = bufnr, silent = true, desc = "Next live ACP thread",
    })
    vim.keymap.set("n", "[a", function() jump_live(-1) end, {
      buffer = bufnr, silent = true, desc = "Previous live ACP thread",
    })
    vim.keymap.set("n", "P", function()
      cancel_preview_delay()
      if preview_winid and vim.api.nvim_win_is_valid(preview_winid) then
        preview_enabled = false
        vim.api.nvim_win_close(preview_winid, true)
        preview_winid = nil
      else
        preview_enabled = true
        preview_signature = nil
        update_preview(nil, true)
      end
    end, { buffer = bufnr, silent = true, desc = "Toggle ACP cockpit preview" })
    vim.keymap.set("n", "s", function()
      cancel_preview_delay()
      preview_layout = preview_layout == "split" and "horizontal" or "split"
      if preview_winid and vim.api.nvim_win_is_valid(preview_winid) then
        vim.api.nvim_win_close(preview_winid, true)
        preview_winid = nil
      end
      preview_enabled = true
      preview_signature = nil
      update_preview(nil, true)
      vim.notify("LazyAgent ACP cockpit preview: " .. preview_layout, vim.log.levels.INFO)
    end, { buffer = bufnr, silent = true, desc = "Toggle ACP cockpit preview layout" })
    vim.keymap.set("n", "v", function()
      local thread_id = line_map[vim.api.nvim_win_get_cursor(0)[1]]
      if thread_id then module.open_thread_transcript(thread_id) end
    end, { buffer = bufnr, silent = true, desc = "Open ACP cockpit raw transcript" })
    vim.keymap.set("n", "b", function()
      local id = selected_thread_id()
      if id then module.branch_thread(id) end
      refresh()
    end, { buffer = bufnr, silent = true, desc = "Branch selected ACP thread at its latest completed turn" })
    vim.keymap.set("n", "r", function()
      for root in pairs(fingerprint_checks) do invalidate_fingerprint(root) end
      refresh()
    end, { buffer = bufnr, silent = true, desc = "Refresh ACP cockpit" })
    vim.keymap.set("n", "R", function()
      local id = selected_thread_id()
      if id then module.prompt_rename_thread(id, refresh) end
    end, { buffer = bufnr, silent = true, desc = "Rename ACP cockpit thread" })
    vim.keymap.set("n", "x", function()
      local id = line_map[vim.api.nvim_win_get_cursor(0)[1]]
      local agent_name = id and thread_agents[id] or nil
      if not agent_name then
        if id then module.close_disconnected_thread(id, function()
          if vim.api.nvim_buf_is_valid(bufnr) then refresh() end
        end) end
        return
      end
      vim.ui.select({ "Cancel", "Stop" }, { prompt = "Stop this ACP process?" }, function(choice)
        if choice ~= "Stop" then return end
        close_session(agent_name)
        vim.defer_fn(function()
          if vim.api.nvim_buf_is_valid(bufnr) then refresh() end
        end, 150)
      end)
    end, { buffer = bufnr, silent = true, desc = "Stop selected ACP cockpit process" })
    vim.keymap.set("n", "/", function()
      vim.ui.input({ prompt = "Filter ACP cockpit: ", default = query }, function(value)
        if value == nil or not vim.api.nvim_buf_is_valid(bufnr) then return end
        local compiled, err = require("lazyagent.acp.cockpit_query").compile(value)
        if not compiled then vim.notify(err, vim.log.levels.WARN); return end
        query, view_name = value, nil
        cancel_preview_delay()
        refresh()
      end)
    end, { buffer = bufnr, silent = true, desc = "Filter ACP cockpit" })
    vim.keymap.set("n", "S", function()
      local saved_query, saved_attention = query, attention_only
      vim.ui.input({ prompt = "Save Cockpit view as: ", default = view_name or "" }, function(name)
        if not name or vim.trim(name) == "" or not vim.api.nvim_buf_is_valid(bufnr) then return end
        name = vim.trim(name)
        local existing, read_err = view_store:get(name)
        if read_err then vim.notify(read_err, vim.log.levels.WARN); return end
        local function save()
          if not vim.api.nvim_buf_is_valid(bufnr) then return end
          local saved, err = view_store:save(name, saved_query, saved_attention)
          if not saved then vim.notify(err, vim.log.levels.WARN); return end
          if query == saved_query and attention_only == saved_attention then view_name = saved.name end
          refresh()
        end
        if existing then
          vim.ui.select({ "Cancel", "Overwrite" }, { prompt = "Replace saved view '" .. name .. "'?" }, function(choice)
            if choice == "Overwrite" then save() end
          end)
        else save() end
      end)
    end, { buffer = bufnr, desc = "Save current Cockpit filter and attention view" })
    vim.keymap.set("n", "g/", function()
      vim.ui.input({ prompt = "Search transcript text: ", default = body_query }, function(value)
        if not value or vim.trim(value) == "" or not vim.api.nvim_buf_is_valid(bufnr) then return end
        body_query = value
        local cockpit = require("lazyagent.acp.cockpit")
        local search_opts = { current_root = current_root, owner_pid = vim.fn.getpid(), owner_instance_id = state.editor_instance_id,
          snoozed = snoozed, fingerprints = fingerprints, fingerprint_pending = fingerprint_pending }
        local candidates = cockpit.filter(stored_threads, query, runtimes, search_opts)
        if attention_only then candidates = vim.tbl_filter(function(thread)
          return cockpit.needs_attention(thread, runtimes[thread.thread_id], search_opts)
        end, candidates) end
        table.sort(candidates, function(a, b)
          if a.updated_at == b.updated_at then return a.thread_id < b.thread_id end
          return tostring(a.updated_at or "") > tostring(b.updated_at or "")
        end)
        if not vim.api.nvim_win_is_valid(cockpit_winid)
          or vim.api.nvim_win_get_tabpage(cockpit_winid) ~= vim.api.nvim_get_current_tabpage() then return end
        vim.api.nvim_set_current_win(cockpit_winid)
        if body_search then body_search.close() end
        body_search = require("lazyagent.acp.cockpit_search").open(candidates, value, { owner_buf = bufnr,
          scope = (query ~= "" and query or "All threads") .. (attention_only and " · attention only" or "") })
      end)
    end, { buffer = bufnr, desc = "Search transcript bodies across filtered threads" })
    vim.keymap.set("n", "F", function()
      local saved, err = view_store:list()
      if err then vim.notify(err, vim.log.levels.WARN) end
      if not saved then return end
      local items = {
        { name = "All threads", query = "", attention_only = false, builtin = true },
        { name = "Needs attention", query = "", attention_only = true, builtin = true },
        { name = "Current workspace", query = "workspace:current", attention_only = false, builtin = true },
      }
      vim.list_extend(items, saved)
      vim.ui.select(items, { prompt = "Cockpit view:", format_item = function(item)
        return (item.builtin and "[Built-in] " or "") .. item.name .. (item.query ~= "" and (" · " .. item.query) or "")
      end }, function(choice)
        if not choice or not vim.api.nvim_buf_is_valid(bufnr) then return end
        query, attention_only = choice.query, choice.attention_only
        view_name = choice.name
        cancel_preview_delay()
        refresh()
      end)
    end, { buffer = bufnr, desc = "Choose saved or built-in Cockpit view" })
    vim.keymap.set("n", "gF", function()
      local saved, err = view_store:list()
      if err then vim.notify(err, vim.log.levels.WARN) end
      if not saved or #saved == 0 then return end
      vim.ui.select(saved, { prompt = "Delete saved Cockpit view:", format_item = function(item) return item.name end }, function(choice)
        if not choice or not vim.api.nvim_buf_is_valid(bufnr) then return end
        vim.ui.select({ "Cancel", "Delete" }, { prompt = "Delete saved view '" .. choice.name .. "'?" }, function(answer)
          if answer ~= "Delete" or not vim.api.nvim_buf_is_valid(bufnr) then return end
          local deleted, delete_err = view_store:delete(choice.name)
          if not deleted then vim.notify(delete_err, vim.log.levels.WARN); return end
          if view_name == choice.name then view_name = nil end
          refresh()
        end)
      end)
    end, { buffer = bufnr, desc = "Delete saved Cockpit view" })
    vim.keymap.set("n", "p", function()
      local id = line_map[vim.api.nvim_win_get_cursor(0)[1]]
      local target_backend, thread = thread_backend(id)
      if target_backend and thread then
        local metadata = vim.deepcopy(thread.metadata or {})
        metadata.cockpit_pinned = metadata.cockpit_pinned ~= true
        target_backend.update_thread(id, { metadata = metadata })
        refresh()
      end
    end, { buffer = bufnr, silent = true, desc = "Pin ACP cockpit thread" })
    vim.keymap.set("n", "t", function()
      local id = selected_thread_id()
      local target_backend, thread = thread_backend(id)
      if not target_backend or not thread then return end
      local previous = thread.metadata and thread.metadata.test_result and thread.metadata.test_result.command or ""
      vim.ui.input({ prompt = "Test command: ", default = previous }, function(command)
        if not command or command == "" then return end
        local accepted, err = require("lazyagent.acp.worktree_test").run(target_backend, thread, command, function()
          invalidate_fingerprint(thread.cwd)
          if vim.api.nvim_buf_is_valid(bufnr) then pending_refresh = true end
        end)
        if not accepted then vim.notify(tostring(err), vim.log.levels.WARN) end
        refresh()
      end)
    end, { buffer = bufnr, silent = true, desc = "Run ACP thread test" })
    vim.keymap.set("n", "a", function()
      local id = line_map[vim.api.nvim_win_get_cursor(0)[1]]
      local _, thread = thread_backend(id)
      if thread and thread.status == "archived" then module.restore_thread(id) else module.archive_thread(id) end
      refresh()
    end, { buffer = bufnr, silent = true, desc = "Archive or restore ACP thread" })
    vim.keymap.set("n", "d", function()
      local id = line_map[vim.api.nvim_win_get_cursor(0)[1]]
      if not id then return end
      local _, thread = thread_backend(id)
      thread = vim.deepcopy(thread)
      local options = { "Cancel" }
      if thread and thread.process_id ~= nil then options[#options + 1] = "Kill process (keep history)" end
      options[#options + 1] = "Delete"
      local function refreshed()
        if vim.api.nvim_buf_is_valid(bufnr) then refresh() end
      end
      vim.ui.select(options, { prompt = "Kill process or delete cockpit history permanently?" }, function(choice)
        if choice ~= "Kill process (keep history)" and choice ~= "Delete" then return end
        local _, latest = thread_backend(id)
        if not same_process_owner(thread, latest) then
          vim.notify("LazyAgent ACP: thread ownership changed; refresh before retrying", vim.log.levels.WARN)
          return
        end
        if choice == "Kill process (keep history)" then
          local agent_name = thread_agents[id]
          if agent_name then
            force_close_session(agent_name)
            vim.defer_fn(refreshed, 150)
          else
            module.close_disconnected_thread(id, refreshed, { confirmed = true, kill = true })
          end
        elseif choice == "Delete" then
          module.force_delete_thread(id, refreshed)
        end
      end)
    end, { buffer = bufnr, silent = true, desc = "Kill ACP process or delete thread history" })
    vim.keymap.set("n", "D", function()
      local id = line_map[vim.api.nvim_win_get_cursor(0)[1]]
      if not id then return end
      local _, thread = thread_backend(id)
      thread = vim.deepcopy(thread)
      vim.ui.select({ "Cancel", "Force delete" }, {
        prompt = "Force delete cockpit thread and stop its process? This cannot be undone.",
      }, function(choice)
        if choice ~= "Force delete" then return end
        local _, latest = thread_backend(id)
        if not same_process_owner(thread, latest) then
          vim.notify("LazyAgent ACP: thread ownership changed; refresh before retrying", vim.log.levels.WARN)
          return
        end
        module.force_delete_thread(id, function()
          if vim.api.nvim_buf_is_valid(bufnr) then refresh() end
        end)
      end)
    end, { buffer = bufnr, silent = true, desc = "Force delete ACP cockpit thread" })
    vim.keymap.set("n", "c", function()
      local id = line_map[vim.api.nvim_win_get_cursor(0)[1]]
      if not id then return end
      vim.ui.select({ "Cancel", "Cleanup worktree" }, { prompt = "Remove clean managed worktree?" }, function(choice)
        if choice == "Cleanup worktree" then module.cleanup_worktree(id); refresh() end
      end)
    end, { buffer = bufnr, silent = true, desc = "Cleanup managed ACP worktree" })
    vim.keymap.set("n", "X", function()
      vim.ui.select({ "Cancel", "Stop all" }, { prompt = "Stop all running ACP processes?" }, function(choice)
        if choice ~= "Stop all" then return end
        local names = vim.tbl_keys(state.sessions or {})
        for _, agent_name in ipairs(names) do
          close_session(agent_name)
        end
        vim.defer_fn(function()
          if vim.api.nvim_buf_is_valid(bufnr) then refresh() end
        end, 150)
      end)
    end, { buffer = bufnr, silent = true, desc = "Stop all running ACP processes" })
    vim.keymap.set("n", "q", function() pcall(vim.cmd, "tabclose") end, {
      buffer = bufnr,
      nowait = true,
      silent = true,
      desc = "Close ACP cockpit",
    })
    vim.keymap.set("n", "?", function()
      local thread = stored_thread(selected_thread_id())
      local items = {
        { key = "<CR>", description = "Expand/collapse history or toggle latest response / mirror" },
        { key = "o", description = "Open or resume thread in Cockpit tab" },
        { key = "O", description = "Open or resume thread and focus agent" },
        { key = "n", description = "Create agent in the project Neovim" },
        { key = "i", description = "Message live thread" },
        { key = "<C-y>", description = "Copy stable agent reference" },
        { key = "v", description = "Open raw transcript" },
        { key = "b", description = "Branch latest completed turn" },
        { key = "]a", description = "Jump to next live thread" },
        { key = "[a", description = "Jump to previous live thread" },
        { key = "P", description = "Show or hide preview" },
        { key = "s", description = "Toggle side / horizontal preview layout" },
        { key = "x", description = "Stop selected process" },
        { key = "/", description = "Filter threads (e.g. status:running unread:true)" },
        { key = "g/", description = "Search transcript text across matching threads" },
        { key = "S", description = "Save filter and attention view" },
        { key = "F", description = "Choose saved or built-in view" },
        { key = "gF", description = "Delete saved view" },
        { key = "p", description = "Pin or unpin thread" },
        { key = "t", description = "Run thread test" },
        { key = "a", description = "Archive or restore thread" },
        { key = "c", description = "Clean up managed worktree" },
        { key = "d", description = "Kill process (keep history) or delete thread" },
        { key = "D", description = "Force delete thread" },
        { key = "X", description = "Stop all processes" },
        { key = "r", description = "Refresh cockpit" },
        { key = "R", description = "Rename thread" },
        { key = "q", description = "Close cockpit" },
        { key = "f", description = "Toggle attention-only view" },
        { key = "]e", description = "Next thread needing attention" },
        { key = "[e", description = "Previous thread needing attention" },
        { key = "za", description = "Collapse or expand workspace" },
        { key = "Z", description = "Snooze attention for 15 minutes / unsnooze" },
        { key = "m", description = "Acknowledge completed response" },
        { key = "K", description = "Toggle thread details" },
        { key = "<Tab>", description = "Next detail section" },
        { key = "C", description = "Review selected thread changes" },
        { key = "gC", description = "Compare recorded code since last check" },
        { key = "Q", description = "Manage selected thread queue" },
        { key = "A", description = "Respond to active permission request" },
        { key = "w", description = "Set review state" },
        { key = "V", description = "Show changes since last check" },
        { key = "u", description = "Mark recorded history checked" },
      }
      local explicit_actions = require("lazyagent.acp.cockpit").explicit_activation_actions(
        thread, capability_runtime(thread)
      )
      for _, action in ipairs(explicit_actions) do
        items[#items + 1] = {
          key = action.mode == "load" and "L" or "M",
          description = action.label,
        }
      end
      vim.ui.select(items, {
        prompt = thread and ("Cockpit · " .. tostring(thread.provider_id or "Agent") .. ":") or "Cockpit actions:",
        kind = "lazyagent-acp-actions",
        format_item = function(item)
          return string.format("%-4s %s", item.key, item.description)
        end,
      }, function(choice)
        if not choice or not vim.api.nvim_buf_is_valid(bufnr) then return end
        local callback
        vim.api.nvim_buf_call(bufnr, function()
          local mapping = vim.fn.maparg(choice.key, "n", false, true)
          callback = type(mapping) == "table" and mapping.callback or nil
        end)
        if type(callback) == "function" and vim.api.nvim_win_is_valid(cockpit_winid) then
          vim.api.nvim_set_current_win(cockpit_winid)
          callback()
        end
      end)
    end, { buffer = bufnr, silent = true, desc = "Open ACP cockpit action menu" })
    vim.api.nvim_create_autocmd("CursorMoved", {
      buffer = bufnr,
      callback = function()
        schedule_preview()
        update_acp_backgrounds()
      end,
    })
    vim.api.nvim_create_autocmd("WinEnter", {
      buffer = bufnr,
      callback = refresh,
    })
    vim.api.nvim_create_autocmd("User", {
      group = preview_augroup,
      pattern = { "LazyAgentACPAttentionChanged", "LazyAgentTurnDone", "LazyAgentChangeJournal", "LazyAgentSessionStopped", "LazyAgentCockpitReview" },
      callback = function()
        for root in pairs(fingerprint_checks) do invalidate_fingerprint(root) end
        pending_refresh = true
      end,
    })
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = preview_augroup,
      callback = function(args)
        for root, check in pairs(fingerprint_checks) do
          if path_in_workspace(args.file, root) then invalidate_fingerprint(root); pending_refresh = true end
        end
      end,
    })
    local last_activity_poll, last_activity_detail = 0, 0
    preview_timer = vim.uv.new_timer()
    preview_timer:start(300, 300, vim.schedule_wrap(function()
      if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_win_is_valid(cockpit_winid)
        or vim.api.nvim_win_get_tabpage(cockpit_winid) ~= vim.api.nvim_get_current_tabpage() then return end
      local now = os.time()
      if not preview_pending and now ~= last_activity_poll then
        last_activity_poll = now
        for id, agent_name in pairs(thread_agents) do
          local active = state.sessions and state.sessions[agent_name]
          local active_backend = active and state.backends and state.backends[active.backend]
          if active_backend and type(active_backend.get_cockpit_activity) == "function" then
            local data = active_backend.get_cockpit_activity(active.pane_id)
            local runtime = runtimes[id]
            if data and runtime then
              if not runtime.acp_activity or data.signature ~= runtime.acp_activity.signature then pending_refresh = true end
              runtime.acp_activity = data
            end
          end
        end
        -- Receipt-time changes during streaming do not refresh the persisted list.
        if not pending_refresh and preview_mode == "details" and now - last_activity_detail >= 5
          and selected_thread_id() == preview_thread_id then
          last_activity_detail = now
          pcall(update_preview, preview_thread_id, false)
        end
      end
      for id, snooze in pairs(snoozed) do
        if snooze.until_at <= os.time() then snoozed[id] = nil; pending_refresh = true end
      end
      if pending_refresh and not preview_pending then
        pending_refresh = false
        refresh()
      end
      if preview_mode ~= "mirror" or preview_pending or not vim.api.nvim_buf_is_valid(bufnr)
        or not vim.api.nvim_win_is_valid(cockpit_winid)
        or vim.api.nvim_win_get_tabpage(cockpit_winid) ~= vim.api.nvim_get_current_tabpage()
        or selected_thread_id() ~= preview_thread_id
      then return end
      pcall(update_preview, preview_thread_id, false)
    end))
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = bufnr,
      once = true,
      callback = function()
        for job in pairs(review_jobs) do pcall(job.kill, job, 15) end
        for _, check in pairs(fingerprint_checks) do if check.job then pcall(check.job.kill, check.job, 15) end end
        cancel_preview_delay()
        if preview_delay_timer then
          preview_delay_timer:close()
          preview_delay_timer = nil
        end
        restore_acp_backgrounds()
        pcall(vim.api.nvim_del_augroup_by_id, preview_augroup)
        if preview_timer then
          preview_timer:stop()
          preview_timer:close()
          preview_timer = nil
        end
        local orphan_win, orphan_buf = preview_winid, preview_bufnr
        preview_winid, preview_bufnr = nil, nil
        -- A native :close only removes the cockpit window, unlike q/tabclose.
        -- Wait for that window operation to finish before closing its preview.
        vim.schedule(function()
          if orphan_win and vim.api.nvim_win_is_valid(orphan_win) then
            pcall(vim.api.nvim_win_close, orphan_win, true)
          end
          if orphan_buf and vim.api.nvim_buf_is_valid(orphan_buf)
            and vim.fn.bufwinid(orphan_buf) < 0 then
            pcall(vim.api.nvim_buf_delete, orphan_buf, { force = true })
          end
        end)
      end,
    })
    refresh()
    if vim.api.nvim_win_is_valid(cockpit_winid) then
      vim.api.nvim_set_current_win(cockpit_winid)
    end
    return true
  end

  return module
end

return M

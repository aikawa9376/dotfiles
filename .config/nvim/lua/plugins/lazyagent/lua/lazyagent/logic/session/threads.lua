local M = {}

function M.setup(deps)
  local state = deps.state
  local agent_logic = deps.agent_logic
  local backend_logic = deps.backend_logic
  local acp_logic = deps.acp_logic
  local start_interactive_session = deps.start_interactive_session
  local module = {}
  local thread_label

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

  function module.open_thread(thread_id)
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
    if thread.metadata and thread.metadata.worktree_state == "active" then
      local _, restore_err = require("lazyagent.acp.worktree").restore(thread)
      if restore_err then
        vim.notify("LazyAgent ACP: " .. restore_err, vim.log.levels.ERROR)
        return false
      end
    end
    start_interactive_session({
      agent_name = thread.provider_id,
      acp_thread_id = thread.thread_id,
      acp_thread_title = thread.title,
      reuse = true,
    })
    return true
  end

  function module.new_thread(provider_id)
    local provider, providers = configured_provider(provider_id)
    if not provider then
      if type(providers) ~= "table" or #providers == 0 then
        vim.notify("LazyAgent ACP: no ACP provider is configured", vim.log.levels.WARN)
        return false
      end
      vim.ui.select(providers, { prompt = "New thread provider:" }, function(choice)
        if choice then
          module.new_thread(choice)
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
      cwd = vim.fn.getcwd(),
      title = provider,
      status = "closed",
    })
    if not thread then
      vim.notify("LazyAgent ACP: failed to create thread: " .. tostring(err), vim.log.levels.ERROR)
      return false
    end
    return module.open_thread(thread.thread_id)
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
    return backend.rename_thread(thread.thread_id, title) ~= nil
  end

  function module.delete_thread(thread_id)
    local backend, thread = thread_backend(thread_id)
    if not backend or not thread or active_mutation_error(thread, "deleting") then
      return false
    end
    return backend.delete_thread(thread.thread_id) == true
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

    local backend = backend_for_provider(nil)
    local threads = backend and backend.list_threads and backend.list_threads({ include_archived = true }) or {}
    threads = vim.tbl_filter(function(thread)
      local turns = thread.change_journal and thread.change_journal.turns or {}
      for index = #turns, 1, -1 do
        if type(turns[index].changes) == "table" and #turns[index].changes > 0 then
          return true
        end
      end
      return false
    end, threads or {})
    if #threads == 0 then
      vim.notify("LazyAgent ACP: no persisted file changes", vim.log.levels.INFO)
      return false
    end
    vim.ui.select(threads, { prompt = "LazyAgent ACP changed threads:", format_item = thread_label }, function(thread)
      if thread then
        module.show_thread_changes(thread.thread_id)
      end
    end)
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
      end
      actions[#actions + 1] = thread.status == "archived" and "Restore" or "Archive"
      actions[#actions + 1] = "Delete"
      vim.ui.select(actions, { prompt = thread_label(thread) .. ":" }, function(action)
        if action == "Open" then
          module.open_thread(thread.thread_id)
        elseif action == "Rename" then
          vim.ui.input({ prompt = "Thread title: ", default = thread.title }, function(title)
            if title and title ~= "" then
              module.rename_thread(thread.thread_id, title)
            end
          end)
        elseif action == "Review changes" then
          module.show_thread_changes(thread.thread_id)
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

  function module.open_cockpit()
    local backend = backend_for_provider(nil)
    if not backend or type(backend.list_threads) ~= "function" then
      vim.notify("LazyAgent ACP: thread store is unavailable", vim.log.levels.ERROR)
      return false
    end
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.cmd("tabnew")
    vim.api.nvim_win_set_buf(0, bufnr)
    vim.api.nvim_buf_set_name(bufnr, "LazyAgent ACP Cockpit [" .. tostring(bufnr) .. "]")
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = "lazyagent_acp_cockpit"

    local line_map = {}
    local stored_threads = {}
    local query = ""
    local function refresh()
      local list_err
      stored_threads, list_err = backend.list_threads({ include_archived = true })
      if not stored_threads then
        vim.notify("LazyAgent ACP cockpit: " .. tostring(list_err), vim.log.levels.ERROR)
        return
      end
      local lines
      local runtimes = {}
      for agent_name, active in pairs(state.sessions or {}) do
        if active.pane_id and active.pane_id ~= "" then
          local active_backend = backend_for_provider(agent_name)
          if active_backend and type(active_backend.get_runtime_snapshot) == "function" then
            local snapshot = active_backend.get_runtime_snapshot(active.pane_id)
            if snapshot and snapshot.acp_thread_id then
              snapshot.agent_status = active.agent_status
              runtimes[snapshot.acp_thread_id] = snapshot
            end
          end
        end
      end
      lines, line_map = require("lazyagent.acp.cockpit").render(
        require("lazyagent.acp.cockpit").filter(stored_threads, query),
        runtimes
      )
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.bo[bufnr].modifiable = false
      vim.bo[bufnr].modified = false
    end

    vim.keymap.set("n", "<CR>", function()
      local thread_id = line_map[vim.api.nvim_win_get_cursor(0)[1]]
      if thread_id then module.open_thread(thread_id) end
    end, { buffer = bufnr, silent = true, desc = "Open ACP cockpit thread" })
    vim.keymap.set("n", "r", refresh, { buffer = bufnr, silent = true, desc = "Refresh ACP cockpit" })
    vim.keymap.set("n", "/", function()
      vim.ui.input({ prompt = "Filter ACP cockpit: ", default = query }, function(value)
        if value ~= nil then query = value; refresh() end
      end)
    end, { buffer = bufnr, silent = true, desc = "Filter ACP cockpit" })
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
    vim.keymap.set("n", "a", function()
      local id = line_map[vim.api.nvim_win_get_cursor(0)[1]]
      local _, thread = thread_backend(id)
      if thread and thread.status == "archived" then module.restore_thread(id) else module.archive_thread(id) end
      refresh()
    end, { buffer = bufnr, silent = true, desc = "Archive or restore ACP thread" })
    vim.keymap.set("n", "d", function()
      local id = line_map[vim.api.nvim_win_get_cursor(0)[1]]
      if not id then return end
      vim.ui.select({ "Cancel", "Delete" }, { prompt = "Delete cockpit thread permanently?" }, function(choice)
        if choice == "Delete" then module.delete_thread(id); refresh() end
      end)
    end, { buffer = bufnr, silent = true, desc = "Delete ACP cockpit thread" })
    vim.keymap.set("n", "c", function()
      local id = line_map[vim.api.nvim_win_get_cursor(0)[1]]
      if not id then return end
      vim.ui.select({ "Cancel", "Cleanup worktree" }, { prompt = "Remove clean managed worktree?" }, function(choice)
        if choice == "Cleanup worktree" then module.cleanup_worktree(id); refresh() end
      end)
    end, { buffer = bufnr, silent = true, desc = "Cleanup managed ACP worktree" })
    vim.keymap.set("n", "X", function()
      vim.ui.select({ "Cancel", "Close all" }, { prompt = "Close all running ACP sessions?" }, function(choice)
        if choice ~= "Close all" then return end
        for agent_name, active in pairs(state.sessions or {}) do
          if active.pane_id then
            local active_backend = backend_for_provider(agent_name)
            if active_backend and type(active_backend.kill_pane) == "function" then active_backend.kill_pane(active.pane_id) end
          end
        end
        vim.schedule(refresh)
      end)
    end, { buffer = bufnr, silent = true, desc = "Close all running ACP threads" })
    vim.keymap.set("n", "q", function() pcall(vim.cmd, "tabclose") end, {
      buffer = bufnr,
      silent = true,
      desc = "Close ACP cockpit",
    })
    refresh()
    return true
  end

  return module
end

return M

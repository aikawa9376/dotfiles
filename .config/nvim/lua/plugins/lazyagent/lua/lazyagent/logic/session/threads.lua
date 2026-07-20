local M = {}
local identity = require("lazyagent.logic.session.identity")

function M.setup(deps)
  local state = deps.state
  local agent_logic = deps.agent_logic
  local backend_logic = deps.backend_logic
  local acp_logic = deps.acp_logic
  local start_interactive_session = deps.start_interactive_session
  local close_session = deps.close_session
  local editor_registry = deps.editor_registry or require("lazyagent.acp.editor_registry")
  local module = {}
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

  local function thread_related_to_current_nvim(thread, local_threads)
    if local_threads[thread.thread_id] then return true end
    local metadata = type(thread.metadata) == "table" and thread.metadata or {}
    if metadata.editor and metadata.editor.instance_id and state.editor_instance_id then
      return metadata.editor.instance_id == state.editor_instance_id
    end
    local owner_pid = metadata.editor and metadata.editor.owner_pid
      or metadata.agentmux and metadata.agentmux.owner_pid
    return tonumber(owner_pid) == vim.fn.getpid()
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

  local function process_state(pid)
    pid = tonumber(pid)
    if not pid or pid <= 0 then return false end
    local ok, result, err, code = pcall((vim.uv or vim.loop).kill, pid, 0)
    if not ok then return nil, result end
    if result == 0 then return true end
    if code == "ESRCH" then return false end
    return nil, err or code
  end

  function module.close_disconnected_thread(thread_id)
    local backend, thread = thread_backend(thread_id)
    if not backend or not thread then
      vim.notify("LazyAgent ACP: thread not found: " .. tostring(thread_id), vim.log.levels.WARN)
      return false
    end
    if thread.status ~= "active" or thread.process_id == nil then
      vim.notify("LazyAgent ACP: selected thread is not disconnected", vim.log.levels.INFO)
      return false
    end
    local alive, process_err = process_state(thread.process_id)
    if alive == true then
      vim.notify("LazyAgent ACP: process is still running; refusing to detach its thread", vim.log.levels.WARN)
      return false
    end
    if alive == nil then
      vim.notify("LazyAgent ACP: cannot verify process state: " .. tostring(process_err), vim.log.levels.WARN)
      return false
    end
    local expected_process_id = thread.process_id
    local updated, err = backend.update_thread(thread.thread_id, {
      status = "closed",
      process_id = vim.NIL,
    }, { expected_process_id = expected_process_id })
    if not updated then
      vim.notify("LazyAgent ACP: failed to recover disconnected thread: " .. tostring(
        type(err) == "table" and err.code or err
      ), vim.log.levels.ERROR)
      return false
    end
    vim.notify("LazyAgent ACP: disconnected thread is now closed and can be resumed", vim.log.levels.INFO)
    return true
  end

  local function delete_thread_record(backend, thread)
    local deleted, err = backend.delete_thread(thread.thread_id)
    if deleted ~= true then
      vim.notify("LazyAgent ACP: delete failed: " .. tostring(err), vim.log.levels.ERROR)
      return false
    end
    if thread.transcript_path and thread.transcript_path ~= "" then
      pcall(vim.fn.delete, thread.transcript_path)
    end
    return true
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
    local local_key = local_session_key(thread.thread_id)
    if thread.status == "active" and thread.process_id ~= nil and not local_key then
      vim.notify(
        "LazyAgent ACP: live thread belongs to another Neovim or is disconnected; stop it there or force delete it first",
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
    local source_bufnr, source_winid = source_anchor(thread)
    start_interactive_session({
      agent_name = thread.provider_id,
      acp_thread_id = thread.thread_id,
      acp_thread_title = thread.title,
      root_dir = workspace,
      cwd = workspace,
      source_bufnr = source_bufnr,
      source_winid = source_winid,
      origin_winid = vim.api.nvim_get_current_win(),
      reuse = true,
    })
    return true
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
    return backend.rename_thread(thread.thread_id, title) ~= nil
  end

  function module.delete_thread(thread_id)
    local backend, thread = thread_backend(thread_id)
    if not backend or not thread or active_mutation_error(thread, "deleting") then
      return false
    end
    return delete_thread_record(backend, thread)
  end

  function module.force_delete_thread(thread_id)
    local backend, thread = thread_backend(thread_id)
    if not backend or not thread then
      return false
    end
    return delete_thread_record(backend, thread)
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
    local local_threads = {}
    for session_key, session in pairs(state.sessions or {}) do
      local id = session_thread_id(session_key, session)
      if id then local_threads[id] = true end
    end
    threads = vim.tbl_filter(function(thread)
      if thread.status ~= "active" then return false end
      if not thread_related_to_current_nvim(thread, local_threads) then return false end
      local turns = thread.change_journal and thread.change_journal.turns or {}
      for index = #turns, 1, -1 do
        if type(turns[index].changes) == "table" and #turns[index].changes > 0 then
          return true
        end
      end
      return false
    end, threads or {})
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
    local origin_bufnr = vim.api.nvim_get_current_buf()
    local current_root = vim.b[origin_bufnr].lazyagent_workspace_root
    if type(current_root) ~= "string" or current_root == "" then
      current_root = require("lazyagent.util").git_root_for_path(vim.api.nvim_buf_get_name(origin_bufnr))
        or vim.fn.getcwd()
    end
    current_root = normalize_path(current_root)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.cmd("tabnew")
    vim.api.nvim_win_set_buf(0, bufnr)
    vim.api.nvim_buf_set_name(bufnr, "LazyAgent ACP Cockpit [" .. tostring(bufnr) .. "]")
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = "lazyagent_acp_cockpit"

    local cockpit_winid = vim.api.nvim_get_current_win()
    local line_map = {}
    local stored_threads = {}
    local query = ""
    local warned_conflicts = ""
    local thread_agents = {}
    local preview_bufnr
    local preview_winid
    local preview_enabled = true
    local preview_mode = "summary"
    local preview_layout = require("lazyagent.acp.cockpit").normalize_preview_layout(
      ((state.opts or {}).acp or {}).cockpit_preview_layout or (state.opts or {}).cockpit_preview_layout
    )
    local preview_thread_id
    local preview_signature
    local preview_timer
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
        vim.bo[preview_bufnr].filetype = "markdown"
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

    local function mirror_snapshot(thread)
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
        local ok, lines = pcall(vim.fn.readfile, path)
        if ok and lines then
          return lines, table.concat({
            "file", tostring(thread.thread_id), tostring(vim.fn.getftime(path)), tostring(vim.fn.getfsize(path)),
          }, ":")
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
          lines, signature = mirror_snapshot(thread)
          if not force and preview_thread_id == thread.thread_id and preview_signature == signature then return end
          preview_thread_id = thread.thread_id
          preview_signature = signature
          if #lines == 0 then lines = { "_The transcript is currently empty._" } end
          if preview_winid and vim.api.nvim_win_is_valid(preview_winid) then
            vim.wo[preview_winid].winbar = "%#DiagnosticInfo# PREVIEW %*· Mirror · "
              .. tostring(thread.provider_id or "Agent") .. " · " .. title .. " "
          end
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
      local previous_count = vim.api.nvim_buf_line_count(preview_bufnr)
      local follow = preview_winid and vim.api.nvim_win_is_valid(preview_winid)
        and vim.api.nvim_win_get_cursor(preview_winid)[1] >= previous_count
      vim.bo[preview_bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(preview_bufnr, 0, -1, false, lines)
      vim.bo[preview_bufnr].modifiable = false
      vim.bo[preview_bufnr].modified = false
      if follow and preview_winid and vim.api.nvim_win_is_valid(preview_winid) then
        pcall(vim.api.nvim_win_set_cursor, preview_winid, { math.max(1, #lines), 0 })
      end
      if preview_mode == "mirror" then
        vim.schedule(maybe_mark_preview_read)
      end
    end

    local function cockpit_width()
      local windows = vim.fn.win_findbuf(bufnr)
      local winid = windows[1]
      return math.max(40, (winid and vim.api.nvim_win_get_width(winid) or vim.o.columns) - 1)
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
      local runtimes = {}
      thread_agents = {}
      for agent_name, active in pairs(state.sessions or {}) do
        if active.pane_id and active.pane_id ~= "" then
          local active_backend = backend_for_provider(agent_name)
          if active_backend and type(active_backend.get_runtime_snapshot) == "function" then
            local snapshot = active_backend.get_runtime_snapshot(active.pane_id)
            if snapshot and snapshot.acp_thread_id then
              snapshot.agent_status = active.agent_status
              snapshot.pane_id = active.pane_id
              runtimes[snapshot.acp_thread_id] = snapshot
              thread_agents[snapshot.acp_thread_id] = agent_name
            end
          end
        end
      end
      local highlights
      local open_thread_id = require("lazyagent.logic.session.identity").thread_id(
        state.open_agent,
        state.open_agent and state.sessions and state.sessions[state.open_agent] or nil
      )
      lines, line_map, highlights = require("lazyagent.acp.cockpit").render(
        require("lazyagent.acp.cockpit").filter(stored_threads, query),
        runtimes,
        {
          width = cockpit_width(),
          open_thread_id = open_thread_id,
          owner_pid = vim.fn.getpid(),
          owner_instance_id = state.editor_instance_id,
          current_root = current_root,
        }
      )
      local conflicts = require("lazyagent.acp.cockpit").conflicts(stored_threads)
      local conflict_hash = vim.fn.sha256(vim.inspect(conflicts))
      if next(conflicts) and conflict_hash ~= warned_conflicts then
        warned_conflicts = conflict_hash
        vim.notify("LazyAgent ACP: active threads share changed files in the same workspace", vim.log.levels.WARN)
      end
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.bo[bufnr].modifiable = false
      vim.bo[bufnr].modified = false
      require("lazyagent.acp.cockpit").apply_highlights(bufnr, highlights)
      if selected_id and vim.api.nvim_win_is_valid(cockpit_winid) then
        for line, id in pairs(line_map) do
          if id == selected_id then
            vim.api.nvim_win_set_cursor(cockpit_winid, { line, 0 })
            break
          end
        end
      end
      update_preview(selected_id)
      update_acp_backgrounds()
      refreshing = false
    end

    local function jump_live(delta)
      local rows = {}
      for line, id in pairs(line_map) do
        if thread_agents[id] then rows[#rows + 1] = line end
      end
      table.sort(rows)
      if #rows == 0 then
        vim.notify("LazyAgent ACP: no live threads", vim.log.levels.INFO)
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
      update_preview(line_map[target])
      update_acp_backgrounds()
    end

    vim.keymap.set("n", "<CR>", function()
      local thread_id = selected_thread_id()
      if not thread_id then return end
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
    vim.keymap.set("n", "o", function()
      local thread_id = selected_thread_id()
      if thread_id then
        if preview_winid and vim.api.nvim_win_is_valid(preview_winid) then
          preview_enabled = false
          vim.api.nvim_win_close(preview_winid, true)
          preview_winid = nil
        end
        module.open_thread(thread_id)
      end
    end, { buffer = bufnr, silent = true, desc = "Open or resume ACP cockpit thread" })
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
    vim.keymap.set("n", "]a", function() jump_live(1) end, {
      buffer = bufnr, silent = true, desc = "Next live ACP thread",
    })
    vim.keymap.set("n", "[a", function() jump_live(-1) end, {
      buffer = bufnr, silent = true, desc = "Previous live ACP thread",
    })
    vim.keymap.set("n", "P", function()
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
    vim.keymap.set("n", "r", refresh, { buffer = bufnr, silent = true, desc = "Refresh ACP cockpit" })
    vim.keymap.set("n", "x", function()
      local id = line_map[vim.api.nvim_win_get_cursor(0)[1]]
      local agent_name = id and thread_agents[id] or nil
      if not agent_name then
        if id and module.close_disconnected_thread(id) then refresh() end
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
    vim.keymap.set("n", "t", function()
      local id = line_map[vim.api.nvim_win_get_cursor(0)[1]]
      local target_backend, thread = thread_backend(id)
      if not target_backend or not thread then return end
      local previous = thread.metadata and thread.metadata.test_result and thread.metadata.test_result.command or ""
      vim.ui.input({ prompt = "Test command: ", default = previous }, function(command)
        if not command or command == "" then return end
        local argv, argv_err = require("lazyagent.acp.worktree_test").argv(command)
        if not argv then vim.notify(argv_err, vim.log.levels.ERROR); return end
        local started = vim.uv.hrtime() / 1000000
        target_backend.update_thread(id, { metadata = { test_result = { command = command, status = "running" } } })
        refresh()
        vim.system(argv, { cwd = thread.cwd, text = true }, function(result)
          vim.schedule(function()
            local finished = vim.uv.hrtime() / 1000000
            local test_result = require("lazyagent.acp.worktree_test").finish(command, started, result, finished)
            target_backend.update_thread(id, { metadata = { test_result = test_result } })
            if vim.api.nvim_buf_is_valid(bufnr) then refresh() end
          end)
        end)
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
      vim.ui.select({ "Cancel", "Delete" }, { prompt = "Delete cockpit thread permanently?" }, function(choice)
        if choice == "Delete" then module.delete_thread(id); refresh() end
      end)
    end, { buffer = bufnr, silent = true, desc = "Delete ACP cockpit thread" })
    vim.keymap.set("n", "D", function()
      local id = line_map[vim.api.nvim_win_get_cursor(0)[1]]
      if not id then return end
      vim.ui.select({ "Cancel", "Force delete" }, {
        prompt = "Force delete cockpit thread and stop its process? This cannot be undone.",
      }, function(choice)
        if choice ~= "Force delete" then return end
        local agent_name = thread_agents[id]
        if agent_name then close_session(agent_name) end
        module.force_delete_thread(id)
        refresh()
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
        { key = "<CR>", description = "Toggle latest response / transcript mirror" },
        { key = "o", description = "Open or resume thread" },
        { key = "n", description = "Create agent in the project Neovim" },
        { key = "i", description = "Message live thread" },
        { key = "v", description = "Open raw transcript" },
        { key = "]a", description = "Jump to next live thread" },
        { key = "[a", description = "Jump to previous live thread" },
        { key = "P", description = "Show or hide preview" },
        { key = "s", description = "Toggle side / horizontal preview layout" },
        { key = "x", description = "Stop selected process" },
        { key = "/", description = "Filter threads" },
        { key = "p", description = "Pin or unpin thread" },
        { key = "t", description = "Run thread test" },
        { key = "a", description = "Archive or restore thread" },
        { key = "c", description = "Clean up managed worktree" },
        { key = "d", description = "Delete stopped thread" },
        { key = "D", description = "Force delete thread" },
        { key = "X", description = "Stop all processes" },
        { key = "r", description = "Refresh cockpit" },
        { key = "q", description = "Close cockpit" },
      }
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
        if type(callback) == "function" then callback() end
      end)
    end, { buffer = bufnr, silent = true, desc = "Open ACP cockpit action menu" })
    vim.api.nvim_create_autocmd("CursorMoved", {
      buffer = bufnr,
      callback = function()
        update_preview()
        update_acp_backgrounds()
      end,
    })
    vim.api.nvim_create_autocmd("WinEnter", {
      buffer = bufnr,
      callback = refresh,
    })
    preview_timer = vim.uv.new_timer()
    preview_timer:start(300, 300, vim.schedule_wrap(function()
      if preview_mode ~= "mirror" or not vim.api.nvim_buf_is_valid(bufnr) then return end
      pcall(update_preview, nil, false)
    end))
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = bufnr,
      once = true,
      callback = function()
        restore_acp_backgrounds()
        pcall(vim.api.nvim_del_augroup_by_id, preview_augroup)
        if preview_timer then
          preview_timer:stop()
          preview_timer:close()
          preview_timer = nil
        end
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

local M = {}
local identity = require("lazyagent.logic.session.identity")

local BUNDLE_VERSION = 2

function M.setup(deps)
  local state = deps.state
  local acp_logic = deps.acp_logic
  local backend_logic = deps.backend_logic
  local cache_logic = deps.cache_logic
  local capture_scratch = deps.capture_scratch
  local open_thread = deps.open_thread
  local start_session = deps.start_session

  local module = {}
  local restore_started = false

  local function bundle_dir()
    local dir = cache_logic.get_cache_dir() .. "/acp/restart"
    if vim.fn.isdirectory(dir) == 0 then
      vim.fn.mkdir(dir, "p")
    end
    return vim.fs.normalize(dir)
  end

  local function restart_identity()
    for _, name in ipairs({ "TMUX_PANE", "KITTY_WINDOW_ID", "WEZTERM_PANE", "TERM_SESSION_ID" }) do
      local value = vim.env[name]
      if value and value ~= "" then return name .. "=" .. value end
    end
    return table.concat({ vim.fn.getcwd(), vim.inspect(vim.v.argv or {}) }, "\n")
  end

  local function bundle_path()
    return string.format("%s/native-%s.json", bundle_dir(), vim.fn.sha256(restart_identity()))
  end

  local function valid_bundle_path(path)
    if type(path) ~= "string" or path == "" then return false end
    local normalized = vim.fs.normalize(path)
    local dir = bundle_dir()
    return normalized:sub(1, #dir + 1) == dir .. "/"
      and normalized:match("/native%-%x+%.json$") ~= nil
  end

  local function write_bundle(path, bundle)
    local ok, encoded = pcall(vim.json.encode, bundle)
    if not ok or not encoded then return false end
    return pcall(vim.fn.writefile, { encoded }, path)
  end

  local function read_bundle(path)
    if not valid_bundle_path(path) or vim.fn.filereadable(path) ~= 1 then return nil end
    local ok_read, lines = pcall(vim.fn.readfile, path)
    if not ok_read or type(lines) ~= "table" or #lines == 0 then return nil end
    local ok_decode, bundle = pcall(vim.json.decode, table.concat(lines, "\n"))
    if not ok_decode or type(bundle) ~= "table" then return nil end
    if bundle.kind ~= "lazyagent-acp-native-restart" or bundle.version ~= BUNDLE_VERSION then return nil end
    local created_at = tonumber(bundle.created_at_unix)
    if not created_at or math.abs(os.time() - created_at) > 120 then return nil end
    return bundle
  end

  local function captured_view(backend, pane_id)
    if type(backend.capture_switch_view) ~= "function" then return nil end
    local switch_view = backend.capture_switch_view(pane_id)
    if type(switch_view) ~= "table" then return nil end
    local bufnr = tonumber(switch_view.bufnr)
    local name = bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) or ""
    if name == "" then return nil end
    return {
      name = name,
      pane_id = tostring(switch_view.pane_id or pane_id),
      pane_config = vim.deepcopy(switch_view.pane_config or {}),
    }
  end

  local function thread_snapshot(session_key, session)
    if not session or not session.pane_id or session.pane_id == "" then return nil end
    if not acp_logic.is_acp_backend(session.backend) then return nil end

    local provider_id = identity.provider_id(session_key, session)
    local _, backend = backend_logic.resolve_backend_for_agent(provider_id, nil)
    if not backend then return nil end
    local runtime = type(backend.get_runtime_snapshot) == "function"
      and backend.get_runtime_snapshot(session.pane_id)
      or nil
    local thread_id = identity.thread_id(session_key, session)
      or (runtime and runtime.acp_thread_id)
    if not thread_id or thread_id == "" then return nil end

    local thread = type(backend.get_thread) == "function"
      and backend.get_thread(thread_id, { include_live = true })
      or nil
    local has_user_prompt = runtime and runtime.acp_has_user_prompt == true
      or (thread and type(thread.metadata) == "table" and thread.metadata.has_user_prompt == true)

    local scratch = capture_scratch(session_key)
    return {
      thread_id = thread_id,
      provider_id = provider_id,
      process_id = tonumber(runtime and runtime.acp_process_id) or tonumber(thread and thread.process_id),
      has_user_prompt = has_user_prompt == true,
      cwd = session.cwd or (runtime and (runtime.root_dir or runtime.cwd)) or vim.fn.getcwd(),
      visible = session.hidden ~= true,
      scratch = scratch and {
        was_open = scratch.was_open == true,
        text = scratch.text or "",
      } or nil,
      view = captured_view(backend, session.pane_id),
    }
  end

  function module.capture(reason)
    reason = reason or vim.v.exitreason
    if reason ~= "restart" then return false end

    local entries = {}
    local names = vim.tbl_keys(state.sessions or {})
    table.sort(names)
    for _, session_key in ipairs(names) do
      local entry = thread_snapshot(session_key, state.sessions[session_key])
      if entry then entries[#entries + 1] = entry end
    end

    if #entries == 0 then
      pcall(vim.fn.delete, bundle_path())
      return false
    end

    local path = bundle_path()
    local saved = write_bundle(path, {
      version = BUNDLE_VERSION,
      kind = "lazyagent-acp-native-restart",
      created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      created_at_unix = os.time(),
      sessions = entries,
    })
    if not saved then
      vim.notify("LazyAgent ACP: failed to save native :restart state", vim.log.levels.ERROR)
      return false
    end
    return true
  end

  local function restored_view(view)
    if type(view) ~= "table" or type(view.name) ~= "string" or view.name == "" then return nil end
    local restored_bufnr = nil
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) == view.name then
        restored_bufnr = bufnr
        break
      end
    end
    if not restored_bufnr then return nil end
    if #vim.fn.win_findbuf(restored_bufnr) == 0 then
      pcall(vim.api.nvim_buf_delete, restored_bufnr, { force = true })
      return nil
    end
    return {
      bufnr = restored_bufnr,
      pane_id = view.pane_id,
      pane_config = vim.deepcopy(view.pane_config or {}),
      preserve_existing_transcript = false,
    }
  end

  local function restore_entries(entries, index)
    index = index or 1
    local entry = entries[index]
    if not entry then return end

    local scratch = type(entry.scratch) == "table" and entry.scratch or {}
    local reuse_view = restored_view(entry.view)
    local advanced = false
    local function advance()
      if advanced then return end
      advanced = true
      vim.schedule(function() restore_entries(entries, index + 1) end)
    end
    local restore_opts = {
      focus_agent_view = entry.visible == true,
      stay_hidden = entry.visible ~= true and scratch.was_open ~= true,
      open_input = scratch.was_open == true,
      initial_input = scratch.text or "",
      reuse_view = reuse_view,
      restart_process_id = tonumber(entry.process_id),
      on_ready = advance,
    }
    local _, backend = backend_logic.resolve_backend_for_agent(entry.provider_id, nil)
    local function existing_thread()
      if not backend or type(backend.get_thread) ~= "function" then return nil end
      local ok, thread = pcall(backend.get_thread, entry.thread_id, { include_live = true })
      return ok and thread or nil
    end
    local function start_fresh()
      local ok, started = pcall(start_session, {
        agent_name = entry.provider_id,
        cwd = entry.cwd,
        root_dir = entry.cwd,
        reuse = false,
        focus_agent_view = restore_opts.focus_agent_view,
        stay_hidden = restore_opts.stay_hidden,
        open_input = restore_opts.open_input,
        initial_input = restore_opts.initial_input,
        acp_reuse_view = reuse_view,
        on_ready = advance,
      })
      if not ok or started == false then advance() end
    end
    local function reopen()
      if entry.has_user_prompt ~= true and existing_thread() == nil then
        start_fresh()
        return
      end
      local ok, err = open_thread(entry.thread_id, restore_opts)
      if ok then return end
      if err == "owner_changed" then
        vim.notify(
          "LazyAgent ACP: native restart ownership changed before restore",
          vim.log.levels.WARN
        )
      end
      advance()
    end
    reopen()
  end

  function module.restore(reason)
    reason = reason or vim.v.startreason
    if reason ~= "restart" or restore_started then return false end
    local path = bundle_path()
    if not valid_bundle_path(path) then return false end

    restore_started = true
    local bundle = read_bundle(path)
    pcall(vim.fn.delete, path)
    if not bundle or type(bundle.sessions) ~= "table" or #bundle.sessions == 0 then
      return false
    end
    restore_entries(bundle.sessions)
    return true
  end

  function module.schedule_restore(reason)
    reason = reason or vim.v.startreason
    if reason ~= "restart" or vim.fn.filereadable(bundle_path()) ~= 1 then return false end

    local group = vim.api.nvim_create_augroup("LazyAgentNativeRestart", { clear = true })
    vim.api.nvim_create_autocmd("SessionLoadPost", {
      group = group,
      once = true,
      callback = function() vim.schedule(function() module.restore(reason) end) end,
      desc = "Restore ACP threads after native Neovim restart",
    })
    vim.defer_fn(function() module.restore(reason) end, 500)
    return true
  end

  module.bundle_path = bundle_path
  return module
end

return M

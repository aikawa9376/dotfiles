local M = {}

local THREAD_A = "123e4567-e89b-42d3-a456-426614174000"
local THREAD_B = "123e4567-e89b-42d3-a456-426614174001"
local THREAD_C = "123e4567-e89b-42d3-a456-426614174002"

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local source_bufnr = vim.api.nvim_get_current_buf()
  local previous_workspace_root = vim.b[source_bufnr].lazyagent_workspace_root
  vim.b[source_bufnr].lazyagent_workspace_root = "/tmp/lazyagent-buffer-root"
  local pane_seq = 0
  local splits = {}
  local acp_split_opts = {}
  local legacy_splits = {}
  local hidden_panes = {}
  local joined_panes = {}
  local backend = {
    split = function(_, _, _, opts)
      pane_seq = pane_seq + 1
      local pane_id = "mock-pane-" .. tostring(pane_seq)
      if opts.acp then
        splits[#splits + 1] = vim.deepcopy(opts.acp)
        acp_split_opts[#acp_split_opts + 1] = vim.deepcopy(opts)
      else
        legacy_splits[#legacy_splits + 1] = vim.deepcopy(opts)
      end
      opts.on_split(pane_id)
    end,
    configure_pane = function()
      return true
    end,
    pane_exists = function()
      return true
    end,
    break_pane = function(pane_id)
      hidden_panes[#hidden_panes + 1] = pane_id
      return true
    end,
    join_pane = function(pane_id, _, _, callback)
      joined_panes[#joined_panes + 1] = pane_id
      callback(true)
      return true
    end,
  }
  local state = { sessions = {}, opts = { hooks = { reload_mode = "hook" } }, editor_instance_id = "test-editor" }
  local acp_defaults = {
    footer_animation = true,
    protocol_log = true,
    show_context_notes = true,
    show_session_summary = true,
    show_thread_title = true,
    fancy_mode = false,
    smooth_scroll = {},
    release_buffer_on_hide = true,
    transcript_compaction = {},
    runtime_compaction = {},
    additional_directories = {},
    mcp_servers = { { name = "fixture", command = "/bin/fixture", args = {}, env = {} } },
    permission_rules = {},
    auto_switch = {},
  }
  local ready = {}
  local mcp_start_count = 0
  local prepare_count, root_lookups = 0, 0
  local launch_executable = "fake-acp"
  local launch = require("lazyagent.logic.session.launch").setup({
    state = state,
    acp_logic = {
      is_acp_backend = function(name)
        return name == "buffer_acp"
      end,
      resolve = function()
        return vim.deepcopy(acp_defaults)
      end,
    },
    agent_logic = {
      get_interactive_agent = function() return {} end,
      resolve_launch_spec = function()
        return { command = { launch_executable } }
      end,
    },
    backend_logic = {
      resolve_backend_for_agent = function(name)
        if name == "Legacy" then
          return "tmux", backend
        end
        return "buffer_acp", backend
      end,
    },
    keymaps_logic = { register_scratch_keymaps = function() end },
    send_logic = {},
    skills_logic = {
      prepare = function(provider)
        prepare_count = prepare_count + 1
        if provider == "Copilot" then
          return { append_args = { "--plugin-dir", "/tmp/fixture-skills" }, env = { SKILLS_FIXTURE = "prepared" } }
        end
        return {}
      end,
      apply_command = function(command, args)
        return vim.list_extend(vim.deepcopy(command), args)
      end,
    },
    window = require("lazyagent.window"),
    persistence = {
      get_session = function()
        return nil
      end,
    },
    util = {
      project_root_for_buf = function(bufnr)
        root_lookups = root_lookups + 1
        if bufnr == source_bufnr then return "/tmp/lazyagent-project-root" end
        return nil
      end,
      git_root_for_path = function(path)
        if tostring(path):match("lazyagent%-non%-git") then return nil end
        return vim.fn.getcwd()
      end,
      fire_event = function() end,
    },
    call_watch = function() end,
    maybe_disable_watchers = function() end,
    current_editor_session_name = function()
      return nil
    end,
    mark_session_scope = function() end,
    mcp_integration = {
      ensure_started = function(opts)
        mcp_start_count = mcp_start_count + 1
        opts._mcp_url = "http://127.0.0.1:12345/mcp"
        opts._mcp_type = "http"
      end,
    },
  })
  for index, thread_id in ipairs({ THREAD_A, THREAD_B }) do
    launch.ensure_session("Codex", {
      acp_thread_id = thread_id,
      source_bufnr = source_bufnr,
      root_dir = index == 1 and "/tmp/lazyagent-explicit-root" or nil,
    }, false, function(pane_id, session_key)
      ready[session_key] = pane_id
    end)
  end
  assert(vim.wait(1000, function()
    return vim.tbl_count(ready) == 2
  end, 10), "parallel thread launches should become ready")

  local key_a = "Codex::" .. THREAD_A
  local key_b = "Codex::" .. THREAD_B
  assert_equal(ready[key_a], "mock-pane-1", "first thread pane")
  assert_equal(ready[key_b], "mock-pane-2", "second thread pane")
  assert(state.sessions[key_a] ~= state.sessions[key_b], "thread runtime sessions must be distinct")
  assert_equal(state.sessions[key_a].provider_id, "Codex", "first provider metadata")
  assert_equal(state.sessions[key_b].provider_id, "Codex", "second provider metadata")
  assert_equal(splits[1].agent_name, key_a, "first backend runtime key")
  assert_equal(splits[2].agent_name, key_b, "second backend runtime key")
  assert_equal(splits[1].provider_id, "Codex", "first backend provider")
  assert_equal(splits[1].cwd, "/tmp/lazyagent-explicit-root", "explicit thread workspace wins over source root")
  assert_equal(splits[2].cwd, "/tmp/lazyagent-project-root", "Neovim project root wins over buffer fallback")
  assert_equal(splits[1].editor.owner_pid, vim.fn.getpid(), "Neovim owner is forwarded")
  assert_equal(splits[1].editor.instance_id, "test-editor", "Neovim instance identity is forwarded")
  assert_equal(splits[1].show_context_notes, true, "context note option forwarded to ACP backend")
  assert_equal(state.sessions[key_a].show_context_notes, true, "context note option stored on runtime session")
  assert_equal(splits[1].protocol_log, true, "protocol log option forwarded to ACP backend")
  assert_equal(state.sessions[key_a].protocol_log, true, "protocol log option stored on runtime session")
  assert_equal(splits[1].show_session_summary, true, "session summary option forwarded to ACP backend")
  assert_equal(state.sessions[key_a].show_session_summary, true, "session summary option stored on runtime session")
  assert_equal(splits[1].show_thread_title, true, "thread title option forwarded to ACP backend")
  assert_equal(state.sessions[key_a].show_thread_title, true, "thread title option stored on runtime session")
  assert_equal(splits[2].provider_id, "Codex", "second backend provider")
  assert_equal(splits[1].mcp_servers[1].name, "fixture", "MCP servers forwarded to ACP backend")
  assert_equal(splits[1].env.LAZYAGENT_SESSION_KEY, key_a, "ACP child receives its LazyAgent session key")
  assert_equal(state.session_aliases.Codex, key_b, "legacy provider command alias")

  local reused_key
  local before_reuse_prepare, before_reuse_root = prepare_count, root_lookups
  launch.ensure_session(key_a, {
    source_bufnr = vim.api.nvim_get_current_buf(),
  }, true, function(pane_id, session_key)
    assert_equal(pane_id, "mock-pane-1", "runtime-key command pane")
    reused_key = session_key
  end)
  assert_equal(reused_key, key_a, "runtime-key command reuse")
  assert_equal(#splits, 2, "runtime-key command must not launch a duplicate")
  assert_equal(prepare_count, before_reuse_prepare, "reusing a running pane does not rebuild skills")
  assert_equal(root_lookups, before_reuse_root, "reusing a running pane does not look up project roots")
  assert_equal(mcp_start_count, 0, "ACP session launch must not start legacy MCP server")

  local hidden_key
  local non_git_dir = vim.fn.tempname() .. "-lazyagent-non-git"
  vim.fn.mkdir(non_git_dir, "p")
  local non_git_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(non_git_bufnr, non_git_dir .. "/notes.md")
  launch.ensure_session("Codex", {
    acp_thread_id = THREAD_C,
    source_bufnr = non_git_bufnr,
    stay_hidden = true,
  }, false, function(_, session_key)
    hidden_key = session_key
  end)
  assert(vim.wait(1000, function()
    return hidden_key ~= nil
  end, 10), "hidden ACP session should become ready")
  assert_equal(acp_split_opts[3].hidden, true, "hidden ACP session requests a headless buffer view")
  assert_equal(#hidden_panes, 0, "headless ACP session never creates a view that must be closed")
  assert_equal(state.sessions[hidden_key].hidden, true, "hidden ACP runtime remains marked hidden")
  assert_equal(splits[3].cwd, non_git_dir, "non-Git source directory wins over Neovim cwd")
  local revealed_key
  before_reuse_prepare, before_reuse_root = prepare_count, root_lookups
  launch.ensure_session(hidden_key, {
    source_bufnr = non_git_bufnr,
    stay_hidden = false,
  }, true, function(_, session_key)
    revealed_key = session_key
  end)
  assert(vim.wait(1000, function()
    return revealed_key ~= nil
  end, 10), "explicitly visible reuse should reveal a hidden ACP session")
  assert_equal(joined_panes[1], state.sessions[hidden_key].pane_id, "hidden ACP session rejoins a window")
  assert_equal(state.sessions[hidden_key].hidden, false, "revealed ACP session is no longer hidden")
  assert_equal(state.sessions[hidden_key].mode, nil, "revealed ACP session leaves instant mode")
  assert_equal(prepare_count, before_reuse_prepare, "revealing a hidden pane does not rebuild skills")
  assert_equal(root_lookups, before_reuse_root, "revealing a hidden pane does not look up project roots")
  vim.api.nvim_buf_delete(non_git_bufnr, { force = true })
  vim.fn.delete(non_git_dir, "rf")

  state.opts.mcp_mode = true
  local legacy_ready = false
  launch.ensure_session("Legacy", { acp = false }, false, function()
    legacy_ready = true
  end)
  assert(vim.wait(1000, function()
    return legacy_ready
  end, 10), "legacy session launch should become ready")
  vim.b[source_bufnr].lazyagent_workspace_root = previous_workspace_root
  assert_equal(mcp_start_count, 1, "non-ACP session launch starts MCP server lazily")
  assert_equal(legacy_splits[1].env.LAZYAGENT_MCP_URL, state.opts._mcp_url, "legacy session receives MCP URL")
  assert_equal(legacy_splits[1].env.LAZYAGENT_SESSION_KEY, "Legacy", "legacy child receives its LazyAgent session key")

  local flag_ready
  launch.ensure_session("Copilot", {}, false, function(pane) flag_ready = pane end)
  assert(vim.wait(1000, function() return flag_ready ~= nil end, 10))
  local flag_session = state.sessions.Copilot
  assert(vim.deep_equal(splits[#splits].command, { "fake-acp", "--plugin-dir", "/tmp/fixture-skills" }), "launch retains skill arguments")
  assert_equal(splits[#splits].env.SKILLS_FIXTURE, "prepared", "launch retains skill environment")
  before_reuse_prepare = prepare_count
  launch.ensure_session("Copilot", {}, true, function(pane)
    assert_equal(pane, flag_ready, "flag-provider scratch reuses its pane")
  end)
  assert_equal(prepare_count, before_reuse_prepare, "flag-provider reopen does not prepare skills")

  -- Pre-change runtime snapshots have only the command with appended flags.
  flag_session.launch_base_cmd = nil
  launch.ensure_session("Copilot", {}, true, function(pane)
    assert_equal(pane, flag_ready, "older runtime with skill flags is reused")
  end)
  assert_equal(prepare_count, before_reuse_prepare + 1, "older runtime prepares compatibility signature once")
  launch.ensure_session("Copilot", {}, true, function() end)
  assert_equal(prepare_count, before_reuse_prepare + 1, "compatibility upgrade avoids later skill preparation")

  launch_executable = "changed-acp"
  local changed_ready
  launch.ensure_session("Copilot", {}, true, function(pane) changed_ready = pane end)
  assert(vim.wait(1000, function() return changed_ready ~= nil end, 10))
  assert(changed_ready ~= flag_ready, "a changed base command still launches a new pane")
  assert(vim.deep_equal(splits[#splits].command, { "changed-acp", "--plugin-dir", "/tmp/fixture-skills" }), "changed launch still includes skills")

  local snapshot = { acp_thread_id = THREAD_A, acp_thread_unread = false, acp_thread_draft = "saved draft" }
  local marked_read = 0
  backend.get_runtime_snapshot = function() return vim.deepcopy(snapshot) end
  backend.mark_thread_read = function()
    marked_read = marked_read + 1
    snapshot.acp_thread_unread = false
  end
  local input_buf
  launch.start_interactive_session({ agent_name = "Copilot", reuse = true,
    on_ready = function(_, _, buf) input_buf = buf end })
  assert(vim.wait(500, function()
    return input_buf and vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)[1] == "saved draft"
  end, 10), "saved draft is restored without a read-state write")
  assert_equal(marked_read, 0, "opening an already-read scratch skips read-state persistence")
  local window = require("lazyagent.window")
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "user edited draft" })
  window.close({ keep_buffer = true })
  snapshot.acp_thread_unread = true
  launch.start_interactive_session({ agent_name = "Copilot", reuse = true })
  assert_equal(marked_read, 1, "opening an unread thread still persists its read state")
  assert_equal(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)[1], "user edited draft", "reopen preserves edited input")
  window.close({ keep_buffer = true })
  vim.api.nvim_buf_delete(input_buf, { force = true })
end

return M

local M = {}

local THREAD_A = "123e4567-e89b-42d3-a456-426614174000"
local THREAD_B = "123e4567-e89b-42d3-a456-426614174001"

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local pane_seq = 0
  local splits = {}
  local backend = {
    split = function(_, _, _, opts)
      pane_seq = pane_seq + 1
      local pane_id = "mock-pane-" .. tostring(pane_seq)
      splits[#splits + 1] = vim.deepcopy(opts.acp)
      opts.on_split(pane_id)
    end,
    configure_pane = function()
      return true
    end,
    pane_exists = function()
      return true
    end,
  }
  local state = { sessions = {}, opts = { hooks = { reload_mode = "hook" } }, editor_instance_id = "test-editor" }
  local acp_defaults = {
    footer_animation = true,
    protocol_log = true,
    show_context_notes = true,
    show_session_summary = true,
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
      resolve_launch_spec = function()
        return { command = { "fake-acp" } }
      end,
    },
    backend_logic = {
      resolve_backend_for_agent = function()
        return "buffer_acp", backend
      end,
    },
    keymaps_logic = {},
    send_logic = {},
    skills_logic = {
      prepare = function()
        return {}
      end,
    },
    window = {},
    persistence = {},
    util = {
      git_root_for_path = function()
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
  })

  local ready = {}
  for index, thread_id in ipairs({ THREAD_A, THREAD_B }) do
    launch.ensure_session("Codex", {
      acp_thread_id = thread_id,
      source_bufnr = vim.api.nvim_get_current_buf(),
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
  assert_equal(splits[1].editor.owner_pid, vim.fn.getpid(), "Neovim owner is forwarded")
  assert_equal(splits[1].editor.instance_id, "test-editor", "Neovim instance identity is forwarded")
  assert_equal(splits[1].show_context_notes, true, "context note option forwarded to ACP backend")
  assert_equal(state.sessions[key_a].show_context_notes, true, "context note option stored on runtime session")
  assert_equal(splits[1].protocol_log, true, "protocol log option forwarded to ACP backend")
  assert_equal(state.sessions[key_a].protocol_log, true, "protocol log option stored on runtime session")
  assert_equal(splits[1].show_session_summary, true, "session summary option forwarded to ACP backend")
  assert_equal(state.sessions[key_a].show_session_summary, true, "session summary option stored on runtime session")
  assert_equal(splits[2].provider_id, "Codex", "second backend provider")
  assert_equal(splits[1].mcp_servers[1].name, "fixture", "MCP servers forwarded to ACP backend")
  assert_equal(state.session_aliases.Codex, key_b, "legacy provider command alias")

  local reused_key
  launch.ensure_session(key_a, {
    source_bufnr = vim.api.nvim_get_current_buf(),
  }, true, function(pane_id, session_key)
    assert_equal(pane_id, "mock-pane-1", "runtime-key command pane")
    reused_key = session_key
  end)
  assert_equal(reused_key, key_a, "runtime-key command reuse")
  assert_equal(#splits, 2, "runtime-key command must not launch a duplicate")
end

return M

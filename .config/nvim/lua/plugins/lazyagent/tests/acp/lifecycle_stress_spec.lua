local M = {}

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function plugin_root()
  local source = debug.getinfo(1, "S").source:gsub("^@", "")
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local function exercise_repeated_view_lifecycle(base)
  local view = require("lazyagent.acp.view_buffer")
  local transcript = base .. "/repeat.log"
  vim.fn.writefile({ "# System", "repeat lifecycle" }, transcript)
  for index = 1, 5 do
    local pane_id
    local pane_state
    view.create_pane({
      transcript_path = transcript,
      size = 6,
      is_vertical = index % 2 == 0,
      opts = {},
      acp = {
        agent_name = "repeat-" .. tostring(index),
        source_winid = vim.api.nvim_get_current_win(),
        source_bufnr = vim.api.nvim_get_current_buf(),
      },
    }, function(created, state)
      pane_id, pane_state = created, state
    end)
    assert(vim.wait(1000, function() return pane_id ~= nil end, 10), "repeated view create")
    view.kill_pane(pane_id, {
      pane_id = pane_id,
      transcript_path = transcript,
      view_state = pane_state,
    })
    local snapshot = view.debug_snapshot()
    assert_equal(snapshot.pane_count, 0, "repeated pane teardown")
    assert_equal(snapshot.valid_buffer_count, 0, "repeated buffer teardown")
    assert_equal(snapshot.active_timer_count, 0, "repeated timer teardown")
  end
end

local function exercise_provider_switch(base)
  local restored
  local closed = {}
  local state = {
    sessions = {
      Alpha = { pane_id = "alpha-pane", backend = "buffer_acp" },
    },
  }
  local backend = {
    is_busy = function() return false end,
    capture_pane_sync = function() return "# User\nquestion\n\n# Assistant\nanswer\n" end,
    get_runtime_snapshot = function() return { source_bufnr = 1, source_winid = 1 } end,
    restore_switch_snapshot = function(_, snapshot) restored = snapshot end,
  }
  local actions = require("lazyagent.logic.session.acp_actions").setup({
    state = state,
    acp_logic = {},
    agent_logic = {
      get_interactive_agent = function(name) return { name = name } end,
    },
    backend_logic = {
      resolve_backend_for_agent = function() return "buffer_acp", backend end,
    },
    cache_logic = { get_cache_dir = function() return base end },
    persistence = {},
    util = {},
    current_editor_session_name = function() return "test" end,
    current_context_acp_agent = function() return "Alpha" end,
    active_acp_agents = function() return { "Alpha" } end,
    preferred_session_agent = function() return "Alpha" end,
    resolve_acp_target_agent = function(_, callback) callback("Alpha") end,
    resolve_acp_switch_target_agent = function(_, target, callback) callback(target) end,
    resolve_active_acp_session = function(_, callback) callback("Alpha") end,
    capture_switch_scratch_state = function() return { was_open = false } end,
    resolve_switch_anchor = function() return { source_bufnr = 1, source_winid = 1 } end,
    normalize_keep_line_limit = function(value) return value end,
    split_conversation_checkpoint_lines = function() return {}, {} end,
    build_conversation_sidecar = function() return { conversation_timeline = {}, tool_timeline = {} } end,
    write_provider_switch_snapshot = function()
      local path = base .. "/provider-switch.log"
      vim.fn.writefile({ "snapshot" }, path)
      return path
    end,
    read_saved_conversation_lines = function() return {} end,
    select_saved_conversation = function() end,
    persist_conversation_capture = function() end,
    force_close_session = function(name)
      closed[#closed + 1] = name
      state.sessions[name] = nil
    end,
    with_acp_session = function() end,
    ensure_session = function(name, _, _, callback)
      state.sessions[name] = { pane_id = name .. "-pane", backend = "buffer_acp" }
      callback(name .. "-pane")
    end,
    start_interactive_session = function() end,
    backend_supports_persistence = function() return false end,
  })

  actions.switch_acp_provider("Alpha", "Beta")
  assert_equal(closed, { "Alpha" }, "provider switch closes old provider")
  assert(restored and restored.provider_from == "Alpha", "provider switch source metadata")
  assert_equal(restored.transcript_lines[2], "question", "provider switch transcript carryover")
  assert(restored.transition_message:match("Alpha to Beta"), "provider switch transition")
end

local function exercise_resession()
  local started
  local broke = 0
  local joined = 0
  local state = {
    sessions = {
      Agent = { pane_id = "pane-1", backend = "buffer_acp", hidden = false, on_idle_callback = function() end },
    },
    session_views = {},
    open_agent = "Agent",
  }
  local view = { agents = {}, visible_agents = {}, open_agent = "Agent", last_agent = "Agent" }
  state.session_views["session-a"] = view
  local backend = {
    break_pane = function() broke = broke + 1 end,
    configure_pane = function() end,
    join_pane = function(_, _, _, callback) joined = joined + 1; callback(true) end,
  }
  local runtime = require("lazyagent.logic.session.runtime").setup({
    state = state,
    acp_logic = { is_acp_backend = function(name) return name == "buffer_acp" end },
    agent_logic = { get_interactive_agent = function() return {} end },
    backend_logic = { resolve_backend_for_agent = function() return "buffer_acp", backend end },
    window = { is_open = function() return false end, close = function() end },
    session_view = function(name) return state.session_views[name] end,
    session_agents_for_name = function() return { "Agent" } end,
    resolve_saved_snapshot = function(_, snapshot)
      return "buffer_acp", backend, true, { pane_id = snapshot.pane_id, backend = "buffer_acp" }
    end,
    current_editor_session_name = function() return "session-a" end,
    start_interactive_session = function(opts) started = opts.agent_name end,
  })

  local snapshot = assert(runtime.resession_snapshot())
  assert(snapshot.agents.Agent.on_idle_callback == nil, "ACP resession drops runtime callbacks")
  runtime.resession_pre_load()
  assert_equal(state.sessions.Agent, nil, "resession detaches runtime ownership")
  assert_equal(broke, 1, "resession hides visible pane")
  runtime.resession_post_load(snapshot)
  assert(vim.wait(1000, function() return started == "Agent" end, 10), "resession reopens active agent")
  assert(state.sessions.Agent and state.sessions.Agent.session_scope == "session-a", "resession restores session")
  assert_equal(joined, 1, "resession rejoins visible pane")
end

local function exercise_two_instances(base)
  local root = plugin_root()
  local fixture = root .. "/tests/acp/multi_instance_fixture.lua"
  local store_dir = base .. "/multi-instance"
  local results = {}
  local thread_ids = {
    "123e4567-e89b-42d3-a456-426614174010",
    "123e4567-e89b-42d3-a456-426614174011",
  }
  for index = 1, 2 do
    vim.system({
      vim.v.progpath, "--headless", "--clean", "-u", "NONE", "-i", "NONE", "-l", fixture,
    }, {
      env = {
        LAZYAGENT_MULTI_INSTANCE_DIR = store_dir,
        LAZYAGENT_MULTI_INSTANCE_THREAD = thread_ids[index],
        LAZYAGENT_MULTI_INSTANCE_PROVIDER = "provider-" .. tostring(index),
      },
      text = true,
    }, function(result)
      results[index] = result
    end)
  end
  assert(vim.wait(10000, function() return results[1] ~= nil and results[2] ~= nil end, 10),
    "two Neovim instances should exit")
  local exits = { results[1].code, results[2].code }
  assert_equal(exits, { 0, 0 }, "two Neovim instances mutate one manifest: "
    .. tostring(results[1].stderr or "") .. tostring(results[2].stderr or ""))
  local store = require("lazyagent.acp.thread_store").new({ dir = store_dir })
  assert_equal(#assert(store:list({ include_archived = true })), 2, "multi-instance records preserved")
  assert_equal(assert(store:get(thread_ids[1])).provider_id, "provider-1", "first instance record")
  assert_equal(assert(store:get(thread_ids[2])).provider_id, "provider-2", "second instance record")
end

function M.run()
  local base = vim.fn.tempname() .. "-lifecycle-stress"
  vim.fn.mkdir(base, "p")
  exercise_repeated_view_lifecycle(base)
  exercise_provider_switch(base)
  exercise_resession()
  exercise_two_instances(base)
  vim.fn.delete(base, "rf")
end

return M

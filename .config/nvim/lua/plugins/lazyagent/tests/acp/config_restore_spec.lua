local M = {}

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function setup_config()
  local blocks = {}
  local helpers = require("lazyagent.acp.backend.config").setup({
    state = { opts = {} },
    acp_logic = {},
    agent_logic = {},
    skills_logic = {},
    local_commands = {},
    transforms = {},
    normalize_text = function(value) return tostring(value or "") end,
    append_block = function(_, kind, text)
      blocks[#blocks + 1] = { kind = kind, text = text }
    end,
    sync_runtime_session = function() end,
    sync_thread = function() end,
    first_nonempty = function(...)
      for index = 1, select("#", ...) do
        local value = select(index, ...)
        if value ~= nil and value ~= "" then return value end
      end
      return nil
    end,
    item_body_text = function() return "" end,
    matches_exact = function() return true end,
    matches_pattern = function() return true end,
  })
  return helpers, blocks
end

local function choice_option(id, current, values, category)
  local options = {}
  for _, value in ipairs(values) do
    options[#options + 1] = { name = value, value = value }
  end
  return {
    id = id,
    name = id,
    category = category or id,
    type = "select",
    currentValue = current,
    options = options,
  }
end

local function attach_client(session, calls)
  session.client = {
    set_config_option = function(_, id, value, callback)
      calls[#calls + 1] = { id = id, value = value }
      for _, option in ipairs(session.config_options) do
        if option.id == id then option.currentValue = value end
      end
      callback(vim.deepcopy(session.config_options), nil)
    end,
  }
end

local function assert_no_unavailable_warning(blocks, message)
  for _, block in ipairs(blocks) do
    if tostring(block.text):find("not available", 1, true) then
      error(message .. ": " .. tostring(block.text))
    end
  end
end

function M.run()
  local config_values = require("lazyagent.acp.config_values")
  assert_equal(
    config_values.preferred({ { id = "model", currentValue = "gpt-5.6-sol" } }, { "model" }, "gpt-5.6-sol[medium]"),
    "gpt-5.6-sol",
    "modern model config wins over combined legacy catalog"
  )

  local helpers, blocks = setup_config()
  local calls = {}
  local session = {
    ready = true,
    config_options = {
      choice_option("model", "gpt-5.6-sol", { "gpt-5.6-sol", "gpt-5.6-terra" }, "model"),
      choice_option("reasoning_effort", "medium", { "low", "medium", "high" }, "thought_level"),
      { id = "fast-mode", name = "Fast mode", type = "boolean", currentValue = false },
    },
    initial_config_snapshot = {
      { id = "model", category = "model", currentValue = "gpt-5.6-sol" },
      { id = "reasoning_effort", category = "thought_level", currentValue = "medium" },
      { id = "fast-mode", currentValue = false },
    },
    initial_model = "gpt-5.6-sol[medium]",
  }
  attach_client(session, calls)
  helpers.apply_initial_session_config(session)
  assert_equal(calls, {}, "matching saved config does not send duplicate model, reasoning, or false boolean updates")
  assert_equal(blocks, {}, "matching saved config does not emit unavailable-value warnings")

  helpers, blocks = setup_config()
  calls = {}
  session = {
    ready = true,
    config_options = {
      choice_option("model", "gpt-5.6-terra", { "gpt-5.6-sol", "gpt-5.6-terra" }, "model"),
      choice_option("reasoning_effort", "high", { "low", "medium", "high" }, "thought_level"),
    },
    initial_config_snapshot = {},
    initial_model = "gpt-5.6-sol[medium]",
  }
  attach_client(session, calls)
  helpers.apply_initial_session_config(session)
  assert_equal(calls, {
    { id = "reasoning_effort", value = "medium" },
    { id = "model", value = "gpt-5.6-sol" },
  }, "combined historical model is restored as separate model and reasoning options")
  assert_no_unavailable_warning(blocks, "compatible combined historical model is migrated without warnings")

  helpers, blocks = setup_config()
  calls = {}
  session = {
    ready = true,
    config_options = {
      choice_option("model", "gpt-5.6-luna", { "gpt-5.6-sol", "gpt-5.6-luna" }, "model"),
      choice_option("reasoning_effort", "medium", { "low", "medium", "high", "max" }, "thought_level"),
    },
    initial_config_snapshot = {},
    initial_model = "gpt-5.6-sol",
    initial_effort = "max",
  }
  attach_client(session, calls)
  helpers.apply_initial_session_config(session)
  assert_equal(calls, {
    { id = "model", value = "gpt-5.6-sol" },
    { id = "reasoning_effort", value = "max" },
  }, "explicit initial model and reasoning effort use separate ACP config options")
  assert_no_unavailable_warning(blocks, "supported explicit reasoning effort applies without warnings")

  helpers = setup_config()
  calls = {}
  session = {
    ready = true,
    config_options = {
      choice_option("model", "legacy[low]", { "legacy[low]", "legacy[medium]" }, "model"),
    },
    initial_config_snapshot = {},
    initial_model = "legacy[medium]",
  }
  attach_client(session, calls)
  helpers.apply_initial_session_config(session)
  assert_equal(calls, { { id = "model", value = "legacy[medium]" } }, "legacy combined model identifiers remain supported")

  helpers, blocks = setup_config()
  calls = {}
  session = {
    ready = true,
    config_options = {
      choice_option("mode", "agent-full-access", { "read-only", "agent", "agent-full-access" }, "mode"),
      choice_option("collaboration_mode", "default", { "default", "plan" }, "collaboration_mode"),
    },
  }
  attach_client(session, calls)
  local toggled_modes = {}
  helpers.toggle_plan_mode_for_session(session, function(updated, mode)
    assert(updated, "Codex collaboration mode toggle succeeds")
    toggled_modes[#toggled_modes + 1] = mode
  end)
  helpers.toggle_plan_mode_for_session(session, function(updated, mode)
    assert(updated, "Codex collaboration mode restore succeeds")
    toggled_modes[#toggled_modes + 1] = mode
  end)
  assert_equal(calls, {
    { id = "collaboration_mode", value = "plan" },
    { id = "collaboration_mode", value = "default" },
  }, "Plan toggle changes collaboration mode without touching permission mode")
  assert_equal(toggled_modes, { "plan", "agent" }, "Plan toggle reports both resulting modes")

  helpers = setup_config()
  calls = {}
  session = {
    ready = true,
    config_options = {
      choice_option("mode", "build", { "plan", "build" }, "mode"),
    },
  }
  attach_client(session, calls)
  helpers.toggle_plan_mode_for_session(session)
  helpers.toggle_plan_mode_for_session(session)
  assert_equal(calls, {
    { id = "mode", value = "plan" },
    { id = "mode", value = "build" },
  }, "providers with a combined mode option toggle and restore their agent choice")

  helpers, blocks = setup_config()
  calls = {}
  session = {
    ready = true,
    config_options = {
      choice_option("mode", "agent", { "read-only", "agent", "agent-full-access" }, "mode"),
    },
  }
  attach_client(session, calls)
  local unsupported
  helpers.toggle_plan_mode_for_session(session, function(updated, _, err)
    unsupported = { updated = updated, err = err }
  end)
  assert_equal(calls, {}, "permission-only mode is never changed by Plan toggle")
  assert_equal(unsupported.updated, false, "unsupported provider reports no update")
  assert(tostring(unsupported.err):find("does not expose", 1, true), "unsupported provider explains missing Plan mode")
end

return M

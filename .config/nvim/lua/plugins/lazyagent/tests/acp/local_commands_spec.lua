local M = {}

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local commands = require("lazyagent.acp.local_commands")
  local side, args = commands.parse("/side explain this change")
  assert_equal(side.name, "side", "local side command")
  assert_equal(args, "explain this change", "local side question")

  local entries = commands.entries({})
  assert(vim.tbl_contains(vim.tbl_map(function(item) return item.name end, entries), "side"), "side is locally available")

  local merged = commands.merged_entries({}, {
    { name = "side", label = "/side", desc = "provider-native side" },
  })
  local side_entries = vim.tbl_filter(function(item) return item.label == "/side" end, merged)
  assert_equal(#side_entries, 1, "provider side command suppresses local duplicate")
  assert_equal(side_entries[1].desc, "provider-native side", "provider side command has precedence")

  local actions = require("lazyagent.acp.backend.actions").setup({
    state = { opts = {} },
    local_commands = commands,
    append_block = function() end,
    session_has_available_command = function(session, name)
      return session.native_side == true and name == "side"
    end,
  })
  local action, question = actions.handle_local_slash_command({}, "/side inspect the tests")
  assert_equal(action, "side", "local side action")
  assert_equal(question, "inspect the tests", "local side action question")
  assert_equal(actions.handle_local_slash_command({ native_side = true }, "/side inspect"), false,
    "advertised provider side bypasses local action")
end

return M

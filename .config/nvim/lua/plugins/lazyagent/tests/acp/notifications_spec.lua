local M = {}

local function assert_equal(expected, actual, label)
  if not vim.deep_equal(expected, actual) then
    error(string.format("%s: expected %s, got %s", label, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

function M.run()
  local Notifications = require("lazyagent.acp.notifications")
  local notices = {}
  local sounds = {}
  local deps = {
    notify = function(message, level, opts) notices[#notices + 1] = { message, level, opts.title } end,
    jobstart = function(command, opts) sounds[#sounds + 1] = { command, opts } end,
  }

  assert_equal(true, Notifications.emit({ sound_command = { "play", "done.wav" } }, "permission", {
    agent_name = "Fixture",
    message = "write file",
  }, deps), "notification emitted")
  assert_equal("Fixture: write file", notices[1][1], "visual notification message")
  assert_equal("Permission required", notices[1][3], "visual notification title")
  assert_equal({ "play", "done.wav" }, sounds[1][1], "sound notification command")

  assert_equal(false, Notifications.emit({}, "completion", {}, deps), "completion disabled by default")
  assert_equal(1, #notices, "disabled visual notification count")
  assert_equal(true, Notifications.emit({ completion = true }, "completion", {
    agent_name = "Fixture",
    message = "done",
  }, deps), "completion can be enabled")
  assert_equal("Turn completed", notices[2][3], "completion notification title")
  assert_equal(false, Notifications.emit({ enabled = false }, "elicitation", {}, deps), "all notifications disabled")
end

return M

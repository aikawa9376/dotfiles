return {
  "lazyagent",
  dir = os.getenv("XDG_CONFIG_HOME") .. "/nvim/lua/plugins/lazyagent",
  -- Use lazy.nvim key mappings to load plugin when keys are used
  keys = {
    { "<leader>sa", function() require("lazyagent").send_visual() end, mode = "v", desc = "Send Visual to Agent" },
    { "<leader>sl", function() require("lazyagent").send_line() end, mode = "n", desc = "Send Line to Agent" },
    { "c<space><space>", function() require("lazyagent").toggle_session() end, mode = { "n", "x" }, desc = "Toggle Gemini Agent" },
  },
  -- Also load the plugin when these user commands are executed
  cmd = {
    "SendAgentScratch",
    "SendAgentToggle",
    "SendAgentHistory",
    "SendAgentHistoryList",
    "SendAgentClose",
    "Claude",
    "Codex",
    "Gemini",
    "Copilot",
    "Cursor",
  },
  opts = {}
}

return {
  "send-agent",
  dir = os.getenv("XDG_CONFIG_HOME") .. "/nvim/lua/plugins/send-agent",
  -- Use lazy.nvim key mappings to load plugin when keys are used
  keys = {
    { "<leader>sa", function() require("send-agent").send_visual() end, mode = "v", desc = "Send Visual to Agent" },
    { "<leader>sl", function() require("send-agent").send_line() end, mode = "n", desc = "Send Line to Agent" },
    { "c<space><space>", function() require("send-agent").toggle_session() end, mode = { "n", "x" }, desc = "Toggle Gemini Agent" },
    { "<leader>sar", function() require("send-agent").start_interactive_session({ agent_name = "Cursor", reuse = true }) end, mode = "n", desc = "Start Cursor Agent" },
    { "<leader>sac", function() require("send-agent").start_interactive_session({ agent_name = "Copilot", reuse = true }) end, mode = "n", desc = "Start Copilot Agent" },
    { "<leader>sag", function() require("send-agent").start_interactive_session({ agent_name = "Gemini", reuse = true }) end, mode = "n", desc = "Start Gemini Agent" },
  },
  -- Also load the plugin when these user commands are executed
  cmd = {
    "SendAgentScratch",
    "SendAgentToggle",
    "SendAgentHistory",
    "SendAgentClose",
    "Claude",
    "Codex",
    "Gemini",
    "Copilot",
    "Cursor",
  },
  config = true,
}

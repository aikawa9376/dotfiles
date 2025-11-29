return {
  "lazyagent",
  dir = os.getenv("XDG_CONFIG_HOME") .. "/nvim/lua/plugins/lazyagent",
  -- Use lazy.nvim key mappings to load plugin when keys are used
  keys = {
    {
      "c<space><space>",
      function() require("lazyagent").toggle_session() end,
      mode = { "n", "x" },
      desc = "Toggle AI Agent",
    },
  },
  -- Also load the plugin when these user commands are executed
  cmd = {
    "LazyAgentScratch", "LazyAgentToggle", "LazyAgentHistory",
    "LazyAgentHistoryList", "LazyAgentClose", "LazyAgentOpenConversation",
    "Claude", "Codex", "Gemini", "Copilot", "Cursor",
  },
  opts = {
    scratch_keymaps = {
      close = "q",
      send_and_clear = "<C-Space>",
      scroll_up = "<C-u>",
      scroll_down = "<C-d>",
      nav_up = "<C-k>",
      nav_down = "<C-j>",
      esc = "<C-c>",
      clear = "c<space>d",
    },
    interactive_agents = {
      Gemini = { yolo = true },
      Copilot = { yolo = true },
    }
  }
}

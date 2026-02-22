return {
  "lazyagent",
  dir = os.getenv("XDG_CONFIG_HOME") .. "/nvim/lua/plugins/lazyagent",
  -- Use lazy.nvim key mappings to load plugin when keys are used
  keys = (function()
    local keys = {
      {
        "c<space><space>",
        function() require("lazyagent").toggle_session() end,
        mode = { "n", "x" },
        desc = "Toggle AI Agent",
      },
      {
        "c<space>i",
        function() require("lazyagent").open_instant() end,
        mode = { "n", "x" },
        desc = "Instant AI Agent",
      },
      {
        "c<space><cr>",
        function() require("lazyagent").send_enter() end,
        mode = { "n", "x" },
        desc = "Send Enter to Agent",
      },
      {
        "c<space>n",
        function() require("lazyagent").send_down() end,
        mode = { "n", "x" },
        desc = "Send Down to Agent",
      },
      {
        "c<space>p",
        function() require("lazyagent").send_up() end,
        mode = { "n", "x" },
        desc = "Send Up to Agent",
      },
    }
    for i = 0, 9 do
      table.insert(keys, {
        "c<space>" .. i,
        function() require("lazyagent").send_key(tostring(i)) end,
        mode = { "n", "x" },
        desc = "Send " .. i .. " to Agent",
      })
    end
    table.insert(keys, {
      "c<space><C-c>",
      function() require("lazyagent").send_interrupt() end,
      mode = { "n", "x" },
      desc = "Send Ctrl-C to Agent",
    })
    table.insert(keys, {
      "c<space>d",
      function() require("lazyagent").clear_input() end,
      mode = { "n", "x" },
      desc = "Clear Agent Input",
    })
    return keys
  end)(),
  -- Also load the plugin when these user commands are executed
  cmd = {
    "LazyAgentScratch", "LazyAgentToggle", "LazyAgentHistory",
    "LazyAgentHistoryList", "LazyAgentClose", "LazyAgentOpenConversation",
    "LazyAgentResumeConversation", "LazyAgentSummary", "LazyAgentRestore",
    "LazyAgentDetach", "LazyAgentInstant", "LazyAgentAttach",
    "Claude", "Codex", "Gemini", "Copilot", "Cursor",
  },
  opts = {
    backend = "tmux",
    resume = false,
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
      Copilot = { yolo = true, default = true },
    },
    instant_mode = {
      append_text = " #cursor #small-fix #diffstyle-code", -- e.g. " #translate"
    },

  }
}

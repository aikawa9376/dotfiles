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
    table.insert(keys, {
      "c<space>l",
      function() vim.cmd("LazyAgentOpenConversation") end,
      mode = { "n", "x" },
      desc = "Open Agent Conversation",
    })
    return keys
  end)(),
  -- Also load the plugin when these user commands are executed
  cmd = {
    "LazyAgentScratch", "LazyAgentToggle", "LazyAgentHistory",
    "LazyAgentHistoryList", "LazyAgentConversationList", "LazyAgentClose",
    "LazyAgentOpenConversation", "LazyAgentResumeConversation", "LazyAgentSummary",
    "LazyAgentRestore", "LazyAgentDetach", "LazyAgentInstant", "LazyAgentAttach",
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
    -- auto_follow: automatically open/focus files edited by the AI agent.
    -- "split" = dedicated split window (default), "jump" = replace current window.
    --
    -- NOTE: inotifywait (Linux) を強く推奨します。インストールすると find ポーリングの代わりに
    --       イベント駆動で動作し、CPU 負荷がほぼゼロになります。
    --   Arch:   sudo pacman -S inotify-tools
    --   Ubuntu: sudo apt install inotify-tools
    --   macOS:  brew install fswatch  (fswatch を使用)
    auto_follow = "split",
  }
}

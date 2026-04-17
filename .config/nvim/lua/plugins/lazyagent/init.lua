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
    "LazyAgent", "LazyAgentScratch", "LazyAgentToggle", "LazyAgentHistory",
    "LazyAgentHistoryList", "LazyAgentConversationList", "LazyAgentClose",
    "LazyAgentOpenConversation", "LazyAgentResumeConversation", "LazyAgentSummary",
    "LazyAgentRestore", "LazyAgentDetach", "LazyAgentInstant", "LazyAgentAttach",
    "LazyAgentACPConfig", "LazyAgentACPModel", "LazyAgentACPMode",
    "Claude", "Codex", "Gemini", "Copilot", "Cursor",
  },
  opts = {
    backend = "tmux",
    acp = {
      enabled = true,
      view = "buffer",
      -- default_mode = "bypassPermissions", -- prefer provider mode when available
      auto_permission = "allow_always",
    },
    resume = false,
    scratch_keymaps = {
      close = "q",
      send_and_clear = "<C-Space>",
      scroll_up = "<C-u>",
      scroll_down = "<C-d>",
      nav_up = "<C-k>",
      nav_down = "<C-j>",
      esc = "<C-c>",
      adjust_line = "<C-l>",
      clear = "c<space>d",
    },
    interactive_agents = {
      Gemini = { yolo = true, mcp_context_dir_flag = "--include-directories" },
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
    -- auto_follow = "split",
    -- MCP server for non-ACP / legacy agent integrations.
    -- ACP mode itself no longer depends on this path; if all configured agents use ACP,
    -- lazyagent skips starting the MCP server even when this stays true.
    mcp_mode = true,
    -- mcp_host: set to "0.0.0.0" to expose the MCP server (and web UI) to the local network.
    -- Access the web UI at http://<your-ip>:<port>/ from any device on the same network.
    -- Default is "127.0.0.1" (localhost only).
    mcp_host = "0.0.0.0",
    hooks = {
      open_on_edit = false,
      quickfix_on_edit = true,
      git_checkpoint_on_done = false,
      notify_on_done = true,
    }
  }
}

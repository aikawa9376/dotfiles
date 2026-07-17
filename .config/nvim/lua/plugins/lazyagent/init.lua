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
        "c<space>e",
        function() require("lazyagent").edit_selection() end,
        mode = { "n", "x" },
        desc = "Edit Selected Block",
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
    "LazyAgentOpenConversation", "LazyAgentConversation", "LazyAgentResumeConversation", "LazyAgentSummary",
    "LazyAgentRestore", "LazyAgentDetach", "LazyAgentInstant", "LazyAgentAttach", "LazyAgentEdit",
    "LazyAgentRestart", "LazyAgentStack", "LazyAgentHooks", "LazyAgentQR", "LazyAgentACPCockpit",
    "LazyAgentACPMobileStart",
    "LazyAgentACPMobileStop", "LazyAgentACPMobileQR", "LazyAgentACPRawTranscript", "LazyAgentACPFullTranscript",
    "LazyAgentACPRestart", "LazyAgentACPRestoreRestartState",
    "LazyAgentScreenShot",
    "Claude", "Codex", "Gemini", "Copilot", "Cursor",
  },
  init = function() end,
  opts = {
    backend = "tmux",
    acp = {
      enabled = true,
      view = "buffer",
      footer_animation = true,
      brain_save = {
        enabled = true,
      },
      -- buffer_background = "#002b36",
      -- buffer_inactive_background = "#073642",
      -- default_mode = "bypassPermissions", -- prefer provider mode when available
      auto_permission = "allow_always",
      buffer_background = "none",
      buffer_inactive_background = "none",
      fancy_mode = false,
      table_layout = "card",
      smooth_scroll = {
        enabled = true,
        duration_ms = 140,
        step_ms = 10,
        max_delta = 80,
        manual = true,
        follow = true,
      },
    },
    resume = false,
    image_paste = {
      enabled = true,
      dir = vim.fn.stdpath("cache") .. "/lazyagent/conversation",
      dir_layout = "conversation",
      max_dimension = 1600,
      drop = {
        enabled = true,
        copy = true,
      },
      preview = {
        max_width = 80,
        max_height = 20,
      },
    },
    scratch_keymaps = {
      close = "q",
      send_and_clear = "<C-Space>",
      scroll_up = "<C-u>",
      scroll_down = "<C-d>",
      nav_up = "<C-k>",
      nav_down = "<C-j>",
      interrupt = "<C-c>",
      esc = "<Esc>",
      adjust_line = "<C-l>",
      clear = "c<space>d",
    },
    interactive_agents = {
      Gemini = { yolo = true, mcp_context_dir_flag = "--include-directories" },
      Copilot = { yolo = true },
      Codex = { yolo = true, default = true, acp_cmd = { "npx", "@agentclientprotocol/codex-acp" } },
    },
    instant_mode = {
      append_text = " #cursor #small-fix #diffstyle-code", -- e.g. " #translate"
    },
    skills = {
      enabled = true,
      mode = "auto",
      -- bin_dir = "/path/to/bin", -- default: lazyagent/bin
      -- mount_dir = "~/.agents/skills", -- fallback only; Gemini uses hidden cache runtime by default
      agents = {
        Copilot = {
          mode = "flag",
          flag = "--plugin-dir",
        },
        Gemini = {
          mode = "mount",
        },
      },
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
      reload_mode = "hook",
      open_on_edit = false,
      quickfix_on_edit = true,
      git_checkpoint_on_done = false,
      notify_on_done = true,
    },
    edit_blocks = {
      transport = "api",
      command = { "copilot", "--model", "gpt-5-mini", "--effort", "low", "-p" },
      api = {
        provider = "copilot",
        model = "gpt-5-mini",
      },
    },
  }
}

local M = {}

function M.build()
  local base_agent = {
    pane_size = "60",
    scratch_filetype = "lazyagent",
    is_vertical = true,
    yolo = false,
    yolo_flag = nil,
    acp = nil,
    default = false,
  }

  return {
    filetype_settings = {
      ["*"] = { agent = "Gemini" },
    },
    prompts = {
      default_agent = function(context)
        vim.notify("Agent received: " .. (context and context.text or ""))
      end,
    },
    interactive_agents = {
      Claude = vim.tbl_deep_extend("force", base_agent, {
        cmd = "claude",
        yolo_flag = "--dangerously-skip-permissions",
      }),
      Codex = vim.tbl_deep_extend("force", base_agent, {
        cmd = "codex",
        yolo_flag = "--full-auto",
      }),
      Gemini = vim.tbl_deep_extend("force", base_agent, {
        cmd = "gemini",
        acp_cmd = { "gemini", "--acp" },
        acp_cmd_fallbacks = { { "gemini", "--experimental-acp" } },
        yolo_flag = "--yolo",
      }),
      Copilot = vim.tbl_deep_extend("force", base_agent, {
        cmd = "copilot",
        acp_cmd = { "copilot", "--acp" },
        yolo_flag = "--yolo --allow-all-tools",
        -- Copilot's Bubble Tea TUI can pause input after focus-out.
        refocus_on_send = true,
      }),
      Cursor = vim.tbl_deep_extend("force", base_agent, {
        cmd = "cursor-agent",
        acp_cmd = { "cursor-agent", "acp" },
        acp_cmd_fallbacks = {
          { "agent", "acp" },
          { "cursor-agent", "--acp" },
        },
        yolo_flag = "--yolo",
      }),
    },
    start_in_insert_on_focus = false,
    window_type = "float",
    backend = "tmux",
    acp = {
      enabled = false,
      view = "tmux",
      auto_permission = nil,
      default_mode = nil,
      initial_model = nil,
      footer_animation = true,
      table_layout = "table",
      buffer_background = nil,
      buffer_inactive_background = nil,
      transcript_compaction = {
        enabled = true,
        min_sections = 48,
        keep_recent_sections = 24,
        summary_items = 6,
      },
      permission_rules = {},
      hide_pending_messages = true,
      auto_switch = {
        enabled = false,
        preserve_manual = true,
        mode_rules = {},
        model_rules = {},
      },
      brain_save = {
        enabled = false,
        command = nil,
      },
    },
    tmux_auto_exit_copy_mode = true,
    submit_delay = 600,
    submit_retry = 1,
    debug = false,
    close_on_send = true,
    save_conversation_on_close = true,
    open_conversation_on_save = false,
    scratch_keymaps = {
      close = "q",
      interrupt = "<C-c>",
      send_and_clear = "<C-Space>",
      send_key_insert = "<C-s>",
      send_key_normal = "<CR>",
      scroll_up = "<C-u>",
      scroll_down = "<C-d>",
      nav_up = "<Up>",
      nav_down = "<Down>",
      esc = "<Esc>",
      clear = "c<space>d",
      history_next = "c<space>n",
      history_prev = "c<space>p",
    },
    cache = {
      enabled = true,
      dir = vim.fn.stdpath("cache") .. "/lazyagent",
      debounce_ms = 1500,
      persistence_debounce_ms = 150,
      max_history = 100,
      conversation_retention = "30d",
    },
    skills = {
      enabled = false,
      mode = "auto",
      bin_dir = nil,
      bin_env = "LAZYAGENTBIN",
      mount_dir = "~/.agents/skills",
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
    send_mode = "append",
    use_bracketed_paste = true,
    send_number_keys_to_agent = true,
    resume = false,
    mcp_mode = true,
    mcp_initial_send = false,
    initial_send_delay = 3000,
    interrupt_attempts = 3,
    interrupt_interval_ms = 40,
    post_interrupt_wait_ms = 2000,
    hooks = {
      reload_mode = "hook",
      open_on_edit = false,
      quickfix_on_edit = true,
      notify_on_done = true,
      git_checkpoint_on_done = false,
      diagnostic_on_done = false,
    },
    instant_mode = {
      append_text = nil,
    },
    edit_blocks = {
      agent = "Copilot",
      transport = "command",
      command = nil,
      command_mode = "arg",
      timeout_ms = 90000,
      context_lines = 80,
      max_context_chars = 24000,
      preview = true,
      auto_apply = false,
      preserve_indent = true,
      max_inline_diff_lines = 120,
      api = {
        provider = nil,
        model = "gpt-4o-2024-11-20",
        endpoint = nil,
        proxy = nil,
        allow_insecure = false,
        use_response_api = nil,
        extra_headers = {},
        extra_body = {
          max_tokens = 20480,
        },
        copilot = {
          token_refresh_skew_seconds = 120,
        },
      },
      keymaps = {
        accept = "ct",
        accept_all = "ca",
        reject = "co",
        reject_alt = "cq",
        reject_none = "c0",
        next = "]]",
        prev = "[[",
      },
      candidates = {
        { name = "copilot", cmd = { "copilot", "-p" }, mode = "arg" },
        { name = "claude", cmd = { "claude", "-p" }, mode = "arg" },
        { name = "gemini", cmd = { "gemini", "-p" }, mode = "arg" },
      },
    },
  }
end

return M

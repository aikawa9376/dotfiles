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
        acp_cmd = { "codex-acp" },
        yolo_flag = "--dangerously-bypass-approvals-and-sandbox",
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
      fancy_mode = false,
      table_layout = "table",
      smooth_scroll = false,
      transcript_max_lines = 12000,
      release_buffer_on_hide = true,
      buffer_background = nil,
      buffer_inactive_background = nil,
      transcript_compaction = {
        enabled = false,
        min_sections = 48,
        keep_recent_sections = 24,
        summary_items = 6,
      },
      runtime_compaction = {
        enabled = true,
        keep_recent_items = 80,
        keep_recent_tools = 40,
        body_limit = 12000,
        tool_output_limit = 24000,
      },
      permission_rules = {},
      -- Debounce markdown rendering so streaming output doesn't repeatedly re-render.
      render_markdown_debounce_ms = 900,
      hide_pending_messages = true,
      auto_switch = {
        enabled = false,
        preserve_manual = true,
        mode_rules = {},
        model_rules = {},
      },
      brain_save = {
        enabled = true,
        command = nil,
      },
      mobile = {
        host = nil,
        port = nil,
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
    image_paste = {
      enabled = true,
      dir = vim.fn.stdpath("cache") .. "/lazyagent/conversation",
      dir_layout = "conversation",
      max_dimension = 1600,
      notify = true,
      drop = {
        enabled = true,
        copy = true,
      },
      preview = {
        enabled = true,
        max_width = 80,
        max_height = 20,
        auto_resize = true,
        acp_max_previews = 6,
        acp_prefetch_lines = 40,
        acp_refresh_debounce_ms = 80,
      },
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

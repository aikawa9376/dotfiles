-- lazyagent.lua - Main entry point for the LazyAgent plugin.
-- This file orchestrates the various modules that comprise the plugin's functionality.

local M = require("lazyagent.logic.state")

local cache_logic = require("lazyagent.logic.cache")
local commands_logic = require("lazyagent.logic.commands")
local agent_logic = require("lazyagent.logic.agent")
local session_logic = require("lazyagent.logic.session")
local send_logic = require("lazyagent.logic.send")
local backend_logic = require("lazyagent.logic.backend")
local status_logic = require("lazyagent.logic.status")

-- Expose public API from logic modules through the main M table
M.open_history = cache_logic.open_history
M.get_active_agents = agent_logic.get_active_agents
M.send_to_cli = send_logic.send_to_cli
M.close_session = session_logic.close_session
M.close_all_sessions = session_logic.close_all_sessions
M.toggle_session = session_logic.toggle_session
M.send_visual = send_logic.send_visual
M.send_line = send_logic.send_line
M.status = status_logic.get_status

--- Sets up the LazyAgent plugin with user-defined options.
-- @param opts (table|nil) User options to merge with defaults.
function M.setup(opts)
  local default_opts = {
    filetype_settings = {
      ["*"] = { agent = "Gemini" },
    },
    prompts = {
      default_agent = function(context)
        vim.notify("Agent received: " .. (context and context.text or ""))
      end,
    },
    interactive_agents = (function()
      local base = {
        pane_size = "60", -- Default to fixed 60 cells width
        scratch_filetype = "lazyagent",
        -- Edit here to override agent-specific settings
        -- submit_keys = { "C-m" },
        -- submit_delay = 600,
        -- submit_retry = 1,
        is_vertical = true,
        yolo = false,
        yolo_flag = nil,
        default = false,
      }
      return {
        Claude = vim.tbl_deep_extend("force", base, {
          cmd = "claude",
          yolo_flag = "--dangerously-skip-permissions",
        }),
        Codex = vim.tbl_deep_extend("force", base, {
          cmd = "codex",
          yolo_flag = "--full-auto",
        }),
        Gemini = vim.tbl_deep_extend("force", base, {
          cmd = "gemini",
          yolo_flag = "--yolo",
        }),
        Copilot = vim.tbl_deep_extend("force", base, {
          cmd = "copilot",
          yolo_flag = "--allow-all-tools",
        }),
        Cursor = vim.tbl_deep_extend("force", base, {
          cmd = "cursor-agent",
          yolo_flag = "--no-confirm",
        }),
      }
    end)(),
    start_in_insert_on_focus = false,
    window_type = "float",
    backend = "tmux",
    tmux_auto_exit_copy_mode = true,
    submit_delay = 600,
    submit_retry = 1,
    debug = false,
    close_on_send = true,
    save_conversation_on_close = true,
    open_conversation_on_save = false,
    scratch_keymaps = {
      close = "q",
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
      max_history = 100,
    },
    -- How new content is merged into existing agent input:
    -- - "append": move cursor to end of agent's input and append content before submitting.
    -- - "replace": wipe existing input and paste-the-new content.
    send_mode = "append",
    -- If true, wrap pasted blocks with the terminal "bracketed paste" control chars
    -- to preserve pasted content as one operation in supported terminals.
    use_bracketed_paste = true,
    send_number_keys_to_agent = true,
    resume = false,
  }

  M.opts = vim.tbl_deep_extend("force", default_opts, opts or {})

  -- Register any backend modules passed through setup opts (backends[name]={module} OR backends[name]="lua.module.path")
  if M.opts.backends and type(M.opts.backends) == "table" then
    for name, mod in pairs(M.opts.backends) do
      if type(mod) == "string" then
        local ok, loaded = pcall(require, mod)
        if ok and loaded then backend_logic.register_backend(name, loaded) end
      elseif type(mod) == "table" then
        backend_logic.register_backend(name, mod)
      end
    end
  end

  pcall(function()
    if vim and vim.treesitter and vim.treesitter.language and vim.treesitter.language.register then
      pcall(function() vim.treesitter.language.register("markdown", { "lazyagent" }) end)
    end
  end)

  if M._configured then
    return
  end
  M._configured = true

  -- Register user commands
  commands_logic.setup_commands()

  -- Close all agent sessions on Quit/Exit
  pcall(function()
    local group = vim.api.nvim_create_augroup("LazyAgentCleanup", { clear = true })
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = group,
      callback = function()
        session_logic.close_all_sessions(true)
      end,
      desc = "Close lazyagent tmux sessions on exit",
    })
  end)
end

return M

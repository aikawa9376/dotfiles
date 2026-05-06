-- Main entry point for lazyagent.nvim.
--
-- Keep this file as a thin composition root. Feature behavior lives in
-- lazyagent.logic.*, command registration in lazyagent.commands.*, and external
-- integrations in lazyagent.integrations.*.

local M = require("lazyagent.logic.state")

local agent_logic = require("lazyagent.logic.agent")
local backend_logic = require("lazyagent.logic.backend")
local cache_logic = require("lazyagent.logic.cache")
local commands_logic = require("lazyagent.commands")
local default_config = require("lazyagent.config.defaults")
local edit_blocks = require("lazyagent.logic.edit_blocks")
local mcp_integration = require("lazyagent.integrations.mcp")
local send_logic = require("lazyagent.logic.send")
local session_logic = require("lazyagent.logic.session")
local status_logic = require("lazyagent.logic.status")
local util = require("lazyagent.util")

-- Public API facade ---------------------------------------------------------

M.open_history = cache_logic.open_history
M.get_active_agents = agent_logic.get_active_agents
M.send_to_cli = send_logic.send_to_cli
M.close_session = session_logic.close_session
M.close_all_sessions = session_logic.close_all_sessions
M.toggle_session = session_logic.toggle_session
M.open_instant = session_logic.open_instant
M.attach_session = session_logic.attach_session
M.switch_acp_provider = function(target_agent, agent_name)
  return session_logic.switch_acp_provider(agent_name, target_agent)
end
M.resume_acp_conversation = function(agent_name)
  return session_logic.resume_acp_conversation(agent_name)
end
M.pick_acp_sessions = session_logic.pick_acp_sessions
M.pick_acp_config = session_logic.pick_acp_config
M.pick_acp_model = session_logic.pick_acp_model
M.pick_acp_mode = session_logic.pick_acp_mode
M.reopen_acp_window = session_logic.reopen_acp_window
M.open_raw_acp_transcript = session_logic.open_raw_acp_transcript
M.open_full_acp_transcript = session_logic.open_full_acp_transcript
M.pick_acp_commands = session_logic.pick_acp_commands
M.show_acp_tool_timeline = session_logic.show_acp_tool_timeline
M.pick_acp_resources = session_logic.pick_acp_resources
M.show_acp_capabilities = session_logic.show_acp_capabilities
M.save_conversation_checkpoint = session_logic.save_conversation_checkpoint
M.on_session_save_pre = session_logic.on_session_save_pre
M.on_session_load_pre = session_logic.on_session_load_pre
M.on_session_load_post = session_logic.on_session_load_post
M.resession_snapshot = session_logic.resession_snapshot
M.resession_pre_load = session_logic.resession_pre_load
M.resession_post_load = session_logic.resession_post_load
M.send_visual = send_logic.send_visual
M.send_line = send_logic.send_line
M.status = status_logic.get_status
M.send_enter = send_logic.send_enter
M.send_down = send_logic.send_down
M.send_up = send_logic.send_up
M.send_key = send_logic.send_key
M.send_interrupt = send_logic.send_interrupt
M.send_raw_keys = send_logic.send_raw_keys
M.clear_input = send_logic.clear_input
M.edit_selection = edit_blocks.edit_selection
M.edit_selected_blocks = edit_blocks.edit_selection
M.fire_event = util.fire_event

local function export_nvim_listen_address()
  pcall(function()
    local ok, servername = pcall(function() return vim.v.servername end)
    if ok and servername and servername ~= "" then
      vim.env.NVIM_LISTEN_ADDRESS = servername
      pcall(function() vim.fn.setenv("NVIM_LISTEN_ADDRESS", servername) end)
    end
  end)
end

local function register_custom_backends(opts)
  if type(opts.backends) ~= "table" then
    return
  end

  for name, mod in pairs(opts.backends) do
    if type(mod) == "string" then
      local ok, loaded = pcall(require, mod)
      if ok and loaded then
        backend_logic.register_backend(name, loaded)
      end
    elseif type(mod) == "table" then
      backend_logic.register_backend(name, mod)
    end
  end
end

local function register_treesitter_filetypes()
  pcall(function()
    if vim and vim.treesitter and vim.treesitter.language and vim.treesitter.language.register then
      pcall(function()
        vim.treesitter.language.register("markdown", { "lazyagent", "lazyagent_acp" })
      end)
    end
  end)
end

local function register_cleanup_autocmd()
  pcall(function()
    local group = vim.api.nvim_create_augroup("LazyAgentCleanup", { clear = true })
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = group,
      callback = function()
        session_logic.close_all_sessions(true)
      end,
      desc = "Close lazyagent sessions on exit",
    })
  end)
end

--- Sets up the LazyAgent plugin with user-defined options.
---@param opts table|nil User options to merge with defaults.
function M.setup(opts)
  M.opts = vim.tbl_deep_extend("force", default_config.build(), opts or {})

  export_nvim_listen_address()
  register_custom_backends(M.opts)
  register_treesitter_filetypes()

  if M._configured then
    return
  end
  M._configured = true

  commands_logic.setup_commands()
  register_cleanup_autocmd()
  mcp_integration.setup(M.opts)
end

return M

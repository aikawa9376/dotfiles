local M = {}

function M.run()
  local Agentmux = require("lazyagent.integrations.agentmux")
  local state = require("lazyagent.logic.state")
  local identity = Agentmux.identity_for("Codex", {
    agent_status = "waiting",
    agent_status_message = "Permission",
    acp_transcript_path = "/tmp/thread.md",
  }, "%7")
  assert(identity.pane_id == "%7", "agentmux pane identity")
  assert(identity.kind == "codex", "agentmux kind")
  assert(identity.name == "Codex (ACP)", "agentmux display name")
  assert(identity.state == "blocked", "agentmux normalized state")
  assert(identity.message == "Permission", "agentmux status message")
  assert(identity.preview_path == "/tmp/thread.md", "agentmux preview identity")

  local previous_opts = state.opts
  local previous_sessions = state.sessions
  local previous_create_augroup = vim.api.nvim_create_augroup
  local previous_create_autocmd = vim.api.nvim_create_autocmd
  local previous_schedule = vim.schedule
  local autocmds = 0
  local scheduled = 0
  vim.api.nvim_create_augroup = function() return 1 end
  vim.api.nvim_create_autocmd = function()
    autocmds = autocmds + 1
    return autocmds
  end
  vim.schedule = function()
    scheduled = scheduled + 1
  end
  state.sessions = {}
  state.opts = { agentmux = { enabled = false } }
  assert(Agentmux.setup() == false, "disabled agentmux setup")
  assert(autocmds == 0, "disabled agentmux registers no autocmds")
  assert(Agentmux.sync() == false, "disabled agentmux sync")

  state.opts.agentmux.enabled = true
  assert(Agentmux.setup() == true, "enabled agentmux setup")
  assert(autocmds == 2, "enabled agentmux lifecycle autocmds")
  assert(scheduled == 0, "agentmux setup does not sync on plugin load")

  vim.api.nvim_create_augroup = previous_create_augroup
  vim.api.nvim_create_autocmd = previous_create_autocmd
  vim.schedule = previous_schedule
  state.opts = previous_opts
  state.sessions = previous_sessions
end

return M

local M = {}

function M.run()
  local state = require("lazyagent.logic.state")
  local previous_opts = state.opts
  local previous_instance_id = state.editor_instance_id
  local cache_dir = vim.fn.tempname() .. "-editor-registry"
  local workspace = vim.fn.tempname() .. "-workspace"
  vim.fn.mkdir(workspace, "p")
  state.opts = vim.tbl_deep_extend("force", vim.deepcopy(previous_opts or {}), { cache = { dir = cache_dir } })
  state.editor_instance_id = "editor-registry-test"

  local bufnr = vim.api.nvim_create_buf(true, true)
  vim.b[bufnr].lazyagent_workspace_root = workspace
  local registry = require("lazyagent.acp.editor_registry")
  local setup, setup_err = registry.setup()
  assert(setup, "editor registry setup: " .. tostring(setup_err))
  local targets = registry.targets(workspace)
  assert(#targets == 1, "open workspace Neovim target")
  assert(targets[1].instance_id == "editor-registry-test", "current Neovim target identity")
  assert(type(targets[1].server) == "string" and targets[1].server ~= "", "target RPC server")

  local accepted, err = registry.request_create_agent(targets[1], "missing-provider", workspace)
  assert(accepted == false and tostring(err):find("not configured", 1, true), "remote action validates provider")
  local unsupported = registry.dispatch({ action = "arbitrary_command", token = targets[1].token })
  assert(unsupported.ok == false, "editor registry only accepts create_agent")

  registry.stop()
  vim.api.nvim_buf_delete(bufnr, { force = true })
  state.opts = previous_opts
  state.editor_instance_id = previous_instance_id
  vim.fn.delete(cache_dir, "rf")
  vim.fn.delete(workspace, "rf")
end

return M

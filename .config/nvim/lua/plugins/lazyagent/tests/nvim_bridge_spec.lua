local M = {}
function M.run()
  local adapter = require("lazyagent.nvim_bridge")
  local bridge = require("nvim_cli.bridge")
  -- Earlier launch suites may already have started the singleton receiver.
  bridge.stop()
  local root = vim.fn.tempname() .. "-bridge-spec"
  local saved_connector = package.loaded["lazyagent.connector_bridge"]
  local saved_agent = package.loaded["lazyagent.agent_bridge"]
  package.loaded["lazyagent.connector_bridge"] = { run = function(args) return { result = args } end }
  package.loaded["lazyagent.agent_bridge"] = { run = function(args, req)
    return { result = { args = args, sender = req.sender_session_key } }
  end }
  local ok, err = xpcall(function()
    adapter.ensure_started({ root = root, registry_dir = root .. "/registry" })
    local env = adapter.inject_env({ EXISTING = "keep" })
    assert(env.EXISTING == "keep")
    assert(env.NVIM_CLI_BRIDGE_DIR == env.LAZYAGENT_NVIM_BRIDGE_DIR)
    assert(env.NVIM_CLI_BRIDGE_TOKEN == env.LAZYAGENT_NVIM_BRIDGE_TOKEN)
    assert(env.NVIM_CLI_REGISTRY_DIR == root .. "/registry")
    assert(adapter.dispatch({ command = "context" }).result.buffers)
    assert(adapter.dispatch({ command = "connector", args = { sql = "select 1" } }).result.sql == "select 1")
    local reply = adapter.dispatch({ command = "lazyagent-agent", args = { subcommand = "list" }, sender_session_key = "fixture" })
    assert(reply.result.sender == "fixture")
    package.loaded["lazyagent.nvim_bridge"] = nil
    assert(require("lazyagent.nvim_bridge").dispatch == bridge.dispatch, "adapter reload is idempotent")
    local records = vim.fn.globpath(root .. "/registry", "*.json", false, true)
    assert(#records == 1, "one instance record")
    adapter.stop()
    assert(vim.fn.filereadable(records[1]) == 0, "stop removes discovery record")
  end, debug.traceback)
  bridge.stop()
  package.loaded["lazyagent.connector_bridge"] = saved_connector
  package.loaded["lazyagent.agent_bridge"] = saved_agent
  vim.fn.delete(root, "rf")
  assert(ok, err)
end
return M

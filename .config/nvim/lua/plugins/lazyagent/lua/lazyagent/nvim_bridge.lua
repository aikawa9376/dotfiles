-- Transport and generic editor commands are owned by nvim-cli.
local bridge = require("nvim_cli.bridge")

-- Keep registration idempotent when this adapter is reloaded.
if not bridge.lazyagent_handlers_registered then
  bridge.register("connector", function(req)
    return require("lazyagent.connector_bridge").run(req.args or {})
  end)
  bridge.register("lazyagent-agent", function(req)
    return require("lazyagent.agent_bridge").run(req.args or {}, req)
  end)
  bridge.lazyagent_handlers_registered = true
end

local M = {}
M.ensure_started = bridge.ensure_started
M.stop = bridge.stop
M.dispatch = bridge.dispatch
function M.inject_env(env)
  env = bridge.inject_env(env)
  -- Preserve old sessions/tools while native nvim-cli uses the new names.
  env.LAZYAGENT_NVIM_BRIDGE_DIR = env.NVIM_CLI_BRIDGE_DIR
  env.LAZYAGENT_NVIM_BRIDGE_TOKEN = env.NVIM_CLI_BRIDGE_TOKEN
  return env
end
return M

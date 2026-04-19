local M = {}

local function with_lazyagent(callback)
  local ok_agent, agent = pcall(require, "lazyagent")
  if ok_agent and agent then
    return callback(agent)
  end
  return nil
end

function M.on_save(_opts)
  return with_lazyagent(function(agent)
    if type(agent.resession_snapshot) == "function" then
      return agent.resession_snapshot()
    end
    return nil
  end)
end

function M.on_post_load(data)
  with_lazyagent(function(agent)
    if type(agent.resession_post_load) == "function" then
      agent.resession_post_load(data)
    end
  end)
end

return M

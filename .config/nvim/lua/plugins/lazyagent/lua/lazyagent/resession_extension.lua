local M = {}
local load_generation = 0

local function with_lazyagent(callback)
  local ok_agent, agent = pcall(require, "lazyagent")
  if ok_agent and agent then
    return callback(agent)
  end
  return nil
end

function M.on_save(_opts)
  local snapshot = with_lazyagent(function(agent)
    if type(agent.resession_snapshot) == "function" then
      return agent.resession_snapshot()
    end
    return nil
  end) or {}
  snapshot.notes = require("lazyagent.notes").snapshot()
  return snapshot
end

function M.on_pre_load(_data)
  load_generation = load_generation + 1
  require("lazyagent.notes")._reset()
end

function M.on_post_load(data)
  load_generation = load_generation + 1
  local generation = load_generation
  -- Resession still replaces temporary buffers after its extension callbacks.
  vim.schedule(function()
    if generation == load_generation then
      require("lazyagent.notes").restore(type(data) == "table" and data.notes or nil)
    end
  end)
  with_lazyagent(function(agent)
    if type(agent.resession_post_load) == "function" then
      agent.resession_post_load(data)
    end
  end)
end

return M

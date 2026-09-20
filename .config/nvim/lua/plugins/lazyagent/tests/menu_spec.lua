local M = {}

function M.run()
  local menu = require("lazyagent.logic.menu")
  local state = require("lazyagent.logic.state")
  local agent = require("lazyagent.logic.agent")
  local acp = require("lazyagent.logic.session.acp")
  local session_logic = require("lazyagent.logic.session")
  local saved = { sessions = state.sessions, opts = state.opts, select = vim.ui.select,
    commands = vim.api.nvim_get_commands, cmd = vim.api.nvim_cmd,
    team = agent.team_lead_session, scoped = acp.preferred_session_agent,
    notify = vim.notify, rename = session_logic.rename_acp_session,
    buffer_agent = vim.b.lazyagent_agent, buffer_acp = vim.b.lazyagent_acp_agent }
  local calls, notices = {}, {}
  local function contains(items, name)
    for _, item in ipairs(items) do
      if item[1] == name then return item end
    end
  end
  local ok, err = xpcall(function()
    state.opts = { interactive_agents = {} }
    state.sessions = {
      ACP = { pane_id = "acp:1", backend = "buffer_acp" },
      CLI = { pane_id = "%1", backend = "tmux" },
    }
    agent.team_lead_session = function() return nil end
    acp.preferred_session_agent = function() return nil end
    vim.api.nvim_get_commands = function()
      return setmetatable({}, { __index = function() return {} end })
    end
    vim.api.nvim_cmd = function(cmd) calls[#calls + 1] = cmd end
    vim.notify = function(msg) notices[#notices + 1] = msg end
    vim.b.lazyagent_acp_agent = nil
    vim.b.lazyagent_agent = "CLI"
    assert(not contains(menu.items("CLI"), "LazyAgentACPModel"), "hide ACP in CLI context")
    menu.run("LazyAgentACPModel")
    assert(#calls == 0 and #notices == 1, "direct ACP key must not target another agent")

    vim.b.lazyagent_agent = "ACP"
    local items, callback
    vim.ui.select = function(values, opts, cb)
      items, callback = values, cb
      assert(opts.kind == "lazyagent-menu")
      assert(opts.format_item(values[2]):find("c<Space>m", 1, true))
    end
    menu.open()
    assert(items[1][1] == "LazyAgentToggle" and items[2][1] == "LazyAgentACPModel")
    vim.b.lazyagent_agent = "CLI"
    callback(items[2])
    assert(vim.deep_equal(calls[1], { cmd = "LazyAgentACPModel", args = { "ACP" } }), "freeze target")
    callback(nil)
    assert(#calls == 1, "cancel does nothing")
    callback(contains(items, "LazyAgentHistoryList"))
    assert(#calls[2].args == 0, "history argument is not an agent")
    session_logic.rename_acp_session = function(title, target)
      assert(title == nil and target == "ACP", "rename argument is a title, target is separate")
    end
    callback(contains(items, "LazyAgentACPRename"))

    agent.team_lead_session = function() return "ACP" end
    menu.run("LazyAgentACPFollow")
    assert(calls[3].args[1] == "ACP", "team lead takes priority")
    agent.team_lead_session = function() return nil end
    vim.b.lazyagent_agent = nil
    acp.preferred_session_agent = function() return "ACP" end
    menu.run("LazyAgentACPModel")
    assert(calls[4].args[1] == "ACP", "normal buffer uses editor session context")
    acp.preferred_session_agent = function() return nil end
    local choose
    vim.ui.select = function(values, _, cb) choose = cb; assert(#values == 2) end
    menu.run("LazyAgentACPModel")
    choose("ACP")
    assert(calls[5].args[1] == "ACP", "ambiguous normal buffer asks for target")
    vim.api.nvim_get_commands = function() return { LazyAgentToggle = {} } end
    assert(#menu.items("ACP") == 1, "unregistered ACP commands are hidden")
  end, debug.traceback)
  state.sessions, state.opts = saved.sessions, saved.opts
  vim.ui.select, vim.api.nvim_get_commands, vim.api.nvim_cmd = saved.select, saved.commands, saved.cmd
  agent.team_lead_session, acp.preferred_session_agent = saved.team, saved.scoped
  vim.notify, session_logic.rename_acp_session = saved.notify, saved.rename
  vim.b.lazyagent_agent, vim.b.lazyagent_acp_agent = saved.buffer_agent, saved.buffer_acp
  if not ok then error(err) end

  -- Exercise Neovim's actual prefix matching with the dotfiles key definitions.
  local root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
  local spec = dofile(root .. "/init.lua")
  local old_buf = vim.api.nvim_get_current_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  local old_plugin, old_open, old_run = package.loaded.lazyagent, menu.open, menu.run
  local invoked = {}
  package.loaded.lazyagent = { toggle_session = function() invoked[#invoked + 1] = "toggle" end }
  menu.open = function() invoked[#invoked + 1] = "menu" end
  menu.run = function(cmd) invoked[#invoked + 1] = cmd end
  local map_ok, map_err = xpcall(function()
    vim.api.nvim_set_current_buf(buf)
    for _, key in ipairs(spec.keys) do
      vim.keymap.set(key.mode, key[1], key[2], { buffer = buf, nowait = key.nowait or false })
    end
    for _, mode in ipairs({ "n", "x" }) do
      for _, case in ipairs({
        { "c  ", "toggle" }, { "c m", "LazyAgentACPModel" },
        { "c f", "LazyAgentACPFollow" }, { "c M", "LazyAgentACPPlanToggle" },
        { "c ", "menu" },
      }) do
        invoked = {}
        if mode == "x" then vim.cmd("normal! v") end
        vim.api.nvim_feedkeys(case[1], "xt", false)
        assert(vim.deep_equal(invoked, { case[2] }), mode .. " prefix dispatch: " .. vim.inspect(invoked))
      end
    end
  end, debug.traceback)
  package.loaded.lazyagent, menu.open, menu.run = old_plugin, old_open, old_run
  vim.api.nvim_set_current_buf(old_buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  if not map_ok then error(map_err) end
end

return M

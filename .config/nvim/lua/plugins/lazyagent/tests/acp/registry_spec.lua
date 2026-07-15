local M = {}

function M.run()
  local Registry = require("lazyagent.acp.registry")
  local registry = assert(Registry.decode(vim.json.encode({ version = "1.0.0", agents = {
    { id = "z", name = "Zulu", version = "1", distribution = { uvx = { package = "zulu==1", args = { "acp" } } } },
    { id = "a", name = "Alpha", version = "2", distribution = { npx = { package = "alpha@2", args = { "--acp" }, env = { NO_UPDATE = "1" } } } },
  } })))
  assert(registry.agents[1].id == "a", "registry agent sorting")
  local npx = assert(Registry.launcher(registry.agents[1]))
  assert(vim.deep_equal(npx.command, { "npx", "-y", "alpha@2", "--acp" }), "registry npx launcher")
  assert(npx.env.NO_UPDATE == "1", "registry launcher env")
  local uvx = assert(Registry.launcher(registry.agents[2]))
  assert(vim.deep_equal(uvx.command, { "uvx", "zulu==1", "acp" }), "registry uvx launcher")
  local binary, binary_err = Registry.launcher({ distribution = { binary = {} } })
  assert(binary == nil and binary_err:match("archive"), "binary install separation")

  local opts = { interactive_agents = { a = { acp_cmd = { "custom-alpha" } } } }
  local applied = Registry.apply_installed(opts, {
    a = { id = "a", version = "2", distribution = "npx", command = { "npx", "alpha@2" } },
    z = { id = "z", version = "1", distribution = "uvx", command = { "uvx", "zulu==1" }, env = { TOKEN = "x" } },
  })
  assert(applied == 1, "only missing managed agents restored")
  assert(opts.interactive_agents.a.acp_cmd[1] == "custom-alpha", "user agent config takes precedence")
  assert(vim.deep_equal(opts.interactive_agents.z.acp_cmd, { "uvx", "zulu==1" }), "managed agent restored")
  assert(opts.interactive_agents.z.env.TOKEN == "x", "managed agent environment restored")
end

return M

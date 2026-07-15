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

  local Binary = require("lazyagent.acp.registry_binary")
  assert(Binary.platform("Linux", "x64") == "linux-x86_64", "registry binary platform")
  assert(Binary.archive_kind("https://example.test/agent.tar.gz?download=1") == "tar.gz", "tar archive kind")
  local plan = assert(Binary.plan({ id = "agent", version = "1/2", distribution = { binary = {
    ["linux-x86_64"] = {
      archive = "https://example.test/agent.tar.gz", cmd = "./bin/agent", args = { "acp" }, sha256 = string.rep("A", 64),
    },
  } } }, "/tmp/registry", "linux-x86_64"))
  assert(plan.target == "/tmp/registry/agent/1_2/linux-x86_64", "safe binary install target")
  assert(plan.relative_cmd == "bin/agent" and plan.sha256 == string.rep("a", 64), "binary plan normalization")
  assert(Binary.validate_entries("bin/agent\nshare/readme"), "safe archive entries")
  local hash = string.rep("b", 64)
  assert(Binary.parse_checksum(hash .. "  archive.tar.gz\n") == hash, "sha256sum output parsed")
  assert(Binary.parse_checksum("SHA256 hash of archive:\n" .. hash:gsub("..", "%0 ") .. "\nCertUtil: ok") == hash,
    "certutil output parsed")
  local safe, safe_err = Binary.validate_entries("../escape")
  assert(safe == nil and safe_err:match("parent"), "archive traversal rejected")
  local escaped, escaped_err = Binary.plan({ id = "agent", version = "1", distribution = { binary = {
    ["linux-x86_64"] = { archive = "https://example.test/agent", cmd = "../agent" },
  } } }, "/tmp/registry", "linux-x86_64")
  assert(escaped == nil and escaped_err:match("escapes"), "binary command traversal rejected")
end

return M

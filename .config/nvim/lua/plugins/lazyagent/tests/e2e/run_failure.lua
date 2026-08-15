local source = vim.fn.fnamemodify(debug.getinfo(1, "S").source:gsub("^@", ""), ":p")
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
vim.opt.runtimepath:prepend(root)
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local output = assert(vim.env.LAZYAGENT_E2E_OUT, "LAZYAGENT_E2E_OUT must be explicit")
local provider = vim.env.LAZYAGENT_E2E_PROVIDER
local command
if provider == "fake" then
  command = { vim.v.progpath, "--headless", "--clean", "-u", "NONE", "-l", root .. "/tests/acp/fake_agent.lua" }
elseif vim.env.LAZYAGENT_E2E_COMMAND_JSON and vim.env.LAZYAGENT_E2E_COMMAND_JSON ~= "" then
  command = vim.json.decode(vim.env.LAZYAGENT_E2E_COMMAND_JSON)
end

local result = require("tests.e2e.failure_harness").run({
  output = output,
  provider = provider,
  scenario = vim.env.LAZYAGENT_E2E_SCENARIO,
  failure_authorized = vim.env.LAZYAGENT_E2E_FAILURE_AUTHORIZED,
  mutation_authorized = vim.env.LAZYAGENT_E2E_MUTATION_AUTHORIZED,
  timeout_ms = tonumber(vim.env.LAZYAGENT_E2E_TIMEOUT_MS),
  prompt_timeout_ms = tonumber(vim.env.LAZYAGENT_E2E_PROMPT_TIMEOUT_MS),
  command = command,
  additional_directories = provider == "fake" and { root .. "/tests" } or nil,
})
print(string.format("failure e2e %s/%s: %s", result.provider, result.scenario, result.status))

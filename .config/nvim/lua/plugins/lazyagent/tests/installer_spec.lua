local M = {}

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local installer = require("lazyagent.logic.installer")
  local install_command = require("lazyagent.commands.install")
  local root = vim.fn.tempname() .. "-lazyagent-install"
  vim.fn.mkdir(root, "p")

  local project_result = assert(installer.install({
    scope = "project",
    components = "all",
    root_dir = root,
  }))
  assert_equal(project_result.target_dir, root .. "/.lazyagent", "project install target")
  assert(vim.fn.filereadable(root .. "/.lazyagent/AGENTS.md") == 1, "project instructions installed")
  assert(vim.fn.filereadable(root .. "/.lazyagent/skills/brain/SKILL.md") == 1, "bundled skills installed")
  assert(vim.fn.filereadable(root .. "/.lazyagent/skills/obsidian/references/html-artifacts.md") == 1,
    "skill references installed recursively")

  vim.fn.writefile({ "# Custom project rules" }, root .. "/.lazyagent/AGENTS.md")
  local repeated = assert(installer.install({
    scope = "project",
    components = "all",
    root_dir = root,
  }))
  assert(#repeated.skipped > 0, "repeat install keeps existing files")
  assert_equal(vim.fn.readfile(root .. "/.lazyagent/AGENTS.md")[1], "# Custom project rules",
    "existing instructions are not overwritten")

  local global_dir = root .. "/local-share/lazyagent"
  local global_result = assert(installer.install({
    scope = "global",
    components = "skills",
    global_dir = global_dir,
  }))
  assert_equal(global_result.target_dir, global_dir, "global install target")
  assert(vim.fn.filereadable(global_dir .. "/skills/nvim-cli/SKILL.md") == 1, "global skills installed")
  assert(vim.fn.filereadable(global_dir .. "/AGENTS.md") == 0, "component selection is respected")

  local invalid, err = installer.install({ scope = "machine", root_dir = root })
  assert(invalid == nil and err:find("scope", 1, true), "invalid scope rejected")
  assert_equal(install_command._complete("g", "LazyAgentInstall g")[1], "global", "scope completion")
  assert_equal(install_command._complete("s", "LazyAgentInstall project s")[1], "skills", "component completion")
  vim.fn.delete(root, "rf")
end

return M

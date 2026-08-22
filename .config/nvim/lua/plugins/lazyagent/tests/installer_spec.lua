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
  assert(vim.fn.filereadable(root .. "/.lazyagent/skills/lazyagent-team-builder/scripts/validate.lua") == 1,
    "team builder skill resources installed")
  assert(vim.fn.filereadable(root .. "/.lazyagent/skills/obsidian/references/html-artifacts.md") == 1,
    "skill references installed recursively")
  assert(vim.fn.filereadable(root .. "/.lazyagent/skills/obsidian-memory/SKILL.md") == 1,
    "obsidian memory skill installed")
  assert(vim.fn.filereadable(root .. "/.lazyagent/skills/obsidian-memory/references/human-facing-notes.md") == 1,
    "obsidian memory conditional references installed")
  assert(vim.fn.filereadable(root .. "/.lazyagent/skills/obsidian-memory/scripts/resolve_vault.lua") == 1,
    "obsidian memory skill resources installed recursively")
  local catalog = assert(require("lazyagent.teams.config").load_all(root .. "/.lazyagent/teams.json"))
  local team = assert(require("lazyagent.teams.config").select(catalog))
  assert_equal(team.members.sol_lead.model, "gpt-5.6-sol", "team template uses Sol for the lead")
  assert_equal(team.members.sol_lead.effort, "max", "team template gives the lead max reasoning")
  assert_equal(team.members.luna_implementer.model, "gpt-5.6-luna", "team template uses Luna for members")
  assert_equal(team.members.luna_reviewer.effort, "medium", "team template gives members medium reasoning")
  assert_equal(#team.members.sol_lead.reports, 2, "team template gives the lead two direct reports")

  vim.fn.writefile({ "# Custom project rules" }, root .. "/.lazyagent/AGENTS.md")
  local repeated = assert(installer.install({
    scope = "project",
    components = "all",
    root_dir = root,
  }))
  assert(#repeated.skipped > 0, "repeat install keeps existing files")
  assert_equal(vim.fn.readfile(root .. "/.lazyagent/AGENTS.md")[1], "# Custom project rules",
    "existing instructions are not overwritten")

  vim.fn.writefile({
    "# Custom project rules",
    "",
    "## Obsidian",
    "",
    "Old memory policy.",
    "",
    "## Personal",
    "",
    "Keep this rule.",
  }, root .. "/.lazyagent/AGENTS.md")
  local profiled = assert(installer.install({
    scope = "project",
    components = "instructions",
    profile = "obsidian",
    root_dir = root,
  }))
  assert_equal(#profiled.updated, 1, "instruction profile updates an existing file")
  local profiled_text = table.concat(vim.fn.readfile(root .. "/.lazyagent/AGENTS.md"), "\n")
  assert(profiled_text:find("lazyagent:instructions:obsidian:start", 1, true), "profile has managed markers")
  assert(profiled_text:find("Use `obsidian-memory`", 1, true), "profile installs concise memory instructions")
  assert(profiled_text:find("Keep this rule", 1, true), "profile merge preserves other sections")
  assert(not profiled_text:find("Old memory policy", 1, true), "profile merge replaces its existing section")
  local profiled_again = assert(installer.install({
    scope = "project",
    components = "instructions",
    profile = "obsidian",
    root_dir = root,
  }))
  assert_equal(#profiled_again.skipped, 1, "repeated profile install is idempotent")

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
  assert_equal(install_command._complete("t", "LazyAgentInstall project t")[1], "teams", "teams completion")
  assert_equal(install_command._complete("o", "LazyAgentInstall global instructions o")[1], "obsidian",
    "instructions profile completion")
  assert_equal(install_command._complete("", "LazyAgentInstall global instructions ")[1], "obsidian",
    "instructions profile completion after a space")
  local invalid_profile, profile_err = installer.install({
    scope = "project",
    components = "skills",
    profile = "obsidian",
    root_dir = root,
  })
  assert(invalid_profile == nil and profile_err:find("instructions", 1, true), "profiles require instructions")
  local unknown_profile, unknown_err = installer.install({
    scope = "project",
    components = "instructions",
    profile = "unknown",
    root_dir = root,
  })
  assert(unknown_profile == nil and unknown_err:find("unknown", 1, true), "unknown profiles are rejected")
  vim.fn.delete(root, "rf")
end

return M

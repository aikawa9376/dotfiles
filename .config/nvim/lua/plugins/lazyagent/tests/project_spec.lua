local M = {}

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local project = require("lazyagent.logic.project")
  local root = vim.fn.tempname() .. "-lazyagent-project"
  vim.fn.mkdir(root .. "/.lazyagent/prompts", "p")
  vim.fn.mkdir(root .. "/.lazyagent/skills/reviewer", "p")
  vim.fn.mkdir(root .. "/src/nested", "p")
  vim.fn.writefile({ "# Review", "", "Review this request:", "{{input}}" }, root .. "/.lazyagent/prompts/review.md")
  vim.fn.writefile({ "# Explain", "", "Explain carefully." }, root .. "/.lazyagent/prompts/explain.md")
  vim.fn.writefile({ "# Reviewer" }, root .. "/.lazyagent/skills/reviewer/SKILL.md")
  vim.fn.writefile({ "# Project rules", "", "- Run focused tests.", "- Keep changes scoped." },
    root .. "/.lazyagent/AGENTS.md")

  local project_dir, project_root = project.find(root .. "/src/nested")
  assert_equal(project_dir, root .. "/.lazyagent", "nearest .lazyagent directory")
  assert_equal(project_root, root, "project root")
  assert_equal(project.skills_dir(root), root .. "/.lazyagent/skills", "project skills directory")
  assert_equal(#project.list_prompts(root), 2, "project prompts discovered")
  local instructions = assert(project.instructions(root .. "/src/nested"))
  assert_equal(instructions.path, root .. "/.lazyagent/AGENTS.md", "project instructions path")
  assert(instructions.content:find("Run focused tests", 1, true), "project instructions content")

  local tracker = {}
  local instructed = assert(project.apply_instructions("Fix the parser.", tracker, root))
  assert(instructed:find("# LazyAgent project instructions", 1, true), "instructions heading")
  assert(instructed:find("Keep changes scoped", 1, true), "instructions are included")
  assert(instructed:find("# User request\n\nFix the parser.", 1, true), "request follows instructions")
  assert_equal(project.apply_instructions("Follow up.", tracker, root), "Follow up.",
    "instructions are applied only once per session")
  assert(tracker.project_instructions_applied, "session tracks instruction injection")

  local role_tracker = {}
  local role_instructed = assert(project.apply_instructions(
    "Plan the change.",
    role_tracker,
    root,
    "# Team role\nYou are the lead."
  ))
  assert(role_instructed:find("# Team role", 1, true), "session instructions are included")
  assert(role_instructed:find("# LazyAgent project instructions", 1, true), "project instructions follow role")
  assert(role_instructed:find("# User request\n\nPlan the change.", 1, true), "request follows all instructions")
  assert_equal(project.apply_instructions("Follow up.", role_tracker, root, "# Team role"),
    "Follow up.", "session and project instructions are both applied once")

  local native_tracker = {}
  local native_role = assert(project.apply_instructions(
    "Delegate this.",
    native_tracker,
    root,
    "# Team role\nYou are the lead.",
    { include_project = false }
  ))
  assert(native_role:find("# Team role", 1, true), "team role remains a session instruction")
  assert(not native_role:find("# LazyAgent project instructions", 1, true),
    "native project instructions are not added to the user prompt")
  assert(native_role:find("# User request\n\nDelegate this.", 1, true), "native request remains after team role")

  local codex = assert(project.prepare_native("Codex", root, {
    command = { "codex-acp" },
    env = { CODEX_CONFIG = vim.json.encode({ model = "gpt-5", developer_instructions = "Existing." }) },
    acp = true,
  }))
  local codex_config = vim.json.decode(codex.env.CODEX_CONFIG)
  assert(codex.native, "Codex uses native instructions")
  assert_equal(codex_config.model, "gpt-5", "Codex config is preserved")
  assert(codex_config.developer_instructions:find("Existing.", 1, true), "existing Codex instructions are preserved")
  assert(codex_config.developer_instructions:find("Keep changes scoped", 1, true),
    "Codex developer instructions include the project file")

  local copilot = assert(project.prepare_native("Copilot", root, {
    command = { "copilot", "--acp" },
    env = { COPILOT_CUSTOM_INSTRUCTIONS_DIRS = "/existing" },
    acp = true,
  }))
  assert(copilot.native, "Copilot uses native instructions")
  assert_equal(copilot.env.COPILOT_CUSTOM_INSTRUCTIONS_DIRS,
    "/existing," .. root .. "/.lazyagent", "Copilot instruction directories are merged")

  local claude = assert(project.prepare_native("Claude", root, {
    command = { "claude" },
    env = {},
  }))
  assert(claude.native, "Claude uses native instructions")
  assert_equal(claude.command[#claude.command - 1], "--append-system-prompt-file", "Claude instruction flag")
  assert_equal(claude.command[#claude.command], root .. "/.lazyagent/AGENTS.md", "Claude instruction path")

  local gemini_home = root .. "/gemini-home"
  local gemini = assert(project.prepare_native("Gemini", root, {
    command = { "gemini", "--acp" },
    env = { GEMINI_CLI_HOME = gemini_home },
    acp = true,
  }))
  assert(gemini.native, "Gemini uses native instructions")
  local gemini_memory = table.concat(vim.fn.readfile(gemini_home .. "/.gemini/GEMINI.md"), "\n")
  assert(gemini_memory:find("Keep changes scoped", 1, true), "Gemini memory includes project instructions")

  local expanded, err, matched = project.expand_prompt("/prompt review check parser.lua", root)
  assert(matched and not err, err)
  assert(expanded:find("Review this request:", 1, true), "prompt body")
  assert(expanded:find("check parser.lua", 1, true), "input placeholder")
  local appended = assert(project.expand_prompt("/prompt explain use examples", root))
  assert(appended:find("# Request\nuse examples", 1, true), "request appends without placeholder")
  local missing, missing_err, missing_match = project.expand_prompt("/prompt absent request", root)
  assert(missing == nil and missing_match and missing_err:match("not found"), "missing project prompt")

  local local_commands = require("lazyagent.acp.local_commands")
  local entries = local_commands.merged_entries({ root_dir = root }, {})
  assert(vim.tbl_contains(vim.tbl_map(function(entry) return entry.label end, entries), "/prompt"),
    "project prompt completion")

  local state = require("lazyagent.logic.state")
  local previous_opts = state.opts
  state.opts = vim.tbl_deep_extend("force", vim.deepcopy(previous_opts or {}), {
    cache = { dir = root .. "/cache" },
    skills = { enabled = false },
  })
  local prepared = assert(require("lazyagent.logic.skills").prepare("Copilot", {}, { root_dir = root }))
  assert(vim.tbl_contains(prepared.source_dirs, root .. "/.lazyagent/skills"),
    "project skills activate independently of global skills")
  state.opts = previous_opts
  vim.fn.delete(root, "rf")
end

return M

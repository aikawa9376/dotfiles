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

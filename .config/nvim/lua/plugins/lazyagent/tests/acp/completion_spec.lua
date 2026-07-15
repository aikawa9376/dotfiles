local M = {}

local function assert_equal(expected, actual, label)
  if not vim.deep_equal(expected, actual) then
    error(string.format("%s: expected %s, got %s", label, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

function M.run()
  local agent = require("lazyagent.logic.agent")
  local entries = agent.normalize_completion_list({
    {
      label = "/review",
      desc = "Review a target",
      doc = "Open a review for the selected target.",
      input_hint = "<file-or-symbol>",
      input_required = true,
    },
    {
      label = "/explain",
      desc = "Explain code",
      input_placeholder = "[topic]",
    },
  })

  assert_equal(2, #entries, "completion count")
  assert_equal("Review a target · <file-or-symbol> (required)", entries[1].desc, "required hint detail")
  assert(entries[1].doc:match("Open a review"), "description documentation")
  assert(entries[1].doc:match("%*%*Arguments:%*%* `<file%-or%-symbol>` %(required%)"), "required argument documentation")
  assert_equal("<file-or-symbol>", entries[1].input_hint, "hint metadata")
  assert_equal(true, entries[1].input_required, "required metadata")
  assert_equal("Explain code · [topic] (optional)", entries[2].desc, "optional hint detail")
  assert(entries[2].doc:match("%(optional%)"), "optional argument documentation")
end

return M

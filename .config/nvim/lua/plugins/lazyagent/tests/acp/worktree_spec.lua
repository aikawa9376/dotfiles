local M = {}

function M.run()
  local Worktree = require("lazyagent.acp.worktree")
  local calls = {}
  local function run(argv)
    calls[#calls + 1] = argv
    if argv[4] == "rev-parse" then return "/repo\n" end
    return ""
  end
  local metadata = assert(Worktree.create({
    root = "/repo", path = "/tmp/feature", branch = "feature/acp", base = "main", run = run,
  }))
  assert(metadata.original_root == "/repo", "worktree original root")
  assert(metadata.worktree_path == "/tmp/feature", "worktree path")
  assert(vim.deep_equal(calls[2], {
    "git", "-C", "/repo", "worktree", "add", "-b", "feature/acp", "/tmp/feature", "main",
  }), "worktree create argv")

  local cleanup_calls = {}
  local cleaned = assert(Worktree.cleanup({ metadata = metadata }, { run = function(argv)
    cleanup_calls[#cleanup_calls + 1] = argv
    return ""
  end }))
  assert(cleaned.worktree_state == "cleaned", "worktree cleaned state")
  assert(cleanup_calls[2][4] == "worktree" and cleanup_calls[2][5] == "remove", "worktree remove argv")
  local dirty, dirty_err = Worktree.cleanup({ metadata = metadata }, { run = function(argv)
    return argv[4] == "status" and " M dirty.lua\n" or ""
  end })
  assert(dirty == nil and dirty_err:match("uncommitted"), "dirty worktree protection")
end

return M

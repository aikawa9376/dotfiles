local M = {}

function M.register(create, delete)
  delete("LazyAgentReview")
  create("LazyAgentReview", function(args)
    require("lazyagent.acp.git_review_controller").start(args.args)
  end, { nargs = "?", desc = "Review the active Diffview or a Git range with an idle ACP agent" })

  delete("LazyAgentReviews")
  create("LazyAgentReviews", function(args)
    require("lazyagent.acp.git_review_controller").open(args.args)
  end, { nargs = "?", desc = "Open saved AI code reviews" })
end

return M

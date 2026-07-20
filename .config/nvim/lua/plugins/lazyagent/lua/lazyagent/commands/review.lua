local M = {}

function M.register(create, delete)
  delete("LazyAgentReview")
  create("LazyAgentReview", function(args)
    require("lazyagent.acp.git_review_controller").start(args.args)
  end, { nargs = "?", desc = "Ask an idle ACP agent to review a Git range" })

  delete("LazyAgentReviews")
  create("LazyAgentReviews", function(args)
    require("lazyagent.acp.git_review_controller").open(args.args)
  end, { nargs = "?", desc = "Open saved AI Git reviews" })
end

return M

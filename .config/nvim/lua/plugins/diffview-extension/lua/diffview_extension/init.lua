local M = {}

local configured = false

function M.setup()
  if configured then return end
  configured = true
  vim.g.diffview_extension_instance = vim.g.diffview_extension_instance or tostring((vim.uv or vim.loop).hrtime())

  local controller = require("lazyagent.acp.git_review_controller")
  local snapshot = require("diffview_extension.snapshot")
  local review_view = require("diffview_extension.review_view")

  controller.register_frontend("diffview", {
    current_snapshot = function(services)
      local ok, lib = pcall(require, "diffview.lib")
      local view = ok and lib.get_current_view() or nil
      return view and snapshot.capture(view, services) or nil
    end,
    refresh_snapshot = function(review, services)
      return snapshot.refresh(review, services)
    end,
    open = function(review)
      return review_view.open(review)
    end,
  })

  local group = vim.api.nvim_create_augroup("DiffviewExtensionReview", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "DiffviewDiffBufWinEnter", "DiffviewSelectionChanged", "LazyAgentReviewCompleted" },
    callback = function() vim.schedule(review_view.attach_current) end,
  })
  vim.api.nvim_create_autocmd("TabClosed", {
    group = group,
    callback = review_view.cleanup,
  })
end

return M

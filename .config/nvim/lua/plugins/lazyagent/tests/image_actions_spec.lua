local M = {}

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local image_actions = require("lazyagent.logic.image_actions")
  local removed
  local completed
  local controller = image_actions.new({
    current_image = function(bufnr)
      return { source = "/tmp/image.png", bufnr = bufnr }
    end,
    remove = function(bufnr, reference)
      removed = { bufnr = bufnr, source = reference.source }
      return true
    end,
  })

  local opened = controller.open(21, {
    select = function(items, opts, done)
      assert(opts.prompt:find("/tmp/image.png", 1, true), "image action prompt includes its source")
      for _, item in ipairs(items) do
        if item.id == "remove" then
          done(item)
          return
        end
      end
    end,
    on_done = function(result)
      completed = result
    end,
  })
  assert_equal(opened, true, "image action menu opens")
  assert_equal(removed, { bufnr = 21, source = "/tmp/image.png" }, "remove image action")
  assert_equal(completed, true, "image action completion")

  local notified
  controller = image_actions.new({
    current_image = function()
      return nil
    end,
    notify = function(message)
      notified = message
    end,
  })
  assert_equal(controller.open(22), false, "image action menu rejects a non-image cursor")
  assert(notified:find("cursor", 1, true), "non-image cursor guidance")
end

return M

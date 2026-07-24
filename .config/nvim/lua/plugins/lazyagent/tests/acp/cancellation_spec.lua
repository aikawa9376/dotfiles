local M = {}

local function assert_equal(expected, actual, label)
  if not vim.deep_equal(expected, actual) then
    error(string.format(
      "%s: expected %s, got %s",
      label or "values differ",
      vim.inspect(expected),
      vim.inspect(actual)
    ), 2)
  end
end

function M.run()
  local cancellation = require("lazyagent.acp.backend.cancellation")
  local blocks = {}
  local session = {
    tool_calls = {
      ["tool-b"] = {
        toolCallId = "tool-b",
        title = "Second tool",
        status = "in_progress",
        path = "/tmp/second.lua",
      },
      ["tool-a"] = {
        toolCallId = "tool-a",
        title = "First tool",
        status = "pending",
        path = "/tmp/first.lua",
      },
    },
  }

  local count = cancellation.finalize_tools(session, {
    merge_tool_update = function(target, update)
      local current = target.tool_calls[update.toolCallId] or {}
      local merged = vim.tbl_deep_extend("force", {}, current, update)
      target.tool_calls[update.toolCallId] = merged
      return merged
    end,
    append_block = function(_, heading, body, meta)
      blocks[#blocks + 1] = {
        heading = heading,
        body = body,
        meta = meta,
      }
    end,
    tool_heading = function(tool)
      return "Tool " .. tostring(tool.status)
    end,
    extract_tool_paths = function(tool)
      return { tool.path }
    end,
  })

  assert_equal(2, count, "finalized tool count")
  assert_equal(nil, next(session.tool_calls), "active tool map")
  assert_equal(2, #blocks, "cancellation blocks")
  assert_equal("tool-a", blocks[1].meta.toolCallId, "stable tool order")
  assert_equal("cancelled", blocks[1].meta.status, "first tool status")
  assert_equal("/tmp/first.lua", blocks[1].meta.path, "first tool path")
  assert_equal("Tool cancelled", blocks[2].heading, "second tool heading")

  local fallback_blocks = {}
  local fallback_session = {
    tool_calls = {
      ["tool-without-path-helper"] = {
        title = "Fallback tool",
        status = "in_progress",
      },
    },
  }
  local fallback_count = cancellation.finalize_tools(fallback_session, {
    merge_tool_update = function(target, update)
      local merged = vim.tbl_deep_extend("force", {}, target.tool_calls[update.toolCallId], update)
      target.tool_calls[update.toolCallId] = merged
      return merged
    end,
    append_block = function(_, _, _, meta)
      fallback_blocks[#fallback_blocks + 1] = meta
    end,
    tool_heading = function()
      return "Tool cancelled"
    end,
  })
  assert_equal(1, fallback_count, "missing optional path helper does not interrupt cancellation")
  assert_equal(nil, fallback_blocks[1].path, "missing path helper omits path metadata")
  assert_equal(nil, next(fallback_session.tool_calls), "fallback active tool map")
end

return M

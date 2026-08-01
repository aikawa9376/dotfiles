local M = {}

function M.run()
  local bufnr = vim.api.nvim_create_buf(false, true)
  local namespace = vim.api.nvim_create_namespace("lazyagent_acp_view_diff_spec_" .. tostring(bufnr))
  local lines = {
    "```lua",
    'local message = "a very long string"',
    "```",
  }
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  local view = require("lazyagent.acp.view_diff").new({
    diff_utils = {
      parse_rendered_diff_block = function() return { old_lines = {}, new_lines = {} } end,
    },
    diff_ns = namespace,
    transcript_line_count = function() return 3 end,
    transcript_lines = function(buf, start_idx, end_idx)
      return vim.api.nvim_buf_get_lines(buf, start_idx, end_idx, false)
    end,
    captures_at_pos = function(_, row, col)
      assert(row == 1 and col >= 0, "capture lookup uses the character before the ellipsis")
      return {
        { capture = "markup.raw.block", lang = "markdown", metadata = { priority = 100 } },
        { capture = "string", lang = "lua", metadata = { priority = 100 } },
      }
    end,
    session_for_agent = function() return nil end,
    agent_name_for_bufnr = function() return nil end,
  })

  local normalized, changed = view.normalize_diff_display_lines(bufnr, lines, 18, 0)
  assert(changed, "long code-block line is truncated")
  assert(normalized[2]:sub(-3) == "...", "truncated line ends with an ellipsis")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, normalized)
  view.decorate_diff_blocks(bufnr)

  local found = false
  local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true })
  for _, extmark in ipairs(extmarks) do
    local details = extmark[4] or {}
    if details.hl_group == "@string.lua" then
      found = details.end_col == #normalized[2]
        and extmark[3] == #normalized[2] - 3
    end
  end
  assert(found, "ellipsis highlight extmark mismatch: " .. vim.inspect(extmarks))

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

return M

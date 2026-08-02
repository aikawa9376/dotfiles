local M = {}

function M.run()
  local bufnr = vim.api.nvim_create_buf(false, true)
  local namespace = vim.api.nvim_create_namespace("lazyagent_acp_view_diff_spec_" .. tostring(bufnr))
  local lines = {
    "```lua",
    'local message = "a very long string"',
    'local answer = "ok"',
    "```",
  }
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  local view = require("lazyagent.acp.view_diff").new({
    diff_utils = {
      parse_rendered_diff_block = function() return { old_lines = {}, new_lines = {} } end,
    },
    diff_ns = namespace,
    transcript_line_count = function() return 4 end,
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
  assert(normalized[2] == lines[2], "truncation preserves the source line for syntax parsing")
  assert(normalized[3] == lines[3], "a following string remains independently parseable")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, normalized)
  view.decorate_diff_blocks(bufnr)

  local found_conceal = false
  local found_ellipsis = false
  local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true })
  for _, extmark in ipairs(extmarks) do
    local details = extmark[4] or {}
    if extmark[2] == 1 and details.conceal == "" then
      found_conceal = details.end_col == #normalized[2] and extmark[3] < #normalized[2]
    end
    local chunk = details.virt_text and details.virt_text[1] or nil
    if extmark[2] == 1 and chunk and chunk[1] == "..." then
      found_ellipsis = chunk[2] == "@string.lua" and extmark[3] < #normalized[2]
    end
  end
  assert(found_conceal, "truncated suffix conceal extmark mismatch: " .. vim.inspect(extmarks))
  assert(found_ellipsis, "ellipsis virtual text highlight mismatch: " .. vim.inspect(extmarks))

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

return M

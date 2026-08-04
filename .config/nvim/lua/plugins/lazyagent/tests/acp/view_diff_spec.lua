local M = {}

function M.run()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, bufnr)
  vim.wo.conceallevel = 0
  vim.wo.concealcursor = ""
  local original_render_markdown_state = package.loaded["render-markdown.state"]
  package.loaded["render-markdown.state"] = {
    get = function()
      return {
        enabled = true,
        code = {
          enabled = true,
          language_pad = 1,
          language_left = "",
          language_right = "",
          left_margin = 0,
          left_pad = 1,
          right_pad = 1,
          min_width = 40,
        },
      }
    end,
  }
  local namespace = vim.api.nvim_create_namespace("lazyagent_acp_view_diff_spec_" .. tostring(bufnr))
  local lines = {
    "```lua",
    'local message = "very long string"',
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

  local normalized, changed = view.normalize_diff_display_lines(bufnr, lines, 28, 0)
  assert(changed, "long code-block line is truncated")
  assert(normalized[2]:sub(-4) == '..."', "truncated string gets a hidden closing quote")
  assert(vim.fn.strdisplaywidth(normalized[2]) + 1 <= 28,
    "physical line plus render-markdown padding fits the transcript window")
  assert(normalized[3] == lines[3], "a following string remains independently parseable")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, normalized)
  view.decorate_diff_blocks(bufnr)

  local found_conceal = false
  local found_ellipsis_highlight = false
  local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true })
  for _, extmark in ipairs(extmarks) do
    local details = extmark[4] or {}
    if extmark[2] == 1 and details.conceal == "" then
      found_conceal = details.end_col == #normalized[2] and extmark[3] == #normalized[2] - 1
    end
    if extmark[2] == 1 and details.hl_group == "@string.lua" then
      found_ellipsis_highlight = details.end_col == #normalized[2] - 1
        and extmark[3] == #normalized[2] - 4
    end
  end
  assert(found_conceal, "truncated suffix conceal extmark mismatch: " .. vim.inspect(extmarks))
  assert(found_ellipsis_highlight, "ellipsis highlight extmark mismatch: " .. vim.inspect(extmarks))
  assert(vim.wo.conceallevel == 2, "truncation enables conceal in an existing transcript window")
  assert(vim.wo.concealcursor == "nvic", "truncation remains concealed on the cursor line in every mode")

  package.loaded["render-markdown.state"] = original_render_markdown_state
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

return M

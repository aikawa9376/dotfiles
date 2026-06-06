local M = {}

local markdown_query = [[
    (fenced_code_block) @code

    [
        (thematic_break)
        (minus_metadata)
        (plus_metadata)
    ] @dash

    (document) @document

    (link_reference_definition (link_label) @footnote)

    [
        (atx_heading)
        (setext_heading)
    ] @heading

    (list_item) @list

    (section (paragraph) @paragraph)

    (block_quote) @quote

    (section) @section

    (pipe_table) @table
]]

local function is_lazyagent_buffer(buf)
  local filetype = vim.bo[buf].filetype
  return filetype == "lazyagent" or filetype == "lazyagent_acp"
end

local function is_lazyagent_acp_buffer(buf)
  return vim.bo[buf].filetype == "lazyagent_acp"
end

local function is_diff_header(line)
  return line:match("^@@")
    or line:match("^diff %-%-git")
    or line:match("^index ")
    or line:match("^--- ")
    or line:match("^%+%+%+ ")
end

local function is_diff_change(line)
  return line:match("^[+-] ") ~= nil
end

local function is_diff_list_item(buf, node)
  if not is_lazyagent_buffer(buf) then
    return false
  end

  local row = node.start_row
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
  if not line or not is_diff_change(line) then
    return false
  end

  local first_row = math.max(row - 8, 0)
  local last_row = math.min(row + 8, vim.api.nvim_buf_line_count(buf) - 1)
  local lines = vim.api.nvim_buf_get_lines(buf, first_row, last_row + 1, false)
  local change_count = 0
  local saw_minus = false
  local saw_plus = false

  for _, nearby in ipairs(lines) do
    if is_diff_header(nearby) then
      return true
    end

    if is_diff_change(nearby) then
      change_count = change_count + 1
      saw_minus = saw_minus or nearby:match("^%- ") ~= nil
      saw_plus = saw_plus or nearby:match("^%+ ") ~= nil
    end
  end

  return change_count >= 2 and saw_minus and saw_plus
end

local function transcript_skip_ranges(buf)
  if not is_lazyagent_acp_buffer(buf) then
    return nil
  end

  local section_heading_for_line = require("lazyagent.acp.view_buffer.sections").section_heading_for_line
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local ranges = {}
  local skip_start = nil

  for idx, line in ipairs(lines) do
    local heading = section_heading_for_line(line)
    if heading then
      if skip_start then
        ranges[#ranges + 1] = { start_row = skip_start, end_row = idx - 2 }
        skip_start = nil
      end
      if heading == "Tool" or heading == "Edited" then
        skip_start = idx - 1
      end
    end
  end

  if skip_start then
    ranges[#ranges + 1] = { start_row = skip_start, end_row = #lines - 1 }
  end

  return #ranges > 0 and ranges or nil
end

local function row_in_ranges(row, ranges)
  if not ranges then
    return false
  end

  local left = 1
  local right = #ranges
  while left <= right do
    local mid = math.floor((left + right) / 2)
    local range = ranges[mid]
    if row < range.start_row then
      right = mid - 1
    elseif row > range.end_row then
      left = mid + 1
    else
      return true
    end
  end
  return false
end

local function should_skip_render(buf, capture, node, ranges)
  if row_in_ranges(node.start_row, ranges) then
    return true
  end
  if capture == "list" and is_diff_list_item(buf, node) then
    return true
  end
  return false
end

function M.parse(ctx)
  local ts = require("render-markdown.core.ts")
  local Context = require("render-markdown.request.context")
  local Marks = require("render-markdown.lib.marks")

  local query = ts.parse("markdown", markdown_query)
  local renders = {
    code = require("render-markdown.render.markdown.code"),
    dash = require("render-markdown.render.markdown.dash"),
    document = require("render-markdown.render.markdown.document"),
    footnote = require("render-markdown.render.common.footnote"),
    heading = require("render-markdown.render.markdown.heading"),
    list = require("render-markdown.render.markdown.list"),
    paragraph = require("render-markdown.render.markdown.paragraph"),
    quote = require("render-markdown.render.markdown.quote"),
    section = require("render-markdown.render.markdown.section"),
    table = require("render-markdown.render.markdown.table"),
  }

  local context = Context.get(ctx.buf)
  local marks = Marks.new(context, false)
  local skip_ranges = transcript_skip_ranges(ctx.buf)
  context.view:nodes(ctx.root, query, function(capture, node)
    if should_skip_render(ctx.buf, capture, node, skip_ranges) then
      return
    end

    local render = renders[capture]
    assert(render, ("unhandled markdown capture: %s"):format(capture))
    render:execute(context, marks, node)
  end)
  return marks:get()
end

return M

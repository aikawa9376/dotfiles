local M = {}
local sections = require("lazyagent.acp.view_buffer.sections")

function M.is_message(heading)
  return heading == "User" or heading == "Assistant"
end

-- Associate items before removing sections: the runtime timeline also includes
-- tools and diagnostics, so aligning it to the filtered list selects wrong IDs.
function M.project(lines, source_sections, items)
  local out, kept_items = {}, {}
  if lines[1] == "... earlier transcript omitted from buffer ..." then
    out[1] = lines[1]
  end
  for index, section in ipairs(source_sections) do
    if M.is_message(section.heading) then
      local stop = source_sections[index + 1] and source_sections[index + 1].start_row - 1 or #lines
      for row = section.start_row, stop do out[#out + 1] = lines[row] end
      kept_items[#kept_items + 1] = items[index] or {}
    end
  end
  return out, kept_items
end

function M.tail_state(lines, source_sections)
  return {
    heading = source_sections[#source_sections] and source_sections[#source_sections].heading,
    tail = lines[#lines] or "",
  }
end

-- Headers are emitted as complete blocks by the backend. Keep just the source
-- tail so hidden tool-output chunks need neither a buffer write nor a file read.
function M.append_action(state, text)
  if not state then return "refresh" end
  local lines = vim.split((state.tail or "") .. text, "\n", { plain = true })
  for _, line in ipairs(lines) do
    if sections.section_heading_for_line(line) then return "refresh" end
  end
  state.tail = lines[#lines] or ""
  return M.is_message(state.heading) and "append" or "skip"
end

return M

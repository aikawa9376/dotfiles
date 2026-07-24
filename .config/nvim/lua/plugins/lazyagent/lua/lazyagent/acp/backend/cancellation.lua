local M = {}

local function first_tool_path(tool, deps)
  if type(deps.extract_tool_paths) ~= "function" then
    return nil
  end
  local ok, paths = pcall(deps.extract_tool_paths, tool)
  if not ok or type(paths) ~= "table" then
    return nil
  end
  return paths[1]
end

function M.finalize_tools(session, deps)
  if not session then
    return 0
  end
  deps = deps or {}
  local pending_ids = {}
  for tool_call_id in pairs(session.tool_calls or {}) do
    pending_ids[#pending_ids + 1] = tool_call_id
  end
  table.sort(pending_ids)

  for _, tool_call_id in ipairs(pending_ids) do
    local current = session.tool_calls[tool_call_id] or {}
    local tool = deps.merge_tool_update(session, {
      toolCallId = tool_call_id,
      status = "cancelled",
    })
    local title = tool.title or current.title or tool_call_id
    deps.append_block(session, deps.tool_heading(tool), title, {
      kind = "tool",
      title = title,
      summary = title,
      toolCallId = tool_call_id,
      status = "cancelled",
      path = first_tool_path(tool, deps),
    })
    session.tool_calls[tool_call_id] = nil
  end

  return #pending_ids
end

return M

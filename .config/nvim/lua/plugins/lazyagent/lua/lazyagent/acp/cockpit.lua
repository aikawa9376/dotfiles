local M = {}

local function changed_file_count(thread)
  local seen = {}
  for _, turn in ipairs(thread.change_journal and thread.change_journal.turns or {}) do
    for _, change in ipairs(turn.changes or {}) do
      local path = change.path or change.new_path or change.old_path
      if path and path ~= "" then seen[path] = true end
    end
  end
  return vim.tbl_count(seen)
end

local function group_path(thread)
  local metadata = type(thread.metadata) == "table" and thread.metadata or {}
  return metadata.worktree_path or thread.cwd or "(unknown workspace)"
end

function M.render(threads)
  local groups = {}
  for _, thread in ipairs(threads or {}) do
    local path = group_path(thread)
    groups[path] = groups[path] or {}
    groups[path][#groups[path] + 1] = thread
  end
  local paths = vim.tbl_keys(groups)
  table.sort(paths)

  local lines = {
    "# LazyAgent ACP Session Cockpit",
    "",
    "`<CR>` open  `r` refresh  `q` close",
  }
  local line_map = {}
  if #paths == 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "_No persisted ACP threads._"
    return lines, line_map
  end

  for _, path in ipairs(paths) do
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## " .. vim.fn.fnamemodify(path, ":~")
    table.sort(groups[path], function(left, right)
      if left.updated_at == right.updated_at then return left.thread_id < right.thread_id end
      return tostring(left.updated_at or "") > tostring(right.updated_at or "")
    end)
    for _, thread in ipairs(groups[path]) do
      local unread = thread.unread == true and "unread" or "read"
      local model = thread.model and thread.model ~= "" and thread.model or "default"
      local changes = changed_file_count(thread)
      lines[#lines + 1] = string.format(
        "- [%s] %s · %s · model:%s · %s · changes:%d",
        tostring(thread.status or "closed"),
        tostring(thread.title or thread.thread_id),
        tostring(thread.provider_id or "provider"),
        tostring(model),
        unread,
        changes
      )
      line_map[#lines] = thread.thread_id
    end
  end
  return lines, line_map
end

return M

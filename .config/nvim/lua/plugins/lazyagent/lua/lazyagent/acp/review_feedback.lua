local M = {}
local scratch_input = require("lazyagent.scratch_input")

local function user_notes(turn)
  local notes = {}
  for _, annotation in ipairs(require("lazyagent.acp.review_annotations").normalize_all(turn and turn.annotations)) do
    if annotation.author and annotation.author.type == "user" then
      notes[#notes + 1] = annotation
    end
  end
  return notes
end

local function target_label(annotation)
  if not annotation.path then return "Overall" end
  local first = annotation.target and annotation.target.start_line
  local last = annotation.target and annotation.target.end_line or first
  if not first then return annotation.path end
  return first == last
      and string.format("%s:%d", annotation.path, first)
    or string.format("%s:%d-%d", annotation.path, first, last)
end

function M.build_prompt(turn)
  local lines = {
    string.format("Review feedback for turn %s.", tostring(turn and turn.turn_id or "unknown")),
  }
  local has_decisions = false
  for _, change in ipairs(turn and turn.changes or {}) do
    if change.decision then
      if not has_decisions then vim.list_extend(lines, { "", "## Decisions" }); has_decisions = true end
      lines[#lines + 1] = string.format(
        "- %s: %s",
        change.decision == "kept" and "Approved" or "Rejected",
        tostring(change.path or "unknown")
      )
    end
    for _, hunk in ipairs(change.hunks or {}) do
      if hunk.decision then
        if not has_decisions then vim.list_extend(lines, { "", "## Decisions" }); has_decisions = true end
        lines[#lines + 1] = string.format(
          "- %s hunk: %s @@ -%d,%d +%d,%d @@",
          hunk.decision == "kept" and "Approved" or "Rejected",
          tostring(change.path or "unknown"),
          tonumber(hunk.before_start) or 0,
          tonumber(hunk.before_count) or 0,
          tonumber(hunk.after_start) or 0,
          tonumber(hunk.after_count) or 0
        )
      end
    end
  end

  local ids = {}
  local notes = user_notes(turn)
  if #notes > 0 then
    vim.list_extend(lines, { "", "## Review Notes" })
    for _, annotation in ipairs(notes) do
      lines[#lines + 1] = "- " .. target_label(annotation)
      local body = annotation.rationale or annotation.summary or ""
      for _, line in ipairs(vim.split(body, "\n", { plain = true })) do
        lines[#lines + 1] = "  " .. line
      end
      ids[#ids + 1] = annotation.id
    end
  end
  vim.list_extend(lines, { "", "Please address this feedback and run the relevant tests." })
  return table.concat(lines, "\n"), ids, has_decisions or #notes > 0
end

function M.open_editor(opts)
  opts = opts or {}
  return scratch_input.open({
    source_bufnr = opts.source_bufnr,
    source_winid = opts.source_winid,
    window_type = opts.window_type,
    window_opts = opts.window_opts,
    is_vertical = opts.is_vertical,
    start_in_insert_on_focus = opts.start_in_insert_on_focus,
    title = opts.title or " LazyAgent Review Note ",
    text = opts.text,
    buffer_vars = { lazyagent_review_editor = true },
    empty_message = "review text is empty",
    error_prefix = "LazyAgent ACP: ",
    submit_desc = opts.submit_desc,
    cancel_desc = "Cancel review editor",
    on_submit = opts.on_submit,
  })
end

return M

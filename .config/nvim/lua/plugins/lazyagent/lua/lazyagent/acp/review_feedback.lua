local M = {}

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
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "markdown"
  vim.b[bufnr].lazyagent_review_editor = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(tostring(opts.text or ""), "\n", { plain = true }))

  local width = math.max(50, math.floor(vim.o.columns * 0.68))
  local height = math.max(8, math.floor(vim.o.lines * 0.42))
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = math.min(width, vim.o.columns - 4),
    height = math.min(height, vim.o.lines - 4),
    style = "minimal",
    border = "rounded",
    title = opts.title or " LazyAgent Review Note ",
    title_pos = "left",
    footer = string.format(" <C-Space> %s · q cancel ", opts.action or "save"),
    footer_pos = "right",
  })
  vim.wo[winid].wrap = true
  vim.wo[winid].linebreak = true

  local function close()
    if vim.api.nvim_win_is_valid(winid) then vim.api.nvim_win_close(winid, true) end
  end
  local function submit()
    local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n"))
    if text == "" then
      vim.notify("LazyAgent ACP: review text is empty", vim.log.levels.ERROR)
      return
    end
    local ok, err = opts.on_submit(text)
    if not ok then
      vim.notify("LazyAgent ACP: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    pcall(vim.cmd, "stopinsert")
    close()
  end
  for _, mode in ipairs({ "n", "i" }) do
    vim.keymap.set(mode, "<C-Space>", submit, { buffer = bufnr, silent = true, desc = opts.submit_desc })
  end
  vim.keymap.set("n", "ZZ", submit, { buffer = bufnr, silent = true, desc = opts.submit_desc })
  vim.keymap.set("n", "q", close, { buffer = bufnr, silent = true, nowait = true, desc = "Cancel review editor" })
  vim.cmd("startinsert")
  return bufnr, winid
end

return M

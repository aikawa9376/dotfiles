local M = {}
local ReviewAnnotations = require("lazyagent.acp.review_annotations")

local operation_marker = {
  added = "A",
  modified = "M",
  deleted = "D",
  moved = "R",
}

local change_namespace = vim.api.nvim_create_namespace("LazyAgentACPChanges")
local PRIORITY_BG = 200
local PRIORITY_SYNTAX = 210

local operation_highlight = {
  added = "LazyAgentACPChangesAdded",
  modified = "LazyAgentACPChangesModified",
  deleted = "LazyAgentACPChangesDeleted",
  moved = "LazyAgentACPChangesMoved",
}

local function setup_highlights()
  -- Keep these available even when fugitive-extension is lazy-loaded after
  -- Changes. Otherwise `default` would permanently link this buffer to the
  -- plainer built-in Diff groups for the rest of the session.
  vim.api.nvim_set_hl(0, "FugitiveExtAdd", { bg = "#23384C", default = true })
  vim.api.nvim_set_hl(0, "FugitiveExtDelete", { bg = "#321e1e", default = true })
  vim.api.nvim_set_hl(0, "FugitiveExtAddText", { bg = "#005f5f", default = true })
  vim.api.nvim_set_hl(0, "FugitiveExtDeleteText", { bg = "#8c3b40", default = true })
  vim.api.nvim_set_hl(0, "LazyAgentACPChangesAdded", { link = "GitSignsAdd", default = true })
  vim.api.nvim_set_hl(0, "LazyAgentACPChangesModified", { link = "GitSignsChange", default = true })
  vim.api.nvim_set_hl(0, "LazyAgentACPChangesDeleted", { link = "GitSignsDelete", default = true })
  vim.api.nvim_set_hl(0, "LazyAgentACPChangesMoved", { link = "GitSignsChange", default = true })
  vim.api.nvim_set_hl(0, "LazyAgentACPChangesApproved", { link = "DiagnosticOk", default = true })
  vim.api.nvim_set_hl(0, "LazyAgentACPChangesRejected", { link = "DiagnosticError", default = true })
  vim.api.nvim_set_hl(0, "LazyAgentACPChangesApprovedLine", { link = "DiffAdd", default = true })
  vim.api.nvim_set_hl(0, "LazyAgentACPChangesRejectedLine", { link = "DiffDelete", default = true })
  vim.api.nvim_set_hl(0, "LazyAgentACPChangesDiffAdd", {
    link = "FugitiveExtAdd", default = true,
  })
  vim.api.nvim_set_hl(0, "LazyAgentACPChangesDiffDelete", {
    link = "FugitiveExtDelete", default = true,
  })
  vim.api.nvim_set_hl(0, "LazyAgentACPChangesDiffAddText", {
    link = "FugitiveExtAddText", default = true,
  })
  vim.api.nvim_set_hl(0, "LazyAgentACPChangesDiffDeleteText", {
    link = "FugitiveExtDeleteText", default = true,
  })
  vim.api.nvim_set_hl(0, "LazyAgentACPChangesNote", { link = "GitSignsChange", default = true })
end

local function latest_changed_turn(thread)
  local turns = thread and thread.change_journal and thread.change_journal.turns or {}
  for index = #turns, 1, -1 do
    if turns[index].state == "active"
      or type(turns[index].changes) == "table" and #turns[index].changes > 0
    then
      return turns[index]
    end
  end
  return nil
end

local function changed_turns(thread)
  local result = {}
  local turns = thread and thread.change_journal and thread.change_journal.turns or {}
  for _, turn in ipairs(turns) do
    if turn.state == "active" or type(turn.changes) == "table" and #turn.changes > 0 then
      result[#result + 1] = turn
    end
  end
  return result
end

local function display_path(change)
  if change.operation == "moved" and change.previous_path then
    return string.format("%s -> %s", change.previous_path, change.path)
  end
  return tostring(change.path or "unknown")
end

local function display_decision(decision)
  if decision == "kept" then
    return "approved"
  end
  return decision
end

local function devicon_for(path)
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if not ok or type(devicons.get_icon) ~= "function" then
    return nil, nil
  end
  return devicons.get_icon(tostring(path or ""), nil, { default = true })
end

local function split_lines(text)
  local lines = vim.split(tostring(text or ""), "\n", { plain = true })
  return #lines > 0 and lines or { "" }
end

local function set_scratch(bufnr, name, lines, filetype)
  vim.api.nvim_buf_set_name(bufnr, name)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].filetype = filetype or ""
  vim.bo[bufnr].modifiable = false
end

local function filetype_for(path)
  local extension = tostring(path or ""):match("%.([^./]+)$")
  return extension and vim.filetype.match({ filename = "file." .. extension }) or nil
end

function M.latest_turn(thread)
  return latest_changed_turn(thread)
end

function M.changed_turns(thread)
  return changed_turns(thread)
end

function M.drawer_content(thread, turn, turn_index, turn_count, inline_diffs)
  local history = ""
  if turn_index and turn_count and turn_count > 1 then
    history = string.format(" · %d/%d · [t/]t previous/next", turn_index, turn_count)
  end
  local live = turn.state == "active" and " · live" or ""
  local turn_annotations = ReviewAnnotations.for_turn(turn)
  local has_final = false
  local general_notes = 0
  for _, annotation in ipairs(turn_annotations) do
    if annotation.kind == "explanation" then
      has_final = true
    else
      general_notes = general_notes + 1
    end
  end
  local annotation_status = has_final and " · 📝 final" or ""
  if general_notes > 0 then annotation_status = annotation_status .. " · 💬" .. general_notes end
  local lines = {
    string.format("LazyAgent ACP Changes — %s", thread.title or thread.thread_id),
    string.format(
      "Turn %s · %d file(s)%s%s",
      turn.turn_id or "unknown",
      #(turn.changes or {}),
      history .. live,
      annotation_status
    ),
    "`?` actions  `K` note/final  `i` next diff  `o` toggle inline  `<CR>` open file  `d` diff tab",
    "",
  }
  local change_rows = {}
  local line_changes = {}
  local line_targets = {}
  for index, change in ipairs(turn.changes or {}) do
    local binary = change.binary == true and " [binary]" or ""
    local decision = change.decision
        and (" [" .. display_decision(change.decision) .. (change.apply_mode and (":" .. change.apply_mode) or "") .. "]")
      or ""
    local decided_hunks = 0
    for _, hunk in ipairs(change.hunks or {}) do
      if hunk.decision then
        decided_hunks = decided_hunks + 1
      end
    end
    local hunk_state = decided_hunks > 0 and string.format(" [hunks %d/%d]", decided_hunks, #change.hunks) or ""
    local note_count = #ReviewAnnotations.for_change(turn, change)
    local notes = note_count > 0 and (" 💬" .. note_count) or ""
    lines[#lines + 1] = string.format(
      "%s  %s%s%s%s%s",
      operation_marker[change.operation] or "?",
      display_path(change),
      binary,
      decision,
      hunk_state,
      notes
    )
    change_rows[index] = #lines
    line_changes[#lines] = index
    line_targets[#lines] = 1
    local after_line
    for _, diff_line in ipairs((inline_diffs or {})[index] or {}) do
      lines[#lines + 1] = diff_line
      line_changes[#lines] = index
      local hunk_line = diff_line:match("^@@ %-%d+,?%d* %+(%d+),?%d* @@")
      if hunk_line then
        after_line = tonumber(hunk_line)
      elseif after_line and diff_line:sub(1, 1) ~= "-" then
        line_targets[#lines] = after_line
        if diff_line:sub(1, 1) == "+" or diff_line:sub(1, 1) == " " then
          after_line = after_line + 1
        end
      end
      line_targets[#lines] = line_targets[#lines] or after_line
    end
  end
  return lines, change_rows, line_changes, line_targets
end

local function open_annotation_float(annotations, title)
  local lines = ReviewAnnotations.markdown(annotations)
  if #lines == 0 then return false end
  local width = math.min(math.max(48, math.floor(vim.o.columns * 0.55)), vim.o.columns - 4)
  local height = math.min(math.max(4, #lines), math.max(4, math.floor(vim.o.lines * 0.55)))
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "markdown"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "cursor", row = 1, col = 1, width = width, height = height,
    style = "minimal", border = "rounded", title = " " .. title .. " ", title_pos = "center",
  })
  vim.wo[winid].wrap = true
  vim.wo[winid].conceallevel = 2
  local close = function()
    if vim.api.nvim_win_is_valid(winid) then vim.api.nvim_win_close(winid, true) end
  end
  vim.keymap.set("n", "q", close, { buffer = bufnr, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = bufnr, nowait = true, silent = true })
  return true
end

function M.drawer_lines(thread, turn, turn_index, turn_count, inline_diffs)
  local lines = M.drawer_content(thread, turn, turn_index, turn_count, inline_diffs)
  return lines
end

local function changed_span(left, right)
  local prefix = 0
  local limit = math.min(#left, #right)
  while prefix < limit and left:byte(prefix + 1) == right:byte(prefix + 1) do
    prefix = prefix + 1
  end
  local suffix = 0
  while suffix < limit - prefix
    and left:byte(#left - suffix) == right:byte(#right - suffix)
  do
    suffix = suffix + 1
  end
  return prefix + 1, #left - suffix + 1, prefix + 1, #right - suffix + 1
end

local function apply_inline_highlights(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local deleted, added = {}, {}
  local function flush()
    for index = 1, math.min(#deleted, #added) do
      local old = deleted[index]
      local new = added[index]
      local old_start, old_end, new_start, new_end = changed_span(old.text:sub(2), new.text:sub(2))
      if old_start < old_end then
        vim.api.nvim_buf_set_extmark(bufnr, change_namespace, old.row, old_start, {
          end_col = old_end, hl_group = "LazyAgentACPChangesDiffDeleteText", priority = PRIORITY_SYNTAX + 150,
        })
      end
      if new_start < new_end then
        vim.api.nvim_buf_set_extmark(bufnr, change_namespace, new.row, new_start, {
          end_col = new_end, hl_group = "LazyAgentACPChangesDiffAddText", priority = PRIORITY_SYNTAX + 150,
        })
      end
    end
    deleted, added = {}, {}
  end
  for row, line in ipairs(lines) do
    local zero_row = row - 1
    if line:match("^@@") then
      flush()
      vim.api.nvim_buf_set_extmark(bufnr, change_namespace, zero_row, 0, {
        end_col = #line, hl_group = "diffLine",
      })
    elseif line:sub(1, 1) == "-" and not line:match("^%-%-%-") then
      if #added > 0 then flush() end
      deleted[#deleted + 1] = { row = zero_row, text = line }
      vim.api.nvim_buf_set_extmark(bufnr, change_namespace, zero_row, 0, {
        end_row = zero_row + 1, end_col = 0, hl_group = "LazyAgentACPChangesDiffDelete", hl_eol = true,
        priority = PRIORITY_BG,
      })
    elseif line:sub(1, 1) == "+" and not line:match("^%+%+%+") then
      added[#added + 1] = { row = zero_row, text = line }
      vim.api.nvim_buf_set_extmark(bufnr, change_namespace, zero_row, 0, {
        end_row = zero_row + 1, end_col = 0, hl_group = "LazyAgentACPChangesDiffAdd", hl_eol = true,
        priority = PRIORITY_BG,
      })
    else
      flush()
    end
  end
  flush()
end

local function treesitter_language(path)
  local filetype = vim.filetype.match({ filename = tostring(path or "") })
  if not filetype then return nil end
  local language = vim.treesitter.language.get_lang(filetype)
  if not language or not pcall(vim.treesitter.language.inspect, language) then return nil end
  return language
end

local function apply_code_capture_highlights(bufnr, code_lines, line_map, language)
  if #code_lines == 0 then return end
  local code = table.concat(code_lines, "\n")
  local parser_ok, parser = pcall(vim.treesitter.get_string_parser, code, language)
  if not parser_ok or not parser then return end
  local parsed_ok, trees = pcall(function() return parser:parse() end)
  if not parsed_ok or not trees or not trees[1] then return end
  local query_ok, query = pcall(vim.treesitter.query.get, language, "highlights")
  if not query_ok or not query then return end
  for capture, node, metadata in query:iter_captures(trees[1]:root(), code) do
    local start_row, start_col, end_row, end_col = node:range()
    local buffer_start = line_map[start_row + 1]
    if buffer_start then
      local buffer_end = line_map[end_row + 1] or buffer_start
      local priority = (tonumber(metadata and metadata.priority) or 100) + PRIORITY_SYNTAX
      pcall(vim.api.nvim_buf_set_extmark, bufnr, change_namespace, buffer_start, start_col + 1, {
        end_row = buffer_end,
        end_col = end_col + 1,
        hl_group = "@" .. query.captures[capture] .. "." .. language,
        priority = priority,
      })
    end
  end
end

local function apply_inline_code_highlights(bufnr, turn, change_rows)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for index, change in ipairs(turn.changes or {}) do
    local language = treesitter_language(change.path)
    if language then
      local first_row = change_rows and change_rows[index] or (index + 3)
      local last_row = ((change_rows and change_rows[index + 1]) or (#lines + 1)) - 1
      local old_code, old_map, new_code, new_map = {}, {}, {}, {}
      local in_hunk = false
      local function flush()
        apply_code_capture_highlights(bufnr, old_code, old_map, language)
        apply_code_capture_highlights(bufnr, new_code, new_map, language)
        old_code, old_map, new_code, new_map = {}, {}, {}, {}
      end
      for row = first_row + 1, last_row do
        local line = lines[row] or ""
        if line:match("^@@.-@@") then
          flush()
          in_hunk = true
        elseif in_hunk and line:match("^[ +%-]") then
          local prefix, content = line:sub(1, 1), line:sub(2)
          if prefix == "-" or prefix == " " then
            old_code[#old_code + 1] = content
            old_map[#old_code] = row - 1
          end
          if prefix == "+" or prefix == " " then
            new_code[#new_code + 1] = content
            new_map[#new_code] = row - 1
          end
        else
          flush()
          in_hunk = false
        end
      end
      flush()
    end
  end
end

function M.apply_drawer_highlights(bufnr, turn, change_rows, line_changes, line_targets)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  setup_highlights()
  vim.api.nvim_buf_clear_namespace(bufnr, change_namespace, 0, -1)
  vim.api.nvim_buf_set_extmark(bufnr, change_namespace, 0, 0, {
    end_col = #(vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""),
    hl_group = "Title",
  })
  vim.api.nvim_buf_set_extmark(bufnr, change_namespace, 1, 0, {
    end_col = #(vim.api.nvim_buf_get_lines(bufnr, 1, 2, false)[1] or ""),
    hl_group = "Comment",
  })
  vim.api.nvim_buf_set_extmark(bufnr, change_namespace, 2, 0, {
    end_col = #(vim.api.nvim_buf_get_lines(bufnr, 2, 3, false)[1] or ""),
    hl_group = "Comment",
  })

  for index, change in ipairs(turn.changes or {}) do
    local row = ((change_rows and change_rows[index]) or (index + 4)) - 1
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
    local marker_hl = operation_highlight[change.operation] or "Comment"
    vim.api.nvim_buf_set_extmark(bufnr, change_namespace, row, 0, {
      end_col = math.min(1, #line),
      hl_group = marker_hl,
    })

    local path = display_path(change)
    local path_start = line:find(path, 1, true)
    if path_start then
      path_start = path_start - 1
      local icon, icon_hl = devicon_for(change.path)
      vim.api.nvim_buf_set_extmark(bufnr, change_namespace, row, path_start, {
        end_col = path_start + #path,
        hl_group = icon_hl or "Directory",
        virt_text = icon and { { icon .. " ", icon_hl or "Directory" } } or nil,
        virt_text_pos = icon and "inline" or nil,
      })
    end

    local decision = display_decision(change.decision)
    if decision then
      local decision_text = "[" .. decision .. (change.apply_mode and (":" .. change.apply_mode) or "") .. "]"
      local decision_start = line:find(decision_text, 1, true)
      local approved = change.decision == "kept"
      vim.api.nvim_buf_set_extmark(bufnr, change_namespace, row, 0, {
        line_hl_group = approved and "LazyAgentACPChangesApprovedLine" or "LazyAgentACPChangesRejectedLine",
        priority = 100,
      })
      if decision_start then
        decision_start = decision_start - 1
        vim.api.nvim_buf_set_extmark(bufnr, change_namespace, row, decision_start, {
          end_col = decision_start + #decision_text,
          hl_group = approved and "LazyAgentACPChangesApproved" or "LazyAgentACPChangesRejected",
          priority = 110,
        })
      end
    end
  end
  local seen = {}
  for row = 1, vim.api.nvim_buf_line_count(bufnr) do
    local index = line_changes and line_changes[row]
    local change = turn.changes and turn.changes[index]
    if change and row ~= change_rows[index] then
      for _, annotation in ipairs(ReviewAnnotations.for_change(turn, change, line_targets and line_targets[row])) do
        if annotation.target.start_line and not seen[annotation.id] then
          seen[annotation.id] = true
          vim.api.nvim_buf_set_extmark(bufnr, change_namespace, row - 1, 0, {
            virt_text = { { " 💬", "LazyAgentACPChangesNote" } }, virt_text_pos = "eol",
          })
        end
      end
    end
  end
  apply_inline_highlights(bufnr)
  apply_inline_code_highlights(bufnr, turn, change_rows)
  return true
end

function M.new(opts)
  opts = opts or {}
  local review = {}

  local function read_blob(ref)
    if not ref then return nil, "blob reference is unavailable" end
    return opts.read_blob(ref)
  end

  local function read_change_side(change, side)
    local ref = side == "before" and change.before_blob or (change.review_blob or change.after_blob)
    if not ref then
      if (side == "before" and change.operation == "added")
        or (side == "after" and change.operation == "deleted")
      then
        return ""
      end
      return nil, side .. " blob is unavailable for " .. tostring(change.operation or "change")
    end
    return read_blob(ref)
  end

  local function map_diff_tab_close(bufnr)
    vim.keymap.set("n", "q", function()
      vim.cmd("tabclose")
    end, { buffer = bufnr, nowait = true, silent = true, desc = "Close LazyAgent ACP diff tab" })
  end

  function review.open_change(thread, turn, change, index)
    if change.binary == true then
      local bufnr = vim.api.nvim_create_buf(false, true)
      set_scratch(bufnr, string.format("lazyagent://binary-change/%s/%d", turn.turn_id, index), {
        "LazyAgent ACP Binary Change",
        "",
        "operation: " .. tostring(change.operation),
        "path: " .. tostring(change.path),
        "previous path: " .. tostring(change.previous_path or ""),
        "before: " .. vim.inspect(change.before_blob),
        "after: " .. vim.inspect(change.after_blob),
      }, "markdown")
      vim.cmd("tabnew")
      vim.api.nvim_win_set_buf(0, bufnr)
      map_diff_tab_close(bufnr)
      return true
    end

    local before, before_err = read_change_side(change, "before")
    local after, after_err = read_change_side(change, "after")
    if before == nil or after == nil then
      vim.notify("LazyAgent ACP: failed to read change blobs: " .. tostring(before_err or after_err), vim.log.levels.ERROR)
      return false
    end
    local suffix = tostring((vim.uv or vim.loop).hrtime())
    local before_buf = vim.api.nvim_create_buf(false, true)
    local after_buf = vim.api.nvim_create_buf(false, true)
    local ft = filetype_for(change.path)
    set_scratch(before_buf, "lazyagent://before/" .. suffix .. "/" .. display_path(change), split_lines(before), ft)
    set_scratch(after_buf, "lazyagent://after/" .. suffix .. "/" .. display_path(change), split_lines(after), ft)
    map_diff_tab_close(before_buf)
    map_diff_tab_close(after_buf)

    vim.cmd("tabnew")
    local before_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(before_win, before_buf)
    vim.cmd("vsplit")
    local after_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(after_win, after_buf)
    vim.api.nvim_set_current_win(before_win)
    vim.cmd("diffthis")
    vim.api.nvim_set_current_win(after_win)
    vim.cmd("diffthis")
    return true
  end

  function review.open_file(thread, turn, change, line)
    local root = (turn.final_snapshot and turn.final_snapshot.root)
      or (turn.baseline and turn.baseline.root)
      or thread.cwd
    local path = root and vim.fs.joinpath(root, tostring(change.path or "")) or nil
    if not path or vim.fn.filereadable(path) ~= 1 then
      vim.notify("LazyAgent ACP: file is unavailable: " .. tostring(path or change.path), vim.log.levels.ERROR)
      return false
    end
    vim.cmd("keepalt edit " .. vim.fn.fnameescape(path))
    local target = math.max(1, math.min(tonumber(line) or 1, vim.api.nvim_buf_line_count(0)))
    vim.api.nvim_win_set_cursor(0, { target, 0 })
    return true
  end

  function review.open(thread)
    local turns = changed_turns(thread)
    local turn_index = #turns
    local turn = turns[turn_index]
    local inline_by_turn = {}
    local change_rows = {}
    local line_changes = {}
    local line_targets = {}
    if not turn then
      return nil, "thread has no completed file changes"
    end
    local name = string.format("lazyagent://changes/%s/%s", thread.thread_id, turn.turn_id)
    local existing = vim.fn.bufnr(name)
    local bufnr = existing >= 0 and existing or vim.api.nvim_create_buf(false, true)
    if existing < 0 then
      vim.api.nvim_buf_set_name(bufnr, name)
    end
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = "lazyagent_changes"
    vim.cmd("botright split")
    vim.api.nvim_win_set_buf(0, bufnr)
    vim.wo.number = false
    vim.wo.relativenumber = false
    vim.wo.cursorline = false

    local function current_inline_diffs()
      local key = tostring(turn.turn_id or turn_index)
      inline_by_turn[key] = inline_by_turn[key] or {}
      return inline_by_turn[key]
    end
    local function change_index_at_cursor()
      return line_changes[vim.api.nvim_win_get_cursor(0)[1]]
    end
    local function build_inline_diff(change)
      if change.binary == true then
        return { "Binary change: inline text diff is unavailable." }
      end
      local before, before_err = read_change_side(change, "before")
      local after, after_err = read_change_side(change, "after")
      if before == nil or after == nil then
        return nil, before_err or after_err or "failed to read change blobs"
      end
      local ok, unified = pcall(vim.diff, before, after, {
        result_type = "unified", algorithm = "histogram", ctxlen = 3,
      })
      if not ok then return nil, unified end
      local lines = vim.split(tostring(unified or ""), "\n", { plain = true, trimempty = true })
      if #lines == 0 then return { "No textual difference." } end
      local max_lines = math.max(20, tonumber(opts.inline_diff_max_lines) or 500)
      if #lines > max_lines then
        lines = vim.list_slice(lines, 1, max_lines)
        lines[#lines + 1] = string.format("... inline diff truncated after %d lines ...", max_lines)
      end
      return lines
    end
    local function render()
      local lines
      lines, change_rows, line_changes, line_targets = M.drawer_content(
        thread, turn, turn_index, #turns, current_inline_diffs()
      )
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.bo[bufnr].modifiable = false
      M.apply_drawer_highlights(bufnr, turn, change_rows, line_changes, line_targets)
    end
    render()

    vim.keymap.set("n", "<CR>", function()
      local index = change_index_at_cursor()
      local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
      local change = index and turn.changes[index] or nil
      if change then
        review.open_file(thread, turn, change, line_targets[cursor_line])
      end
    end, { buffer = bufnr, silent = true, desc = "Open LazyAgent ACP changed file" })
    local function toggle_inline(index, force_open)
      index = index or change_index_at_cursor()
      local change = index and turn.changes[index] or nil
      if not change then return end
      local expanded = current_inline_diffs()
      if expanded[index] and not force_open then
        expanded[index] = nil
      elseif not expanded[index] then
        local diff, err = build_inline_diff(change)
        if not diff then
          vim.notify("LazyAgent ACP: failed to build inline diff: " .. tostring(err), vim.log.levels.ERROR)
          return
        end
        expanded[index] = diff
      end
      render()
      vim.api.nvim_win_set_cursor(0, { change_rows[index] or 5, 0 })
      return index
    end
    vim.keymap.set("n", "o", function()
      toggle_inline(change_index_at_cursor(), false)
    end, { buffer = bufnr, silent = true, desc = "Toggle LazyAgent ACP inline diff" })
    vim.keymap.set("n", "i", function()
      local row = vim.api.nvim_win_get_cursor(0)[1]
      local index = change_index_at_cursor()
      if not index then
        for _, change_row in ipairs(change_rows) do
          if change_row > row then
            vim.api.nvim_win_set_cursor(0, { change_row, 0 })
            return
          end
        end
        return
      end
      if not current_inline_diffs()[index] then
        toggle_inline(index, true)
        row = change_rows[index] or row
      end
      for cursor = row + 1, vim.api.nvim_buf_line_count(bufnr) do
        local line = vim.api.nvim_buf_get_lines(bufnr, cursor - 1, cursor, false)[1] or ""
        if line:match("^@@") or change_rows[(line_changes[cursor] or 0)] == cursor then
          vim.api.nvim_win_set_cursor(0, { cursor, 0 })
          return
        end
      end
    end, { buffer = bufnr, silent = true, desc = "Open and jump to next LazyAgent ACP diff" })
    vim.keymap.set("n", "d", function()
      local index = change_index_at_cursor()
      local change = index and turn.changes[index] or nil
      if change then review.open_change(thread, turn, change, index) end
    end, { buffer = bufnr, silent = true, desc = "Open LazyAgent ACP diff tab" })
    vim.keymap.set("n", "=", function()
      toggle_inline(change_index_at_cursor(), false)
    end, { buffer = bufnr, silent = true, desc = "Toggle LazyAgent ACP inline diff" })
    local function annotations_at(row)
      if row == 2 then return ReviewAnnotations.for_turn(turn), "Final answer" end
      local index = line_changes[row]
      local change = index and turn.changes[index] or nil
      if not change then return {}, "Changes note" end
      local line = row ~= change_rows[index] and line_targets[row] or nil
      return ReviewAnnotations.for_change(turn, change, line), display_path(change)
    end
    local function show_annotation()
      local annotations, title = annotations_at(vim.api.nvim_win_get_cursor(0)[1])
      if not open_annotation_float(annotations, title) then
        vim.notify("LazyAgent ACP: no note at cursor", vim.log.levels.INFO)
      end
    end
    vim.keymap.set("n", "K", show_annotation, {
      buffer = bufnr, silent = true, desc = "Show LazyAgent ACP change note",
    })
    vim.keymap.set("n", "<Space><Space>", show_annotation, {
      buffer = bufnr, silent = true, desc = "Show LazyAgent ACP change note",
    })
    local function annotation_rows()
      local rows, seen = {}, {}
      local function add(row, annotations)
        for _, annotation in ipairs(annotations) do
          if not seen[annotation.id] then
            seen[annotation.id] = true
            rows[#rows + 1] = row
          end
        end
      end
      add(2, ReviewAnnotations.for_turn(turn))
      for index, change in ipairs(turn.changes or {}) do
        local matched = false
        for row = 1, vim.api.nvim_buf_line_count(bufnr) do
          local row_index = line_changes[row]
          if row_index == index and row ~= change_rows[index] then
            local notes = ReviewAnnotations.for_change(turn, change, line_targets[row])
            if #notes > 0 then add(row, notes); matched = true end
          end
        end
        if not matched then add(change_rows[index], ReviewAnnotations.for_change(turn, change)) end
      end
      table.sort(rows)
      return rows
    end
    local function jump_annotation(direction)
      local row, rows = vim.api.nvim_win_get_cursor(0)[1], annotation_rows()
      if #rows == 0 then return end
      if direction > 0 then
        for _, target in ipairs(rows) do
          if target > row then vim.api.nvim_win_set_cursor(0, { target, 0 }); return end
        end
        vim.api.nvim_win_set_cursor(0, { rows[1], 0 })
      else
        for index = #rows, 1, -1 do
          if rows[index] < row then vim.api.nvim_win_set_cursor(0, { rows[index], 0 }); return end
        end
        vim.api.nvim_win_set_cursor(0, { rows[#rows], 0 })
      end
    end
    vim.keymap.set("n", "]n", function() jump_annotation(1) end, {
      buffer = bufnr, silent = true, desc = "Next LazyAgent ACP change note",
    })
    vim.keymap.set("n", "[n", function() jump_annotation(-1) end, {
      buffer = bufnr, silent = true, desc = "Previous LazyAgent ACP change note",
    })
    local function refresh(decided_turn)
      if decided_turn then
        turn = decided_turn
        inline_by_turn[tostring(turn.turn_id or turn_index)] = {}
      end
      render()
    end
    local function select_turn(index)
      if not turns[index] then
        return
      end
      turn_index = index
      turn = turns[turn_index]
      refresh()
      vim.api.nvim_win_set_cursor(0, { change_rows[1] or math.min(5, vim.api.nvim_buf_line_count(bufnr)), 0 })
    end
    vim.keymap.set("n", "[t", function()
      select_turn(turn_index - 1)
    end, { buffer = bufnr, silent = true, desc = "Review previous LazyAgent ACP turn" })
    vim.keymap.set("n", "]t", function()
      select_turn(turn_index + 1)
    end, { buffer = bufnr, silent = true, desc = "Review next LazyAgent ACP turn" })
    local function decide(indices, decision)
      if type(opts.decide) ~= "function" then
        return
      end
      if turn.state == "active" then
        vim.notify("LazyAgent ACP: wait for the active turn before applying review decisions", vim.log.levels.INFO)
        return
      end
      local decided, err = opts.decide(thread, turn, indices, decision)
      if not decided then
        vim.notify("LazyAgent ACP: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      refresh(decided)
    end
    local function undecided_indices()
      local indices = {}
      for index, change in ipairs(turn.changes) do
        if not change.decision then
          indices[#indices + 1] = index
        end
      end
      return indices
    end
    vim.keymap.set("n", "a", function()
      local index = change_index_at_cursor()
      if turn.changes[index] and not turn.changes[index].decision then
        decide({ index }, "kept")
      end
    end, { buffer = bufnr, silent = true, desc = "Approve LazyAgent ACP file change" })
    vim.keymap.set("n", "A", function()
      local indices = undecided_indices()
      if #indices > 0 then
        decide(indices, "kept")
      end
    end, { buffer = bufnr, silent = true, desc = "Approve all LazyAgent ACP changes" })
    local function confirm_reject(indices, label)
      vim.ui.select({ "Cancel", "Reject" }, { prompt = label }, function(choice)
        if choice == "Reject" then
          decide(indices, "rejected")
        end
      end)
    end
    vim.keymap.set("n", "r", function()
      local index = change_index_at_cursor()
      if turn.changes[index] and not turn.changes[index].decision then
        confirm_reject({ index }, "Reject this file change?")
      end
    end, { buffer = bufnr, silent = true, desc = "Reject LazyAgent ACP file change" })
    vim.keymap.set("n", "R", function()
      local indices = undecided_indices()
      if #indices > 0 then
        confirm_reject(indices, "Reject all file changes?")
      end
    end, { buffer = bufnr, silent = true, desc = "Reject all LazyAgent ACP changes" })
    vim.keymap.set("n", "h", function()
      local change_index = change_index_at_cursor()
      local change = turn.changes[change_index]
      if not change or change.decision or type(opts.hunks) ~= "function" then
        return
      end
      local hunks, err = opts.hunks(thread, turn, change_index)
      if not hunks then
        vim.notify("LazyAgent ACP: " .. tostring(err), vim.log.levels.INFO)
        return
      end
      vim.ui.select(hunks, {
        prompt = "Select change hunk:",
        format_item = function(hunk)
          local state = hunk.decision and (" [" .. display_decision(hunk.decision) .. "]") or ""
          return string.format(
            "@@ -%d,%d +%d,%d @@%s",
            hunk.before_start,
            hunk.before_count,
            hunk.after_start,
            hunk.after_count,
            state
          )
        end,
      }, function(hunk)
        if not hunk or hunk.decision or type(opts.decide_hunk) ~= "function" then
          return
        end
        vim.ui.select({ "Approve", "Reject", "Cancel" }, { prompt = "Hunk decision:" }, function(choice)
          if choice ~= "Approve" and choice ~= "Reject" then
            return
          end
          local decided, decide_err = opts.decide_hunk(
            thread,
            turn,
            change_index,
            hunk.index,
            choice == "Approve" and "kept" or "rejected"
          )
          if not decided then
            vim.notify("LazyAgent ACP: " .. tostring(decide_err), vim.log.levels.ERROR)
            return
          end
          refresh(decided)
        end)
      end)
    end, { buffer = bufnr, silent = true, desc = "Decide LazyAgent ACP change hunk" })
    local function apply_checkpoint(action)
      if type(opts.checkpoint) ~= "function" then
        return
      end
      local updated, err = opts.checkpoint(thread, turn, action)
      if not updated then
        vim.notify("LazyAgent ACP: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      thread = updated
      vim.notify("LazyAgent ACP checkpoint " .. (action == "redo" and "redone" or "restored"), vim.log.levels.INFO)
    end
    vim.keymap.set("n", "u", function()
      vim.ui.select({ "Cancel", "Restore" }, { prompt = "Restore workspace to before this turn?" }, function(choice)
        if choice == "Restore" then
          apply_checkpoint("restore")
        end
      end)
    end, { buffer = bufnr, silent = true, desc = "Restore LazyAgent ACP checkpoint" })
    vim.keymap.set("n", "U", function()
      apply_checkpoint("redo")
    end, { buffer = bufnr, silent = true, desc = "Redo LazyAgent ACP checkpoint" })
    vim.keymap.set("n", "b", function()
      if type(opts.branch) ~= "function" then
        return
      end
      local branch, err = opts.branch(thread, turn)
      if not branch then
        vim.notify("LazyAgent ACP: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      vim.notify("Created LazyAgent ACP local branch: " .. branch.thread_id, vim.log.levels.INFO)
    end, { buffer = bufnr, silent = true, desc = "Branch LazyAgent ACP checkpoint" })
    vim.keymap.set("n", "?", function()
      local index = change_index_at_cursor()
      local change = index and turn.changes[index] or nil
      local items = {
        { key = "K", description = "Show explanation or review note" },
        { key = "]n", description = "Jump to next note" },
        { key = "[n", description = "Jump to previous note" },
        { key = "i", description = "Open inline diff and jump to next hunk" },
        { key = "o", description = "Toggle inline diff" },
        { key = "<CR>", description = "Open changed file at corresponding line" },
        { key = "d", description = "Open before / after diff tab" },
        { key = "[t", description = "Review previous changed turn" },
        { key = "]t", description = "Review next changed turn" },
        { key = "h", description = "Decide a change hunk" },
        { key = "a", description = "Approve selected file" },
        { key = "A", description = "Approve all files" },
        { key = "r", description = "Reject selected file" },
        { key = "R", description = "Reject all files" },
        { key = "u", description = "Restore checkpoint before this turn" },
        { key = "U", description = "Redo restored checkpoint" },
        { key = "b", description = "Branch from this turn" },
        { key = "q", description = "Close changes drawer" },
      }
      vim.ui.select(items, {
        prompt = change and ("Changes · " .. display_path(change) .. ":") or "Changes actions:",
        kind = "lazyagent-acp-actions",
        format_item = function(item)
          return string.format("%-4s %s", item.key, item.description)
        end,
      }, function(choice)
        if not choice or not vim.api.nvim_buf_is_valid(bufnr) then return end
        local callback
        vim.api.nvim_buf_call(bufnr, function()
          local mapping = vim.fn.maparg(choice.key, "n", false, true)
          callback = type(mapping) == "table" and mapping.callback or nil
        end)
        if type(callback) == "function" then callback() end
      end)
    end, { buffer = bufnr, silent = true, desc = "Open LazyAgent ACP changes action menu" })
    vim.keymap.set("n", "q", function()
      vim.cmd("close")
    end, {
      buffer = bufnr,
      nowait = true,
      silent = true,
      desc = "Close changes drawer",
    })
    local live_group = vim.api.nvim_create_augroup("LazyAgentACPChangesLive" .. tostring(bufnr), { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = live_group,
      pattern = "LazyAgentChangeJournal",
      callback = function(args)
        local data = args.data or {}
        if data.thread_id ~= thread.thread_id or type(opts.get_thread) ~= "function" then return end
        vim.schedule(function()
          if not vim.api.nvim_buf_is_valid(bufnr) then return end
          local updated = opts.get_thread(thread.thread_id)
          if not updated then return end
          local updated_turns = changed_turns(updated)
          if #updated_turns == 0 then return end
          local selected_turn_id = turn and turn.turn_id
          local was_latest = turn_index == #turns
          local next_index
          if was_latest then
            next_index = #updated_turns
          else
            for index, candidate in ipairs(updated_turns) do
              if candidate.turn_id == selected_turn_id then next_index = index; break end
            end
          end
          if not next_index then return end
          local expanded_paths = {}
          for index in pairs(current_inline_diffs()) do
            local change = turn.changes and turn.changes[index]
            if change and change.path then expanded_paths[change.path] = true end
          end
          local windows = vim.fn.win_findbuf(bufnr)
          local row = windows[1] and vim.api.nvim_win_get_cursor(windows[1])[1] or nil
          thread = updated
          turns = updated_turns
          turn_index = next_index
          turn = turns[turn_index]
          local refreshed_inline = {}
          for index, change in ipairs(turn.changes or {}) do
            if expanded_paths[change.path] then
              local diff = build_inline_diff(change)
              if diff then refreshed_inline[index] = diff end
            end
          end
          inline_by_turn[tostring(turn.turn_id or turn_index)] = refreshed_inline
          render()
          if row and windows[1] and vim.api.nvim_win_is_valid(windows[1]) then
            vim.api.nvim_win_set_cursor(windows[1], { math.min(row, vim.api.nvim_buf_line_count(bufnr)), 0 })
          end
        end)
      end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = live_group,
      buffer = bufnr,
      once = true,
      callback = function()
        vim.schedule(function() pcall(vim.api.nvim_del_augroup_by_id, live_group) end)
      end,
    })
    return bufnr
  end

  return review
end

return M

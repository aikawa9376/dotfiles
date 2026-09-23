local M = {}

local util = require("lazyagent.util")
local state = require("lazyagent.logic.state")
local scratch_input = require("lazyagent.scratch_input")
local note_source = require("lazyagent.note_source")

local namespace = vim.api.nvim_create_namespace("LazyAgentNotes")
local entries = {}
local next_id = 1
local list_state = {}
local popup_buf
local popup_win
local popup_passive = false
local editor_contexts = {}
local lifecycle_group
local refresh_pending = {}
local refresh_ticks = {}

local function normalize(path)
  if not path or path == "" then return "" end
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function source_bufnr(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_is_valid(bufnr) then
    local source = vim.b[bufnr].lazyagent_source_bufnr
    if source and vim.api.nvim_buf_is_valid(source) then return source end
  end
  return bufnr
end

local function root_for(bufnr, path, override)
  if override and override ~= "" then return normalize(override) end
  if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == "fugitivestatus" then
    local worktree = vim.b[bufnr].fugitive_work_tree
    if worktree and worktree ~= "" then return normalize(worktree) end
  end
  return normalize(util.git_root_for_path(path) or vim.fn.getcwd())
end

local function context(opts)
  opts = opts or {}
  local bufnr = source_bufnr(opts.source_bufnr or opts.bufnr)
  local path = normalize(opts.path or (vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) or ""))
  local root = root_for(bufnr, path, opts.root)
  local source = vim.api.nvim_buf_is_valid(bufnr) and note_source.capture(bufnr, root) or nil
  return bufnr, path, opts.root and root or (source and source.root or root), source
end

local function position(entry)
  if entry.bufnr and vim.api.nvim_buf_is_valid(entry.bufnr) and entry.mark_id then
    local mark = vim.api.nvim_buf_get_extmark_by_id(entry.bufnr, namespace, entry.mark_id, { details = true })
    if mark and #mark >= 2 then
      local details = mark[3] or {}
      local start_line = mark[1] + 1
      local end_line = tonumber(details.end_row) or mark[1]
      if end_line < start_line then end_line = start_line end
      return start_line, end_line
    end
  end
  return entry.start_line, entry.end_line
end

local function display_path(entry)
  if entry.source then return entry.source.path or entry.source.name end
  local prefix = entry.root ~= "" and (entry.root .. "/") or ""
  if prefix ~= "" and entry.path:sub(1, #prefix) == prefix then
    return entry.path:sub(#prefix + 1)
  end
  return vim.fn.fnamemodify(entry.path, ":~")
end

local function ref_for(entry)
  local reference = note_source.reference(entry.source)
  if entry.source and entry.source.status then return require("lazyagent.note_status").reference(entry.source) end
  local start_line, end_line = position(entry)
  if reference then
    start_line = entry.source.start_line or entry.saved_start_line or entry.start_line
    end_line = entry.source.end_line or entry.saved_end_line or entry.end_line
  end
  local suffix = start_line == end_line and tostring(start_line) or string.format("%d-%d", start_line, end_line)
  return string.format("@%s:%s", reference or display_path(entry), suffix)
end

local function matching(root)
  local result = {}
  for _, entry in pairs(entries) do
    if entry.root == root then result[#result + 1] = entry end
  end
  table.sort(result, function(a, b) return a.id < b.id end)
  return result
end

local function ensure_highlights()
  vim.api.nvim_set_hl(0, "LazyAgentNoteSign", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, "LazyAgentNoteLineNr", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, "LazyAgentNoteRange", { link = "CursorLine", default = true })
  vim.api.nvim_set_hl(0, "LazyAgentNoteText", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "LazyAgentNoteHeader", { link = "Title", default = true })
end

local function visual_options(opts)
  local configured = ((state.opts or {}).notes or {})
  local icon_position = tostring(opts.icon_position or configured.icon_position or "eol"):lower()
  if icon_position == "sign" then icon_position = "gutter" end
  if icon_position ~= "gutter" then icon_position = "eol" end
  local icon = tostring(opts.icon or configured.icon or "󰆉")
  if icon == "" then icon = "󰆉" end
  return icon_position, icon
end

local function create_marks(bufnr, start_line, end_line, opts)
  local anchor = vim.api.nvim_buf_set_extmark(bufnr, namespace, start_line - 1, 0, {
    end_row = end_line,
    end_col = 0,
    right_gravity = false,
    end_right_gravity = false,
  })
  local background = vim.api.nvim_buf_set_extmark(bufnr, namespace, start_line - 1, 0, {
    end_row = end_line - 1,
    end_col = #vim.api.nvim_buf_get_lines(bufnr, end_line - 1, end_line, false)[1],
    right_gravity = false,
    end_right_gravity = false,
    hl_group = "LazyAgentNoteRange",
    number_hl_group = "LazyAgentNoteLineNr",
    hl_eol = true,
    priority = 40,
  })

  local icon_position, icon = visual_options(opts)
  local icon_opts = { right_gravity = false, priority = 100 }
  if icon_position == "gutter" then
    icon_opts.sign_text = icon
    icon_opts.sign_hl_group = "LazyAgentNoteSign"
  else
    icon_opts.virt_text = { { " " .. icon, "LazyAgentNoteSign" } }
    icon_opts.virt_text_pos = "eol"
    icon_opts.hl_mode = "combine"
  end
  local icon_mark = vim.api.nvim_buf_set_extmark(bufnr, namespace, start_line - 1, 0, icon_opts)
  return anchor, background, icon_mark, icon_position
end

local function close_window(winid)
  if winid and vim.api.nvim_win_is_valid(winid) then
    pcall(vim.api.nvim_win_close, winid, true)
  end
end

local function close_popup()
  close_window(popup_win)
  popup_win = nil
  popup_buf = nil
  popup_passive = false
end

local function popup_size(lines, max_height_ratio)
  local max_width = math.max(40, math.floor(vim.o.columns * 0.62))
  local width = 40
  for _, line in ipairs(lines) do
    width = math.max(width, math.min(max_width, vim.fn.strdisplaywidth(line) + 2))
  end
  local max_height = math.max(6, math.floor(vim.o.lines * (max_height_ratio or 0.45)))
  local visual_rows = 0
  for _, line in ipairs(lines) do
    visual_rows = visual_rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / math.max(1, width - 2)))
  end
  return width, math.min(math.max(3, visual_rows), max_height)
end

local function binding_position(bufnr, binding)
  local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, namespace, binding.marks[1], { details = true })
  if #mark < 2 then return end
  return mark[1] + 1, math.max(mark[1] + 1, (mark[3] or {}).end_row or mark[1] + 1)
end

local function bind(entry, bufnr, first, last)
  entry.bindings = entry.bindings or {}
  local existing = entry.bindings[bufnr]
  if existing then
    for i = 1, 3 do pcall(vim.api.nvim_buf_del_extmark, bufnr, namespace, existing.marks[i]) end
  end
  local count = vim.api.nvim_buf_line_count(bufnr)
  first, last = math.max(1, math.min(first, count)), math.max(1, math.min(last, count))
  local marks = { create_marks(bufnr, first, last, { icon_position = entry.icon_position, icon = entry.icon }) }
  entry.bindings[bufnr] = { marks = marks }
  if bufnr == entry.bufnr then
    entry.mark_id, entry.background_mark_id, entry.icon_mark_id = marks[1], marks[2], marks[3]
  end
end

local function entries_in_range(bufnr, first_row, last_row)
  local found = {}
  for _, entry in pairs(entries) do
    local binding = entry.bindings and entry.bindings[bufnr]
    if binding then
      local first, last = binding_position(bufnr, binding)
      if first and first <= last_row and last >= first_row then found[#found + 1] = entry end
    end
  end
  table.sort(found, function(a, b) return a.id < b.id end)
  return found
end

-- Fold summaries read existing marks only; never resolve Git objects during redraw.
function M.fold_chunks(bufnr, first, last)
  local found = entries_in_range(bufnr, first, last)
  if #found == 0 then return {} end
  local icon = found[1].icon or '󰆉'
  return { { ' ' .. icon .. (#found > 1 and (' ' .. #found) or ''), 'LazyAgentNoteSign' } }
end

local function entries_at(bufnr, lnum)
  if bufnr == vim.api.nvim_get_current_buf() then
    local first = vim.fn.foldclosed(lnum)
    if first ~= -1 then return entries_in_range(bufnr, first, vim.fn.foldclosedend(lnum)) end
  end
  return entries_in_range(bufnr, lnum, lnum)
end

-- Reattach only on buffer lifecycle events, never on cursor movement. Git
-- identity is captured once per candidate buffer, and repeated events coalesce.
function M.refresh_buffer(bufnr)
  if not next(entries) or not vim.api.nvim_buf_is_loaded(bufnr) then return end
  local name = vim.api.nvim_buf_get_name(bufnr)
  local path = normalize(name)
  local ft = vim.bo[bufnr].filetype
  local diff = ft == "git" or ft == "fugitive"
  local candidate_source, captured
  for _, entry in pairs(entries) do
    local source = entry.source
    local binding = entry.bindings[bufnr]
    if source and source.custom_commit and vim.b[bufnr].custom_git_commit then
      local first, last = require(package.loaded['features.commit'] and 'features.commit_notes' or 'git.features.commit_notes').range(bufnr, source)
      if first then bind(entry, bufnr, first, last)
      elseif binding then
        for i = 1, 3 do pcall(vim.api.nvim_buf_del_extmark, bufnr, namespace, binding.marks[i]) end
        entry.bindings[bufnr] = nil
      end
    elseif source and source.status then
      local first, last
      local worktree_file = source.path and vim.bo[bufnr].buftype == ""
        and path == normalize(source.root .. "/" .. source.path)
      if worktree_file then
        -- Keep a live file anchor tracking edits; status rows are reconciled separately.
        if not binding or not binding_position(bufnr, binding) then
          first, last = source.start_line or 1, source.end_line or source.start_line or 1
        end
      else
        first, last = require("lazyagent.note_status").range(bufnr, source)
      end
      if first then bind(entry, bufnr, first, last)
      elseif binding and not worktree_file then
        for i = 1, 3 do pcall(vim.api.nvim_buf_del_extmark, bufnr, namespace, binding.marks[i]) end
        entry.bindings[bufnr] = nil
      end
    elseif not binding or not binding_position(bufnr, binding) then
      local first, last
      if not source and path == entry.path then
        first, last = entry.start_line, entry.end_line
        entry.bufnr = bufnr
      elseif source and source.kind ~= "buffer" then
        if diff and source.inline_diff then
          first, last = note_source.diff_range(bufnr, source, entry.excerpt)
        elseif not diff and (name:match("^fugitive://") or name:match("^diffview://")
          or vim.b[bufnr].lazyagent_note_source or path == normalize(source.root .. "/" .. (source.path or ""))) then
          if not captured then
            candidate_source = note_source.capture(bufnr, entry.root)
            captured = true
          end
          if note_source.same(source, candidate_source) or (not candidate_source and not source.blob
            and source.revision == "working-tree" and path == normalize(source.root .. "/" .. (source.path or ""))) then
            first = source.start_line or entry.saved_start_line
            last = source.end_line or entry.saved_end_line
          end
        end
      end
      if first then bind(entry, bufnr, first, last) end
    end
  end
end

local function setup_lifecycle()
  if lifecycle_group then return end
  lifecycle_group = vim.api.nvim_create_augroup("LazyAgentNotesLifecycle", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter", "FileType", "TextChanged" }, {
    group = lifecycle_group,
    callback = function(args)
      if not next(entries) or refresh_pending[args.buf] then return end
      if args.event == "TextChanged" and not vim.tbl_contains({ "git", "fugitive", "fugitivestatus", "fugitivecommit" }, vim.bo[args.buf].filetype) then return end
      refresh_pending[args.buf] = true
      vim.schedule(function()
        refresh_pending[args.buf] = nil
        if not next(entries) or not vim.api.nvim_buf_is_loaded(args.buf) then return end
        local tick = table.concat({ vim.api.nvim_buf_get_changedtick(args.buf), vim.bo[args.buf].filetype, vim.api.nvim_buf_get_name(args.buf) }, ":")
        if refresh_ticks[args.buf] == tick then return end
        refresh_ticks[args.buf] = tick
        M.refresh_buffer(args.buf)
      end)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = lifecycle_group,
    callback = function(args)
      refresh_ticks[args.buf] = nil
      for _, entry in pairs(entries) do
        local binding = entry.bindings[args.buf]
        if binding then
          local first, last = binding_position(args.buf, binding)
          if first and not entry.source then entry.start_line, entry.end_line = first, last end
          local source = entry.source
          if first and source and source.status and source.start_line and source.path
            and vim.bo[args.buf].buftype == ""
            and normalize(vim.api.nvim_buf_get_name(args.buf)) == normalize(source.root .. "/" .. source.path) then
            source.start_line, source.end_line = first, last
          end
          entry.bindings[args.buf] = nil
        end
      end
    end,
  })
end

local function popup_lines(note_entries)
  local lines = {}
  for index, entry in ipairs(note_entries) do
    if index > 1 then vim.list_extend(lines, { "", "---", "" }) end
    lines[#lines + 1] = "## " .. ref_for(entry):sub(2)
    lines[#lines + 1] = ""
    if entry.source then
      lines[#lines + 1] = note_source.describe(entry.source)
      vim.list_extend(lines, { "", "Selected code (captured when noted):", "```" })
      vim.list_extend(lines, entry.excerpt or {})
      vim.list_extend(lines, { "```", "" })
    end
    vim.list_extend(lines, vim.split(entry.text, "\n", { plain = true }))
  end
  return lines
end

local function open_popup(note_entries, opts)
  opts = opts or {}
  close_popup()
  local lines = popup_lines(note_entries)
  popup_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[popup_buf].bufhidden = "wipe"
  vim.bo[popup_buf].buftype = "nofile"
  vim.bo[popup_buf].swapfile = false
  vim.bo[popup_buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(popup_buf, 0, -1, false, lines)
  vim.bo[popup_buf].modifiable = false
  pcall(vim.treesitter.start, popup_buf, "markdown")

  local width, height = popup_size(lines)
  local config = {
    relative = opts.relative or "cursor",
    row = opts.row or 1,
    col = opts.col or 1,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " LazyAgent Notes ",
    title_pos = "left",
    focusable = opts.focus ~= false,
    noautocmd = opts.focus == false,
  }
  local ok, winid = pcall(vim.api.nvim_open_win, popup_buf, opts.focus ~= false, config)
  if not ok or not winid then
    config.relative = "editor"
    config.row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
    config.col = math.max(0, math.floor((vim.o.columns - width) / 2))
    winid = vim.api.nvim_open_win(popup_buf, opts.focus ~= false, config)
  end
  popup_win = winid
  popup_passive = opts.focus == false
  vim.wo[winid].wrap = true
  vim.wo[winid].conceallevel = 2
  if opts.focus ~= false then
    for _, key in ipairs({ "q", "<Esc>" }) do
      vim.keymap.set("n", key, close_popup, {
        buffer = popup_buf,
        silent = true,
        nowait = true,
        desc = "Close LazyAgent Notes preview",
      })
    end
  end
  return true
end

local function setup_hover_preview()
  local group = vim.api.nvim_create_augroup("LazyAgentNotesPreview", { clear = true })
  vim.api.nvim_create_autocmd("CursorHold", {
    group = group,
    callback = function(args)
      if vim.api.nvim_get_mode().mode:sub(1, 1) ~= "n" then return end
      local notes = entries_at(args.buf, vim.api.nvim_win_get_cursor(0)[1])
      if #notes > 0 then open_popup(notes, { focus = false }) end
    end,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "InsertEnter", "BufLeave" }, {
    group = group,
    callback = function()
      if popup_passive then close_popup() end
    end,
  })
end

function M.add(opts)
  opts = opts or {}
  local bufnr, path, root, source = context(opts)
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return nil, "Notes require a loaded buffer"
  end
  local text = vim.trim(tostring(opts.text or ""))
  if text == "" then return nil, "Note text is empty" end

  local line_count = math.max(1, vim.api.nvim_buf_line_count(bufnr))
  local start_line = math.max(1, math.min(tonumber(opts.start_line) or 1, line_count))
  local end_line = math.max(1, math.min(tonumber(opts.end_line) or start_line, line_count))
  if start_line > end_line then start_line, end_line = end_line, start_line end
  source = note_source.capture(bufnr, root, start_line, end_line)
  root = opts.root and root or (source and source.root or root)
  ensure_highlights()

  local mark_id, background_mark_id, icon_mark_id, icon_position = create_marks(
    bufnr,
    start_line,
    end_line,
    opts
  )
  local entry = {
    source = source,
    excerpt = source and vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false) or nil,
    id = next_id,
    bufnr = bufnr,
    path = path,
    root = root,
    start_line = start_line,
    end_line = end_line,
    text = text,
    mark_id = mark_id,
    background_mark_id = background_mark_id,
    icon_mark_id = icon_mark_id,
    icon_position = icon_position,
    icon = select(2, visual_options(opts)),
    saved_start_line = start_line,
    saved_end_line = end_line,
    bindings = { [bufnr] = { marks = { mark_id, background_mark_id, icon_mark_id } } },
  }
  next_id = next_id + 1
  entries[entry.id] = entry
  setup_hover_preview()
  setup_lifecycle()
  refresh_ticks = {}
  if source and source.status and source.path then
    local target = normalize(source.root .. "/" .. source.path)
    for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(candidate) and vim.bo[candidate].buftype == ""
        and normalize(vim.api.nvim_buf_get_name(candidate)) == target then M.refresh_buffer(candidate) end
    end
  end
  return vim.deepcopy(entry)
end

function M.show_at_cursor(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then return false end
  local lnum = opts.lnum or vim.api.nvim_win_get_cursor(0)[1]
  local note_entries = entries_at(bufnr, lnum)
  if #note_entries == 0 then
    if not opts.silent then vim.notify("No LazyAgent Notes on this line", vim.log.levels.INFO) end
    return false
  end
  return open_popup(note_entries, { focus = opts.focus ~= false })
end

function M.show(id)
  local entry = entries[tonumber(id)]
  if not entry then return false end
  return open_popup({ entry }, { focus = true, relative = "editor" })
end

local function open_above(target, line)
  for _, win in ipairs(vim.fn.win_findbuf(target)) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { math.max(1, math.min(line, vim.api.nvim_buf_line_count(target))), 0 })
      M.refresh_buffer(target)
      return true
    end
  end
  local current = vim.api.nvim_get_current_win()
  local top = vim.api.nvim_win_get_position(current)[1]
  local chosen
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    local config = vim.api.nvim_win_get_config(win)
    local row = vim.api.nvim_win_get_position(win)[1]
    if win ~= current and config.relative == "" and row < top
      and not list_state[buf] and not vim.wo[win].diff
      and (vim.bo[buf].buftype == "" or vim.b[buf].lazyagent_note_source) then
      if not chosen or row > vim.api.nvim_win_get_position(chosen)[1] then chosen = win end
    end
  end
  if chosen then
    vim.api.nvim_set_current_win(chosen)
  else
    vim.cmd("aboveleft split")
  end
  vim.api.nvim_win_set_buf(0, target)
  M.refresh_buffer(target)
  vim.api.nvim_win_set_cursor(0, { math.max(1, math.min(line, vim.api.nvim_buf_line_count(target))), 0 })
  return true
end

function M.jump(id, opts)
  opts = opts or {}
  local entry = entries[tonumber(id)]
  if not entry then return false end
  if not entry.source then return util.open_in_normal_win(entry.path, { line = position(entry) }) end
  local source = entry.source
  if source.custom_commit then return require(package.loaded['features.commit'] and 'features.commit_notes' or 'git.features.commit_notes').jump(source) end
  if source.status then return require("lazyagent.note_status").jump(source) end
  local saved_line = source.start_line or entry.saved_start_line
  local ok, jumped = pcall(note_source.jump_diffview, source, saved_line)
  if ok and jumped then return true end
  if not opts.fallback then
    if note_source.reopen_diffview(source, saved_line, function()
      if entries[entry.id] then M.jump(entry.id, { fallback = true }) end
    end) then return true end
    if source.review_commit then
      local review = note_source.fugitive_buffer(source, true)
      if review then
        local row = note_source.diff_range(review, source, entry.excerpt)
        if row then return open_above(review, row) end
      end
    end
  end
  if source.kind == "fugitive" and source.blob then
    local blob = note_source.fugitive_buffer(source, false)
    if blob then return open_above(blob, saved_line) end
  end
  local target = entry.bufnr
  local line = position(entry)
  if not source.inline_diff and target and vim.api.nvim_buf_is_loaded(target) then
    for _, win in ipairs(vim.fn.win_findbuf(target)) do
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_current_win(win)
        vim.api.nvim_win_set_cursor(win, { math.min(line, vim.api.nvim_buf_line_count(target)), 0 })
        return true
      end
    end
    if not source.inline_diff then return open_above(target, line) end
  end
  target = entry.restored_bufnr
  if not target or not vim.api.nvim_buf_is_loaded(target) then
    local restored, lines = pcall(note_source.restore, source)
    if not restored or not lines then return M.show(id) end
    target = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(target, 0, -1, false, lines)
    vim.bo[target].filetype = source.filetype
    vim.bo[target].modifiable = false
    vim.bo[target].readonly = true
    vim.bo[target].bufhidden = "wipe"
    local restored_source = vim.deepcopy(source)
    restored_source.inline_diff = nil
    restored_source.start_line, restored_source.end_line = nil, nil
    vim.b[target].lazyagent_note_source = restored_source
    local last = source.end_line or entry.end_line
    entry.restored_bufnr = target
    bind(entry, target, math.min(saved_line, #lines), math.min(last, #lines))
  end
  return open_above(target, saved_line)
end

function M.submit_editor(bufnr)
  return scratch_input.submit(bufnr)
end

function M.open_editor(opts)
  opts = opts or {}
  local bufnr, path = context(opts)
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    vim.notify("LazyAgentNote: Notes require a loaded buffer", vim.log.levels.ERROR)
    return nil
  end
  local line_count = math.max(1, vim.api.nvim_buf_line_count(bufnr))
  local start_line = math.max(1, math.min(tonumber(opts.start_line) or 1, line_count))
  local end_line = math.max(1, math.min(tonumber(opts.end_line) or start_line, line_count))
  if start_line > end_line then start_line, end_line = end_line, start_line end

  local source_winid = tonumber(opts.source_winid)
  if not source_winid or not vim.api.nvim_win_is_valid(source_winid) then
    source_winid = vim.fn.bufwinid(bufnr)
    if source_winid == -1 then source_winid = vim.api.nvim_get_current_win() end
  end
  local editor_buf, winid
  editor_buf, winid = scratch_input.open({
    source_bufnr = bufnr,
    source_winid = source_winid,
    window_type = opts.window_type,
    window_opts = opts.window_opts,
    is_vertical = opts.is_vertical,
    start_in_insert_on_focus = opts.start_in_insert_on_focus,
    title = " LazyAgent Note ",
    buffer_vars = { lazyagent_note_editor = true },
    empty_message = "Note text is empty",
    error_prefix = "LazyAgentNote: ",
    submit_desc = "Save LazyAgent Note",
    cancel_desc = "Cancel LazyAgent Note",
    on_submit = function(text, input_buf)
      local ctx = editor_contexts[input_buf]
      if not ctx then return nil, "Note editor is no longer valid" end
      local entry, err = M.add(vim.tbl_extend("force", ctx, { text = text }))
      if not entry then return nil, err end
      editor_contexts[input_buf] = nil
      vim.notify(string.format("LazyAgentNote: saved %s:%d", vim.fn.fnamemodify(entry.path, ":t"), entry.start_line))
      return entry
    end,
    on_close = function(_, input_buf) editor_contexts[input_buf] = nil end,
  })
  editor_contexts[editor_buf] = {
    bufnr = bufnr,
    start_line = start_line,
    end_line = end_line,
    root = opts.root,
  }
  return editor_buf, winid
end

function M.count(opts)
  local _, _, root = context(opts)
  return #matching(root)
end

function M.render(opts)
  local _, _, root = context(opts)
  local notes = matching(root)
  if #notes == 0 then return "[No LazyAgent Notes are saved for this workspace.]", {} end

  local lines = {
    "Address these code Notes:",
    "",
  }
  local sources = {}
  for _, entry in ipairs(notes) do if entry.source then sources[#sources + 1] = entry.source end end
  local instructions = note_source.instructions(sources)
  if #instructions > 0 then vim.list_extend(lines, instructions); lines[#lines + 1] = "" end
  local ids = {}
  for index, entry in ipairs(notes) do
    local prefix = string.format("%d. ", index)
    local text = entry.text:gsub("\n", "\n" .. string.rep(" ", #prefix))
    lines[#lines + 1] = prefix .. ref_for(entry) .. " " .. text
    if entry.source and entry.source.status and entry.source.selection and not entry.source.start_line then
      for _, line in ipairs(entry.excerpt or {}) do lines[#lines + 1] = "   > " .. line end
    elseif entry.source and not entry.source.status and not note_source.reference(entry.source) then
      lines[#lines + 1] = "   Reference: " .. note_source.describe(entry.source)
      lines[#lines + 1] = "   This is a review reference; investigate the current code before applying changes."
      lines[#lines + 1] = "   Selected code (captured when noted):"
      for _, line in ipairs(entry.excerpt or {}) do lines[#lines + 1] = "       " .. line end
    end
    ids[#ids + 1] = entry.id
  end
  return table.concat(lines, "\n"), ids
end

function M.remove(id)
  local entry = entries[tonumber(id)]
  if not entry then return false end
  for buf, binding in pairs(entry.bindings) do
    if vim.api.nvim_buf_is_valid(buf) then
      for i = 1, 3 do pcall(vim.api.nvim_buf_del_extmark, buf, namespace, binding.marks[i]) end
    end
  end
  entries[entry.id] = nil
  if not next(entries) then
    if lifecycle_group then vim.api.nvim_del_augroup_by_id(lifecycle_group); lifecycle_group = nil end
    pcall(vim.api.nvim_del_augroup_by_name, "LazyAgentNotesPreview")
    refresh_ticks = {}
  end
  return true
end

function M.consume(ids)
  local removed = 0
  for _, id in ipairs(type(ids) == "table" and ids or {}) do
    if M.remove(id) then removed = removed + 1 end
  end
  return removed
end

function M.consume_meta(meta)
  return M.consume(type(meta) == "table" and meta.note_ids or nil)
end

function M.clear(opts)
  local _, _, root = context(opts)
  local ids = {}
  for _, entry in ipairs(matching(root)) do ids[#ids + 1] = entry.id end
  return M.consume(ids)
end

local function refresh_list(bufnr, root)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local lines = { "# LazyAgent Notes · added order", "", "<CR> open  K preview  d delete  C clear  q close", "" }
  local line_map = {}
  for index, entry in ipairs(matching(root)) do
    local row = #lines + 1
    local summary = entry.text:match("[^\n]*") or ""
    if vim.fn.strdisplaywidth(summary) > 80 then summary = vim.fn.strcharpart(summary, 0, 77) .. "…" end
    if entry.text:find("\n", 1, true) then summary = summary .. " …" end
    lines[#lines + 1] = string.format("%d. %s  %s", index, ref_for(entry):sub(2), summary)
    line_map[row] = entry.id
  end
  if #lines == 4 then lines[#lines + 1] = "No Notes saved for this workspace." end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  list_state[bufnr] = { root = root, line_map = line_map }
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  vim.api.nvim_buf_set_extmark(bufnr, namespace, 0, 0, {
    end_row = 0,
    end_col = #lines[1],
    hl_group = "LazyAgentNoteHeader",
  })
end

function M.open(opts)
  local _, _, root = context(opts)
  vim.cmd("botright split")
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, bufnr)
  vim.api.nvim_buf_set_name(bufnr, "lazyagent://notes/" .. bufnr)
  vim.b[bufnr].lazyagent_note_source = { kind = "buffer", root = root, name = "Notes list" }
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "markdown"
  vim.bo[bufnr].modifiable = false
  vim.api.nvim_win_set_height(0, math.min(12, math.max(6, M.count({ root = root }) + 4)))
  refresh_list(bufnr, root)

  local map_opts = { buffer = bufnr, silent = true, nowait = true }
  vim.keymap.set("n", "q", "<cmd>close<cr>", map_opts)
  vim.keymap.set("n", "<CR>", function()
    local state = list_state[bufnr]
    local entry = state and entries[state.line_map[vim.api.nvim_win_get_cursor(0)[1]]]
    if entry then M.jump(entry.id) end
  end, map_opts)
  vim.keymap.set("n", "d", function()
    local state = list_state[bufnr]
    local id = state and state.line_map[vim.api.nvim_win_get_cursor(0)[1]]
    if id and M.remove(id) then refresh_list(bufnr, root) end
  end, map_opts)
  vim.keymap.set("n", "K", function()
    local state = list_state[bufnr]
    local id = state and state.line_map[vim.api.nvim_win_get_cursor(0)[1]]
    if id then M.show(id) end
  end, map_opts)
  vim.keymap.set("n", "C", function()
    M.clear({ root = root })
    refresh_list(bufnr, root)
  end, map_opts)
  return bufnr
end

-- Resession owns persistence. Never serialize buffer/window/extmark IDs.
local saved_fields = { "path", "root", "text", "excerpt", "icon", "icon_position",
  "start_line", "end_line", "saved_start_line", "saved_end_line" }
local source_fields = { "kind", "root", "path", "revision", "side", "name", "git_dir",
  "custom_commit", "parent_index", "status", "section", "header", "hunk", "selection", "filetype", "blob", "inline_diff", "review_commit", "show", "review_args", "start_line", "end_line" }

local function copy_saved(entry)
  local saved = {}
  for _, key in ipairs(saved_fields) do saved[key] = vim.deepcopy(entry[key]) end
  if entry.source then
    saved.source = {}
    for _, key in ipairs(source_fields) do saved.source[key] = vim.deepcopy(entry.source[key]) end
  end
  return saved
end

function M.snapshot()
  local ordered = vim.tbl_values(entries)
  table.sort(ordered, function(a, b) return a.id < b.id end)
  local result = { version = 1, entries = {} }
  for _, entry in ipairs(ordered) do
    local saved = copy_saved(entry)
    saved.start_line, saved.end_line = position(entry)
    result.entries[#result.entries + 1] = saved
  end
  return result
end

function M.restore(snapshot)
  M._reset()
  if type(snapshot) ~= "table" or snapshot.version ~= 1 or type(snapshot.entries) ~= "table" then return 0 end
  for _, saved in ipairs(snapshot.entries) do
    if type(saved) == "table" and type(saved.text) == "string" and saved.text ~= ""
      and type(saved.root) == "string" and type(saved.path) == "string"
      and type(saved.start_line) == "number" and saved.start_line >= 1
      and type(saved.end_line) == "number" and saved.end_line >= saved.start_line
      and (saved.source == nil or type(saved.source) == "table") then
      local entry = copy_saved(saved)
      entry.id, entry.bindings = next_id, {}
      entry.saved_start_line = entry.saved_start_line or entry.start_line
      entry.saved_end_line = entry.saved_end_line or entry.end_line
      entries[next_id] = entry
      next_id = next_id + 1
    end
  end
  if next(entries) then
    ensure_highlights()
    setup_hover_preview()
    setup_lifecycle()
    refresh_ticks = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) then M.refresh_buffer(buf) end
    end
  end
  return #vim.tbl_keys(entries)
end

function M._reset()
  for id in pairs(entries) do M.remove(id) end
  close_popup()
  for bufnr in pairs(editor_contexts) do
    scratch_input.close(bufnr)
    editor_contexts[bufnr] = nil
  end
  next_id = 1
end

M.namespace = namespace

return M

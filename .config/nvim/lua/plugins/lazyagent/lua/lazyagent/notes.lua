local M = {}

local util = require("lazyagent.util")

local namespace = vim.api.nvim_create_namespace("LazyAgentNotes")
local entries = {}
local next_id = 1
local list_state = {}
local popup_buf
local popup_win
local popup_passive = false
local editor_contexts = {}

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
  return normalize(util.git_root_for_path(path) or vim.fn.getcwd())
end

local function context(opts)
  opts = opts or {}
  local bufnr = source_bufnr(opts.source_bufnr or opts.bufnr)
  local path = normalize(opts.path or (vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) or ""))
  return bufnr, path, root_for(bufnr, path, opts.root)
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
  local prefix = entry.root ~= "" and (entry.root .. "/") or ""
  if prefix ~= "" and entry.path:sub(1, #prefix) == prefix then
    return entry.path:sub(#prefix + 1)
  end
  return vim.fn.fnamemodify(entry.path, ":~")
end

local function ref_for(entry)
  local start_line, end_line = position(entry)
  local suffix = start_line == end_line and tostring(start_line) or string.format("%d-%d", start_line, end_line)
  return string.format("@%s:%s", display_path(entry), suffix)
end

local function matching(root)
  local result = {}
  for _, entry in pairs(entries) do
    if entry.root == root then result[#result + 1] = entry end
  end
  table.sort(result, function(a, b)
    if a.path ~= b.path then return a.path < b.path end
    local a_line = position(a)
    local b_line = position(b)
    if a_line ~= b_line then return a_line < b_line end
    return a.id < b.id
  end)
  return result
end

local function ensure_highlights()
  vim.api.nvim_set_hl(0, "LazyAgentNoteSign", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, "LazyAgentNoteText", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "LazyAgentNoteHeader", { link = "Title", default = true })
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

local function entries_at(bufnr, lnum)
  local path = normalize(vim.api.nvim_buf_get_name(bufnr))
  local found = {}
  for _, entry in pairs(entries) do
    local start_line, end_line = position(entry)
    if entry.path == path and lnum >= start_line and lnum <= end_line then
      found[#found + 1] = entry
    end
  end
  table.sort(found, function(a, b) return a.id < b.id end)
  return found
end

local function popup_lines(note_entries)
  local lines = {}
  for index, entry in ipairs(note_entries) do
    if index > 1 then vim.list_extend(lines, { "", "---", "" }) end
    lines[#lines + 1] = "## " .. ref_for(entry):sub(2)
    lines[#lines + 1] = ""
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
  local bufnr, path, root = context(opts)
  if not vim.api.nvim_buf_is_valid(bufnr) or path == "" or vim.bo[bufnr].buftype ~= "" then
    return nil, "Notes require a named file buffer"
  end
  local text = vim.trim(tostring(opts.text or ""))
  if text == "" then return nil, "Note text is empty" end

  local line_count = math.max(1, vim.api.nvim_buf_line_count(bufnr))
  local start_line = math.max(1, math.min(tonumber(opts.start_line) or 1, line_count))
  local end_line = math.max(1, math.min(tonumber(opts.end_line) or start_line, line_count))
  if start_line > end_line then start_line, end_line = end_line, start_line end
  ensure_highlights()

  local mark_id = vim.api.nvim_buf_set_extmark(bufnr, namespace, start_line - 1, 0, {
    end_row = end_line,
    end_col = 0,
    right_gravity = false,
    end_right_gravity = true,
    sign_text = "󰆉",
    sign_hl_group = "LazyAgentNoteSign",
  })
  local entry = {
    id = next_id,
    bufnr = bufnr,
    path = path,
    root = root,
    start_line = start_line,
    end_line = end_line,
    text = text,
    mark_id = mark_id,
  }
  next_id = next_id + 1
  entries[entry.id] = entry
  setup_hover_preview()
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

function M.submit_editor(bufnr)
  local ctx = editor_contexts[bufnr]
  if not ctx or not vim.api.nvim_buf_is_valid(bufnr) then return nil, "Note editor is no longer valid" end
  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  local entry, err = M.add(vim.tbl_extend("force", ctx, { text = text }))
  if not entry then
    vim.notify("LazyAgentNote: " .. tostring(err), vim.log.levels.ERROR)
    return nil, err
  end
  editor_contexts[bufnr] = nil
  pcall(vim.cmd, "stopinsert")
  local winid = vim.fn.bufwinid(bufnr)
  close_window(winid ~= -1 and winid or nil)
  vim.notify(string.format("LazyAgentNote: saved %s:%d", vim.fn.fnamemodify(entry.path, ":t"), entry.start_line))
  return entry
end

function M.open_editor(opts)
  opts = opts or {}
  local bufnr, path = context(opts)
  if not vim.api.nvim_buf_is_valid(bufnr) or path == "" or vim.bo[bufnr].buftype ~= "" then
    vim.notify("LazyAgentNote: Notes require a named file buffer", vim.log.levels.ERROR)
    return nil
  end
  local line_count = math.max(1, vim.api.nvim_buf_line_count(bufnr))
  local start_line = math.max(1, math.min(tonumber(opts.start_line) or 1, line_count))
  local end_line = math.max(1, math.min(tonumber(opts.end_line) or start_line, line_count))
  if start_line > end_line then start_line, end_line = end_line, start_line end

  local editor_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[editor_buf].bufhidden = "wipe"
  vim.bo[editor_buf].buftype = "nofile"
  vim.bo[editor_buf].swapfile = false
  vim.bo[editor_buf].filetype = "markdown"
  vim.b[editor_buf].lazyagent_note_editor = true
  editor_contexts[editor_buf] = {
    bufnr = bufnr,
    start_line = start_line,
    end_line = end_line,
  }

  local width = math.max(50, math.floor(vim.o.columns * 0.68))
  local height = math.max(8, math.floor(vim.o.lines * 0.42))
  local range = start_line == end_line and tostring(start_line) or string.format("%d-%d", start_line, end_line)
  local title = string.format(" LazyAgent Note · %s:%s ", vim.fn.fnamemodify(path, ":~:."), range)
  local winid = vim.api.nvim_open_win(editor_buf, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = math.min(width, vim.o.columns - 4),
    height = math.min(height, vim.o.lines - 4),
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "left",
    footer = " <C-Space> save · q cancel ",
    footer_pos = "right",
  })
  vim.wo[winid].wrap = true
  vim.wo[winid].linebreak = true

  local function cancel()
    editor_contexts[editor_buf] = nil
    close_window(winid)
  end
  for _, mode in ipairs({ "n", "i" }) do
    vim.keymap.set(mode, "<C-Space>", function() M.submit_editor(editor_buf) end, {
      buffer = editor_buf,
      silent = true,
      desc = "Save LazyAgent Note",
    })
  end
  vim.keymap.set("n", "ZZ", function() M.submit_editor(editor_buf) end, {
    buffer = editor_buf,
    silent = true,
    desc = "Save LazyAgent Note",
  })
  vim.keymap.set("n", "q", cancel, { buffer = editor_buf, silent = true, nowait = true, desc = "Cancel LazyAgent Note" })
  vim.cmd("startinsert")
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
    "Address the following saved code Notes. Investigate and answer questions, and carry out instructions.",
    "",
  }
  local ids = {}
  for _, entry in ipairs(notes) do
    local text = entry.text:gsub("\n", "\n  ")
    lines[#lines + 1] = ref_for(entry) .. " " .. text
    ids[#ids + 1] = entry.id
  end
  return table.concat(lines, "\n"), ids
end

function M.remove(id)
  local entry = entries[tonumber(id)]
  if not entry then return false end
  if entry.bufnr and vim.api.nvim_buf_is_valid(entry.bufnr) and entry.mark_id then
    pcall(vim.api.nvim_buf_del_extmark, entry.bufnr, namespace, entry.mark_id)
  end
  entries[entry.id] = nil
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
  local lines = { "# LazyAgent Notes", "", "<CR> open  K preview  d delete  C clear  q close", "" }
  local line_map = {}
  for _, entry in ipairs(matching(root)) do
    local row = #lines + 1
    local summary = entry.text:match("[^\n]*") or ""
    if vim.fn.strdisplaywidth(summary) > 80 then summary = vim.fn.strcharpart(summary, 0, 77) .. "…" end
    if entry.text:find("\n", 1, true) then summary = summary .. " …" end
    lines[#lines + 1] = string.format("%s  %s", ref_for(entry):sub(2), summary)
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
  vim.api.nvim_buf_set_name(bufnr, "lazyagent://notes")
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
    if entry then util.open_in_normal_win(entry.path, { line = position(entry) }) end
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

function M._reset()
  for id in pairs(entries) do M.remove(id) end
  close_popup()
  for bufnr in pairs(editor_contexts) do
    local winid = vim.fn.bufwinid(bufnr)
    close_window(winid ~= -1 and winid or nil)
    editor_contexts[bufnr] = nil
  end
  next_id = 1
end

M.namespace = namespace

return M

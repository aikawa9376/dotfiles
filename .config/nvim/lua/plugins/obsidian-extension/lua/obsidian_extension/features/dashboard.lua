local M = {}

local context = require("obsidian_extension.context")
local namespace = vim.api.nvim_create_namespace("ObsidianExtensionDashboard")
local state_by_buffer = {}
local config = {}

local defaults = {
  show_aliases = true,
  winbar = false,
  preview_width = 0.45,
  folder_depth = 3,
  pin_field = "dashboard_pin",
  pinned_title = "Pinned notes",
  sections = {
    { title = "Recent notes", dir = "notes", limit = 10, exclude = { "projects", "agent-memory" } },
    { title = "Branch notes", dir = "notes/projects", limit = 8, exclude = { "index.md" } },
    { title = "Daily notes", dir = "daily", limit = 7 },
    { title = "Ideas", dir = "ideas", limit = 5 },
  },
}

local function is_markdown(name)
  return name:sub(-3):lower() == ".md"
end

local function scan_markdown(root, recursive, files)
  local handle = vim.uv.fs_scandir(root)
  if not handle then
    return
  end

  while true do
    local name, kind = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end

    local path = vim.fs.joinpath(root, name)
    if kind == "directory" and recursive then
      scan_markdown(path, recursive, files)
    elseif kind == "file" and is_markdown(name) then
      local stat = vim.uv.fs_stat(path)
      files[#files + 1] = {
        path = path,
        mtime = stat and stat.mtime and stat.mtime.sec or 0,
      }
    end
  end
end

local function is_excluded(relative_path, excluded_paths)
  for _, excluded in ipairs(excluded_paths or {}) do
    excluded = vim.fs.normalize(excluded):gsub("^%./", ""):gsub("/+$", "")
    if
      relative_path == excluded
      or relative_path:sub(1, #excluded + 1) == excluded .. "/"
      or vim.fs.basename(relative_path) == excluded
    then
      return true
    end
  end
  return false
end

local function aliases_for(path)
  local ok, Note = pcall(require, "obsidian.note")
  if not ok then
    return {}
  end

  local note_ok, note = pcall(Note.from_file, path, { max_lines = 100 })
  if not note_ok or type(note.aliases) ~= "table" then
    return {}
  end

  return vim.tbl_map(tostring, note.aliases)
end

local function note_for(path)
  local ok, Note = pcall(require, "obsidian.note")
  if not ok then
    return nil
  end

  local note_ok, note = pcall(Note.from_file, path, { max_lines = 100 })
  return note_ok and note or nil
end

local function is_pinned(path)
  local note = note_for(path)
  return note ~= nil and note:get_field(config.pin_field or defaults.pin_field) == true
end

local function section_root(vault_path, directory)
  local root = vim.fs.normalize(vault_path)
  local candidate = vim.fs.normalize(vim.fs.joinpath(root, directory or ""))
  if candidate ~= root and candidate:sub(1, #root + 1) ~= root .. "/" then
    return nil
  end
  return candidate
end

local function matches_query(file, section, query, aliases)
  query = vim.trim(tostring(query or "")):lower()
  if query == "" then
    return true
  end

  local text = table.concat({
    file.relative_path or "",
    vim.fs.basename(file.relative_path or file.path or ""),
    section.title or "",
    section.dir or "",
    table.concat(aliases or file.aliases or {}, " "),
  }, " "):lower()
  return text:find(query, 1, true) ~= nil
end

local function collect_section(vault_path, section, show_aliases, query, ignored_paths)
  local root = section_root(vault_path, section.dir)
  if not root or not vim.uv.fs_stat(root) then
    return {}, 0, root, 0
  end

  local files = {}
  scan_markdown(root, section.recursive ~= false, files)
  files = vim.tbl_filter(function(file)
    local relative_path = file.path:sub(#root + 2)
    return not is_excluded(relative_path, section.exclude)
      and not (ignored_paths and ignored_paths[vim.fs.normalize(file.path)])
  end, files)
  table.sort(files, function(left, right)
    if left.mtime == right.mtime then
      return left.path < right.path
    end
    return left.mtime > right.mtime
  end)

  local total = #files
  query = vim.trim(tostring(query or ""))
  for _, file in ipairs(files) do
    file.relative_path = file.path:sub(#vim.fs.normalize(vault_path) + 2)
  end
  if query ~= "" then
    files = vim.tbl_filter(function(file)
      local aliases = aliases_for(file.path)
      if show_aliases then
        file.aliases = aliases
      end
      return matches_query(file, section, query, aliases)
    end, files)
  end

  local matched_total = #files
  local limit = math.max(tonumber(section.limit) or total, 0)
  while #files > limit do
    table.remove(files)
  end

  for _, file in ipairs(files) do
    file.aliases = file.aliases or (show_aliases and aliases_for(file.path) or {})
  end

  return files, total, root, matched_total
end

local function collect_pinned(vault_path, show_aliases, query)
  local files = {}
  scan_markdown(vim.fs.normalize(vault_path), true, files)
  files = vim.tbl_filter(function(file)
    return is_pinned(file.path)
  end, files)
  table.sort(files, function(left, right)
    if left.mtime == right.mtime then
      return left.path < right.path
    end
    return left.mtime > right.mtime
  end)

  local section = { title = config.pinned_title or defaults.pinned_title, dir = "" }
  for _, file in ipairs(files) do
    file.relative_path = file.path:sub(#vim.fs.normalize(vault_path) + 2)
    file.aliases = show_aliases and aliases_for(file.path) or {}
  end
  local total = #files
  local paths = {}
  for _, file in ipairs(files) do
    paths[vim.fs.normalize(file.path)] = true
  end
  if vim.trim(tostring(query or "")) ~= "" then
    files = vim.tbl_filter(function(file)
      return matches_query(file, section, query, file.aliases)
    end, files)
  end
  return files, total, paths
end

local function scan_directories(root, current, depth, max_depth, excluded_paths, directories)
  if depth >= max_depth then
    return
  end

  local handle = vim.uv.fs_scandir(current)
  if not handle then
    return
  end

  while true do
    local name, kind = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if kind == "directory" then
      local path = vim.fs.joinpath(current, name)
      local relative_path = path:sub(#root + 2)
      if not is_excluded(relative_path, excluded_paths) then
        directories[#directories + 1] = { path = path, relative_path = relative_path }
        scan_directories(root, path, depth + 1, max_depth, excluded_paths, directories)
      end
    end
  end
end

local function section_directories(vault_path, section)
  local root = section_root(vault_path, section.dir)
  if not root or not vim.uv.fs_stat(root) then
    return {}
  end

  local directories = { { path = root, relative_path = "" } }
  scan_directories(
    root,
    root,
    0,
    tonumber(section.folder_depth) or tonumber(config.folder_depth) or defaults.folder_depth,
    section.exclude,
    directories
  )
  table.sort(directories, function(left, right)
    return left.relative_path < right.relative_path
  end)
  return directories
end

local function format_time(timestamp)
  if os.date("%Y", timestamp) == os.date("%Y") then
    return os.date("%m-%d %H:%M", timestamp)
  end
  return os.date("%Y-%m-%d", timestamp)
end

local function add_line(model, text, highlight, entry)
  model.lines[#model.lines + 1] = text
  local row = #model.lines - 1
  if highlight then
    model.highlights[#model.highlights + 1] = { row = row, start_col = 0, end_col = -1, group = highlight }
  end
  if entry then
    model.entries[#model.lines] = entry
  end
  return row
end

local function add_span(model, row, start_col, end_col, group)
  model.highlights[#model.highlights + 1] = {
    row = row,
    start_col = start_col,
    end_col = end_col,
    group = group,
  }
end

local function build_model(vault_path, query)
  local model = { lines = {}, highlights = {}, entries = {}, section_headers = {} }
  local unique = {}
  local updated_today = 0
  local today = os.date("%Y-%m-%d")

  query = vim.trim(tostring(query or ""))
  add_line(model, "OBSIDIAN STATUS", "Title")
  add_line(model, "Vault  " .. vault_path, "Directory")
  if query ~= "" then
    add_line(model, "Filter " .. query, "String")
  end
  add_line(model, "")

  local pinned, pinned_total, pinned_paths = collect_pinned(vault_path, config.show_aliases, query)

  local function add_note(file, pinned_note)
    if not unique[file.path] then
      unique[file.path] = true
      if os.date("%Y-%m-%d", file.mtime) == today then
        updated_today = updated_today + 1
      end
    end

    local stamp = format_time(file.mtime)
    local icon = pinned_note and "󰐃 " or " "
    local prefix = "  " .. stamp .. "  " .. icon
    local aliases = #file.aliases > 0 and " [" .. table.concat(file.aliases, ", ") .. "]" or ""
    local row = add_line(model, prefix .. file.relative_path .. aliases, nil, file)
    local file_name = vim.fs.basename(file.relative_path)
    local file_name_start = #prefix + #file.relative_path - #file_name
    add_span(model, row, 2, 2 + #stamp, "Comment")
    add_span(model, row, file_name_start, file_name_start + #file_name, "Directory")
    if aliases ~= "" then
      add_span(model, row, #prefix + #file.relative_path, -1, "String")
    end
  end

  if pinned_total > 0 then
    local count = #pinned
    local label = query ~= "" and ("%d/%d"):format(count, pinned_total) or tostring(pinned_total)
    add_line(model, ("%-18s (%s)"):format((config.pinned_title or defaults.pinned_title):upper(), label), "Title")
    if #pinned == 0 then
      add_line(model, "  (no matches)", "Comment")
    else
      for _, file in ipairs(pinned) do
        add_note(file, true)
      end
    end
    add_line(model, "")
  end

  for _, section in ipairs(config.sections or {}) do
    local files, total, root, matched_total = collect_section(
      vault_path,
      section,
      config.show_aliases,
      query,
      pinned_paths
    )
    local title = (section.title or section.dir or "Notes"):upper()
    local count = query ~= "" and ("%d/%d"):format(matched_total, total) or tostring(total)
    local header_row = add_line(model, ("%-18s %s/  (%s)"):format(title, section.dir or "", count), "Title")
    model.section_headers[header_row + 1] = section

    if not root or not vim.uv.fs_stat(root) then
      add_line(model, "  (directory not found)", "DiagnosticWarn")
    elseif #files == 0 then
      add_line(model, query ~= "" and "  (no matches)" or "  (no notes)", "Comment")
    else
      for _, file in ipairs(files) do
        add_note(file, false)
      end
    end
    add_line(model, "")
  end

  add_line(model, ("Visible %d notes  ·  updated today %d"):format(vim.tbl_count(unique), updated_today), "DiagnosticInfo")
  add_line(
    model,
    "<CR> open   P preview   a add   p pin   r rename   x delete   [[/]] sections   R refresh   t today   gb knowledge   / filter   ? actions   q close",
    "Comment"
  )
  return model
end

local function section_target(section_headers, current_row, direction, count)
  local rows = vim.tbl_keys(section_headers or {})
  table.sort(rows)

  local target
  local row = current_row
  for _ = 1, math.max(tonumber(count) or 1, 1) do
    local candidate
    if direction > 0 then
      for _, section_row in ipairs(rows) do
        if section_row > row then
          candidate = section_row
          break
        end
      end
    else
      for index = #rows, 1, -1 do
        if rows[index] < row then
          candidate = rows[index]
          break
        end
      end
    end

    if not candidate then
      break
    end
    target = candidate
    row = candidate
  end

  return target
end

local function render(bufnr, vault_path)
  local state = state_by_buffer[bufnr] or {}
  local model = build_model(vault_path, state.query)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, model.lines)
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  for _, highlight in ipairs(model.highlights) do
    vim.api.nvim_buf_add_highlight(
      bufnr,
      namespace,
      highlight.group,
      highlight.row,
      highlight.start_col,
      highlight.end_col
    )
  end
  vim.bo[bufnr].modifiable = false
  state.entries = model.entries
  state.section_headers = model.section_headers
  state.vault_path = vault_path
  state_by_buffer[bufnr] = state
end

local function release_preview_buffer(state, promote_path)
  local preview_bufnr = state and state.preview_bufnr
  if preview_bufnr and vim.api.nvim_buf_is_valid(preview_bufnr) then
    local promote = promote_path
      and vim.fs.normalize(vim.api.nvim_buf_get_name(preview_bufnr)) == vim.fs.normalize(promote_path)
    vim.bo[preview_bufnr].buflisted = promote == true or state.preview_was_listed == true
    if state.preview_created then
      state.opened_buffers = state.opened_buffers or {}
      state.opened_buffers[preview_bufnr] = true
    end
  end
  if state then
    state.preview_bufnr = nil
    state.preview_created = nil
    state.preview_was_listed = nil
  end
end

local function close_preview(state, promote_path)
  if state and state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) then
    vim.api.nvim_win_close(state.preview_win, true)
  end
  release_preview_buffer(state, promote_path)
  if state then
    state.preview_win = nil
    state.preview_path = nil
  end
end

local function preview_buffer(state, path)
  release_preview_buffer(state)
  local existing = vim.fn.bufnr(path)
  local was_listed = existing >= 0 and vim.fn.buflisted(existing) == 1
  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)
  vim.bo[bufnr].buflisted = false
  state.preview_bufnr = bufnr
  state.preview_created = existing < 0
  state.preview_was_listed = was_listed
  return bufnr
end

local function update_preview(state, entry)
  if not state or not entry or state.preview_path == entry.path then
    return
  end
  if not state.preview_win or not vim.api.nvim_win_is_valid(state.preview_win) then
    return
  end

  vim.api.nvim_win_set_buf(state.preview_win, preview_buffer(state, entry.path))
  state.preview_path = entry.path
end

local function follow_preview(bufnr)
  local state = state_by_buffer[bufnr]
  if not state or not state.preview_win or not vim.api.nvim_win_is_valid(state.preview_win) then
    return
  end

  update_preview(state, state.entries[vim.api.nvim_win_get_cursor(0)[1]])
end

local function filter_dashboard()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = state_by_buffer[bufnr]
  if not state then
    return
  end

  vim.ui.input({ prompt = "Filter Obsidian dashboard: ", default = state.query or "" }, function(value)
    if value == nil or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    local selected = state.entries[vim.api.nvim_win_get_cursor(0)[1]]
    state.query = vim.trim(value)
    render(bufnr, state.vault_path)
    local rows = vim.tbl_keys(state.entries)
    table.sort(rows)
    local target = rows[1]
    if selected then
      for _, row in ipairs(rows) do
        if state.entries[row].path == selected.path then
          target = row
          break
        end
      end
    end
    if target and vim.api.nvim_get_current_buf() == bufnr then
      vim.api.nvim_win_set_cursor(0, { target, 0 })
      follow_preview(bufnr)
    end
  end)
end

local function open_entry()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = state_by_buffer[bufnr]
  local entry = state and state.entries[vim.api.nvim_win_get_cursor(0)[1]]
  if entry then
    local entry_bufnr = vim.fn.bufnr(entry.path)
    local opened_by_dashboard = entry_bufnr < 0
      or (entry_bufnr == state.preview_bufnr and state.preview_created == true)
    close_preview(state, entry.path)
    entry_bufnr = vim.fn.bufnr(entry.path)
    if entry_bufnr >= 0 then
      vim.bo[entry_bufnr].buflisted = true
    end
    vim.cmd.edit(vim.fn.fnameescape(entry.path))
    if opened_by_dashboard then
      state.opened_buffers = state.opened_buffers or {}
      state.opened_buffers[vim.api.nvim_get_current_buf()] = true
    end
  end
end

local function toggle_preview()
  local dashboard_win = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = state_by_buffer[bufnr]
  local entry = state and state.entries[vim.api.nvim_win_get_cursor(dashboard_win)[1]]
  if not entry then
    vim.notify("Move the cursor onto a note to preview it", vim.log.levels.INFO)
    return
  end

  if state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) then
    if state.preview_path == entry.path then
      close_preview(state)
      return
    end
    update_preview(state, entry)
    return
  end

  local preview_bufnr = preview_buffer(state, entry.path)
  vim.cmd("botright vsplit")
  state.preview_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.preview_win, preview_bufnr)
  state.preview_path = entry.path
  vim.wo[state.preview_win].previewwindow = true
  local width = config.preview_width
  if type(width) == "number" and width > 0 then
    local columns = width < 1 and math.floor(vim.o.columns * width) or math.floor(width)
    vim.api.nvim_win_set_width(state.preview_win, math.max(columns, 20))
  end
  vim.api.nvim_set_current_win(dashboard_win)
end

local function valid_note_name(name)
  name = vim.trim(name or ""):gsub("%.md$", "")
  if name == "" or name == "." or name == ".." or name:find("[/\\]") then
    return nil
  end
  return name
end

local function refresh_after_change(bufnr, row)
  local state = state_by_buffer[bufnr]
  if not state or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  render(bufnr, state.vault_path)
  if vim.api.nvim_get_current_buf() == bufnr then
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    vim.api.nvim_win_set_cursor(0, { math.min(row or 1, line_count), 0 })
    follow_preview(bufnr)
  end
end

local function write_pin(path, pinned)
  local existing = vim.fn.bufnr(path)
  if existing >= 0 and vim.api.nvim_buf_is_valid(existing) and vim.bo[existing].modified then
    return nil, "Save or discard the note's changes before changing its pin"
  end

  local note = note_for(path)
  if not note then
    return nil, "Could not read note frontmatter"
  end

  note:add_field(config.pin_field or defaults.pin_field, pinned and true or nil)
  local ok, err = pcall(function()
    if existing >= 0 and vim.api.nvim_buf_is_valid(existing) then
      note:save_to_buffer({ bufnr = existing })
      vim.api.nvim_buf_call(existing, function()
        vim.cmd("silent write")
      end)
    else
      note:save()
    end
  end)
  if not ok then
    return nil, tostring(err)
  end
  return true
end

local function toggle_pin()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = state_by_buffer[bufnr]
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local entry = state and state.entries[row]
  if not entry then
    vim.notify("Move the cursor onto a note to pin it", vim.log.levels.INFO)
    return
  end

  local pinned = is_pinned(entry.path)
  close_preview(state)
  local ok, err = write_pin(entry.path, not pinned)
  if not ok then
    vim.notify("Could not update pin: " .. err, vim.log.levels.ERROR)
    return
  end
  refresh_after_change(bufnr, row)
  vim.notify((pinned and "Unpinned " or "Pinned ") .. entry.relative_path, vim.log.levels.INFO)
end

local function delete_entry()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = state_by_buffer[bufnr]
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local entry = state and state.entries[row]
  if not entry then
    vim.notify("Move the cursor onto a note to delete it", vim.log.levels.INFO)
    return
  end

  local existing = vim.fn.bufnr(entry.path)
  if existing >= 0 and vim.api.nvim_buf_is_valid(existing) and vim.bo[existing].modified then
    vim.notify("Save or discard the note's changes before deleting it", vim.log.levels.WARN)
    return
  end
  if vim.fn.confirm("Delete " .. entry.relative_path .. "?", "&Delete\n&Cancel", 2) ~= 1 then
    return
  end

  close_preview(state)
  if existing >= 0 and vim.api.nvim_buf_is_valid(existing) then
    local buffer_ok, buffer_err = pcall(vim.api.nvim_buf_delete, existing, {})
    if not buffer_ok then
      vim.notify("Could not close note buffer: " .. tostring(buffer_err), vim.log.levels.ERROR)
      return
    end
  end
  local deleted, delete_err = vim.uv.fs_unlink(entry.path)
  if not deleted then
    vim.notify("Could not delete note: " .. tostring(delete_err), vim.log.levels.ERROR)
    return
  end

  refresh_after_change(bufnr, row)
  vim.notify("Deleted " .. entry.relative_path, vim.log.levels.INFO)
end

local function rename_entry()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = state_by_buffer[bufnr]
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local entry = state and state.entries[row]
  if not entry then
    vim.notify("Move the cursor onto a note to rename it", vim.log.levels.INFO)
    return
  end

  local current_name = vim.fs.basename(entry.path):gsub("%.md$", "")
  vim.ui.input({ prompt = "Rename note: ", default = current_name }, function(value)
    if value == nil or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local new_name = valid_note_name(value)
    if not new_name then
      vim.notify("Enter a filename without path separators", vim.log.levels.WARN)
      return
    end

    close_preview(state)
    local existing = vim.fn.bufnr(entry.path)
    local opened_by_dashboard = existing < 0
    vim.cmd.edit(vim.fn.fnameescape(entry.path))
    local renamed_bufnr = vim.api.nvim_get_current_buf()
    local ok, err = pcall(vim.api.nvim_cmd, { cmd = "ObsidianRename", args = { new_name } }, {})
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_set_current_buf(bufnr)
    end
    if opened_by_dashboard and vim.api.nvim_buf_is_valid(renamed_bufnr) then
      state.opened_buffers = state.opened_buffers or {}
      state.opened_buffers[renamed_bufnr] = true
    end
    if not ok then
      vim.notify("Could not rename note: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    refresh_after_change(bufnr, row)
  end)
end

local function create_note(vault_path, directory, name)
  name = valid_note_name(name)
  if not name then
    vim.notify("Enter a filename without path separators", vim.log.levels.WARN)
    return
  end

  local path = vim.fs.joinpath(directory.path, name .. ".md")
  if vim.uv.fs_stat(path) then
    vim.notify("Note already exists: " .. path:sub(#vault_path + 2), vim.log.levels.INFO)
    vim.cmd.edit(vim.fn.fnameescape(path))
    return
  end

  local client = require("obsidian").get_client()
  local relative_dir = directory.path:sub(#vault_path + 2)
  local note = client:create_note({
    title = name,
    id = name,
    dir = relative_dir,
    no_write = true,
  })
  client:open_note(note, { sync = true })
  client:write_note_to_buffer(note)

  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  if not vim.tbl_contains(lines, "# " .. name) then
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { "", "# " .. name, "" })
  end
end

local function add_note()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = state_by_buffer[bufnr]
  if not state then
    return
  end

  local function ask_name(directory)
    if not directory then
      return
    end
    vim.ui.input({ prompt = "New note name: " }, function(name)
      if name ~= nil then
        close_preview(state)
        create_note(state.vault_path, directory, name)
      end
    end)
  end

  local row = vim.api.nvim_win_get_cursor(0)[1]
  local entry = state.entries[row]
  if entry then
    local directory_path = vim.fs.dirname(entry.path)
    ask_name({
      path = directory_path,
      relative_path = directory_path:sub(#state.vault_path + 2),
    })
    return
  end

  local section = state.section_headers[row]
  if not section then
    vim.notify("Use a on a note or section heading", vim.log.levels.INFO)
    return
  end

  local directories = section_directories(state.vault_path, section)
  if #directories == 0 then
    vim.notify("Dashboard section directory does not exist", vim.log.levels.WARN)
    return
  end

  if #directories == 1 then
    ask_name(directories[1])
    return
  end

  vim.ui.select(directories, {
    prompt = "Add note to " .. (section.title or section.dir or "section"),
    format_item = function(directory)
      local suffix = directory.relative_path ~= "" and "/" .. directory.relative_path or ""
      return (section.dir or "") .. suffix .. "/"
    end,
  }, ask_name)
end

local function cleanup_opened_buffers(opened_buffers)
  local kept = {}
  for bufnr in pairs(opened_buffers or {}) do
    if
      vim.api.nvim_buf_is_valid(bufnr)
      and (vim.bo[bufnr].modified or #vim.fn.win_findbuf(bufnr) > 0)
    then
      kept[bufnr] = true
    elseif vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, {})
    end
  end
  return kept
end

local function cleanup_session(bufnr)
  local state = state_by_buffer[bufnr]
  if not state then
    return
  end

  close_preview(state)
  state.opened_buffers = cleanup_opened_buffers(state.opened_buffers)
  if vim.api.nvim_buf_is_valid(bufnr) and #vim.fn.win_findbuf(bufnr) == 0 then
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
  state_by_buffer[bufnr] = nil
end

local function cleanup_closed_tabs()
  local closed = {}
  for bufnr, state in pairs(state_by_buffer) do
    if state.tabpage and not vim.api.nvim_tabpage_is_valid(state.tabpage) then
      closed[#closed + 1] = bufnr
    end
  end
  for _, bufnr in ipairs(closed) do
    cleanup_session(bufnr)
  end
end

local function session_buffer(bufnr)
  if bufnr and state_by_buffer[bufnr] then
    return bufnr
  end

  local current_tabpage = vim.api.nvim_get_current_tabpage()
  local fallback
  for candidate, state in pairs(state_by_buffer) do
    if state.tabpage and vim.api.nvim_tabpage_is_valid(state.tabpage) then
      if state.tabpage == current_tabpage then
        return candidate
      end
      fallback = fallback or candidate
    end
  end
  return fallback
end

local function is_open()
  return session_buffer() ~= nil
end

local function close_dashboard(bufnr)
  bufnr = session_buffer(bufnr)
  if not bufnr then
    return
  end
  local state = state_by_buffer[bufnr]
  if
    state
    and state.tabpage
    and vim.api.nvim_tabpage_is_valid(state.tabpage)
    and #vim.api.nvim_list_tabpages() > 1
  then
    vim.api.nvim_set_current_tabpage(state.tabpage)
    vim.cmd.tabclose()
    return
  end
  cleanup_session(bufnr)
end

local function move_section(direction)
  local bufnr = vim.api.nvim_get_current_buf()
  local state = state_by_buffer[bufnr]
  if not state then
    return
  end

  local current_row = vim.api.nvim_win_get_cursor(0)[1]
  local target = section_target(state.section_headers, current_row, direction, vim.v.count1)
  if target then
    vim.api.nvim_win_set_cursor(0, { target, 0 })
  end
end

local function configure_buffer(bufnr, vault_path)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].undofile = false
  vim.bo[bufnr].filetype = "obsidian-dashboard"
  vim.bo[bufnr].modifiable = false

  vim.keymap.set("n", "<CR>", open_entry, { buffer = bufnr, silent = true, desc = "Open dashboard note" })
  vim.keymap.set("n", "P", toggle_preview, { buffer = bufnr, silent = true, desc = "Toggle note preview" })
  vim.keymap.set("n", "a", add_note, { buffer = bufnr, silent = true, desc = "Add a note to this section" })
  vim.keymap.set("n", "p", toggle_pin, { buffer = bufnr, silent = true, desc = "Toggle dashboard note pin" })
  vim.keymap.set("n", "r", rename_entry, { buffer = bufnr, silent = true, desc = "Rename dashboard note" })
  vim.keymap.set("n", "x", delete_entry, { buffer = bufnr, silent = true, desc = "Delete dashboard note" })
  vim.keymap.set("n", "]]", function()
    move_section(1)
  end, { buffer = bufnr, silent = true, desc = "Go to next dashboard section" })
  vim.keymap.set("n", "[[", function()
    move_section(-1)
  end, { buffer = bufnr, silent = true, desc = "Go to previous dashboard section" })
  vim.keymap.set("n", "R", function()
    render(bufnr, vault_path)
  end, { buffer = bufnr, silent = true, desc = "Refresh Obsidian dashboard" })
  vim.keymap.set("n", "t", "<Cmd>ObsidianToday<CR>", { buffer = bufnr, silent = true, desc = "Open today's note" })
  vim.keymap.set("n", "gb", "<Cmd>ObsidianKnowledgeBase<CR>", { buffer = bufnr, silent = true, desc = "Open Knowledge Base" })
  vim.keymap.set("n", "/", filter_dashboard, { buffer = bufnr, silent = true, desc = "Filter dashboard notes" })
  vim.keymap.set("n", "?", "<Cmd>ObsidianMenu<CR>", { buffer = bufnr, silent = true, desc = "Open Obsidian actions" })
  vim.keymap.set("n", "q", close_dashboard, { buffer = bufnr, silent = true, nowait = true, desc = "Close dashboard" })

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      close_preview(state_by_buffer[bufnr])
      state_by_buffer[bufnr] = nil
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = bufnr,
    callback = function()
      follow_preview(bufnr)
    end,
  })
end

local function configure_window(winid)
  if config.winbar == true then
    vim.wo[winid].winbar = "%#Title# OBSIDIAN %*· Vault status"
  elseif type(config.winbar) == "string" then
    vim.wo[winid].winbar = config.winbar
  end
end

local function show_in_tab(bufnr)
  for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
      if vim.api.nvim_win_get_buf(winid) == bufnr then
        vim.api.nvim_set_current_tabpage(tabpage)
        vim.api.nvim_set_current_win(winid)
        return winid
      end
    end
  end

  vim.cmd.tabnew()
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)
  return winid
end

local function register_session(bufnr)
  local state = state_by_buffer[bufnr] or {}
  state.tabpage = vim.api.nvim_get_current_tabpage()
  state.opened_buffers = state.opened_buffers or {}
  state_by_buffer[bufnr] = state
  return state
end

local function open_dashboard()
  local vault_path = context.vault_path()
  if not vault_path then
    vim.notify("Could not resolve the current Obsidian vault", vim.log.levels.ERROR)
    return
  end

  local name = "obsidian-dashboard://" .. vault_path
  local bufnr
  for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(candidate) and vim.api.nvim_buf_get_name(candidate) == name then
      bufnr = candidate
      break
    end
  end

  if not bufnr then
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, name)
    configure_buffer(bufnr, vault_path)
  end

  local winid = show_in_tab(bufnr)
  configure_window(winid)
  render(bufnr, vault_path)
  register_session(bufnr)
  return bufnr
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  local group = vim.api.nvim_create_augroup("ObsidianExtensionDashboard", { clear = true })
  vim.api.nvim_create_autocmd("TabClosed", {
    group = group,
    callback = function()
      vim.schedule(cleanup_closed_tabs)
    end,
  })
  vim.api.nvim_create_user_command("ObsidianDashboard", open_dashboard, {
    desc = "Open the Obsidian vault status dashboard",
  })
end

M.open = open_dashboard
M.close = close_dashboard
M.is_open = is_open
M.refresh = render
M._collect_section = collect_section
M._collect_pinned = collect_pinned
M._section_directories = section_directories
M._build_model = build_model
M._configure_window = configure_window
M._cleanup_opened_buffers = cleanup_opened_buffers
M._release_preview_buffer = release_preview_buffer
M._register_session = register_session
M._show_in_tab = show_in_tab
M._format_time = format_time
M._matches_query = matches_query
M._section_target = section_target
M._valid_note_name = valid_note_name
M._write_pin = write_pin

return M

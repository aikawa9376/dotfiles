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
  sections = {
    { title = "Recent notes", dir = "notes", limit = 10, exclude = { "projects" } },
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

local function section_root(vault_path, directory)
  local root = vim.fs.normalize(vault_path)
  local candidate = vim.fs.normalize(vim.fs.joinpath(root, directory or ""))
  if candidate ~= root and candidate:sub(1, #root + 1) ~= root .. "/" then
    return nil
  end
  return candidate
end

local function collect_section(vault_path, section, show_aliases)
  local root = section_root(vault_path, section.dir)
  if not root or not vim.uv.fs_stat(root) then
    return {}, 0, root
  end

  local files = {}
  scan_markdown(root, section.recursive ~= false, files)
  files = vim.tbl_filter(function(file)
    local relative_path = file.path:sub(#root + 2)
    return not is_excluded(relative_path, section.exclude)
  end, files)
  table.sort(files, function(left, right)
    if left.mtime == right.mtime then
      return left.path < right.path
    end
    return left.mtime > right.mtime
  end)

  local total = #files
  local limit = math.max(tonumber(section.limit) or total, 0)
  while #files > limit do
    table.remove(files)
  end

  for _, file in ipairs(files) do
    file.relative_path = file.path:sub(#vim.fs.normalize(vault_path) + 2)
    file.aliases = show_aliases and aliases_for(file.path) or {}
  end

  return files, total, root
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

local function build_model(vault_path)
  local model = { lines = {}, highlights = {}, entries = {}, section_headers = {} }
  local unique = {}
  local updated_today = 0
  local today = os.date("%Y-%m-%d")

  add_line(model, "OBSIDIAN STATUS", "Title")
  add_line(model, "Vault  " .. vault_path, "Directory")
  add_line(model, "")

  for _, section in ipairs(config.sections or {}) do
    local files, total, root = collect_section(vault_path, section, config.show_aliases)
    local title = (section.title or section.dir or "Notes"):upper()
    local header_row = add_line(model, ("%-18s %s/  (%d)"):format(title, section.dir or "", total), "Title")
    model.section_headers[header_row + 1] = section

    if not root or not vim.uv.fs_stat(root) then
      add_line(model, "  (directory not found)", "DiagnosticWarn")
    elseif #files == 0 then
      add_line(model, "  (no notes)", "Comment")
    else
      for _, file in ipairs(files) do
        if not unique[file.path] then
          unique[file.path] = true
          if os.date("%Y-%m-%d", file.mtime) == today then
            updated_today = updated_today + 1
          end
        end

        local stamp = format_time(file.mtime)
        local prefix = "  " .. stamp .. "   "
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
    end
    add_line(model, "")
  end

  add_line(model, ("Visible %d notes  ·  updated today %d"):format(vim.tbl_count(unique), updated_today), "DiagnosticInfo")
  add_line(
    model,
    "<CR> open   P preview   a add   R refresh   t today   gb knowledge   / search   ? actions   q close",
    "Comment"
  )
  return model
end

local function render(bufnr, vault_path)
  local model = build_model(vault_path)
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
  local state = state_by_buffer[bufnr] or {}
  state.entries = model.entries
  state.section_headers = model.section_headers
  state.vault_path = vault_path
  state_by_buffer[bufnr] = state
end

local function open_entry()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = state_by_buffer[bufnr]
  local entry = state and state.entries[vim.api.nvim_win_get_cursor(0)[1]]
  if entry then
    if state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) then
      vim.api.nvim_win_close(state.preview_win, true)
    end
    vim.cmd.edit(vim.fn.fnameescape(entry.path))
  end
end

local function close_preview(state)
  if state and state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) then
    vim.api.nvim_win_close(state.preview_win, true)
  end
  if state then
    state.preview_win = nil
    state.preview_path = nil
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
    local preview_bufnr = vim.fn.bufadd(entry.path)
    vim.fn.bufload(preview_bufnr)
    vim.api.nvim_win_set_buf(state.preview_win, preview_bufnr)
    state.preview_path = entry.path
    return
  end

  vim.cmd("botright vsplit " .. vim.fn.fnameescape(entry.path))
  state.preview_win = vim.api.nvim_get_current_win()
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

local function close_dashboard()
  local bufnr = vim.api.nvim_get_current_buf()
  close_preview(state_by_buffer[bufnr])
  vim.cmd("silent! bdelete")
  state_by_buffer[bufnr] = nil
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
  vim.keymap.set("n", "R", function()
    render(bufnr, vault_path)
  end, { buffer = bufnr, silent = true, desc = "Refresh Obsidian dashboard" })
  vim.keymap.set("n", "t", "<Cmd>ObsidianToday<CR>", { buffer = bufnr, silent = true, desc = "Open today's note" })
  vim.keymap.set("n", "gb", "<Cmd>ObsidianKnowledgeBase<CR>", { buffer = bufnr, silent = true, desc = "Open Knowledge Base" })
  vim.keymap.set("n", "/", "<Cmd>ObsidianSearch<CR>", { buffer = bufnr, silent = true, desc = "Search the vault" })
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

  vim.api.nvim_win_set_buf(0, bufnr)
  vim.wo.cursorline = true
  vim.wo.foldcolumn = "0"
  vim.wo.number = false
  vim.wo.relativenumber = false
  vim.wo.signcolumn = "no"
  vim.wo.spell = false
  vim.wo.wrap = false
  if config.winbar == true then
    vim.wo.winbar = "%#Title# OBSIDIAN %*· Vault status"
  elseif type(config.winbar) == "string" then
    vim.wo.winbar = config.winbar
  else
    vim.wo.winbar = ""
  end
  render(bufnr, vault_path)
  return bufnr
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  vim.api.nvim_create_user_command("ObsidianDashboard", open_dashboard, {
    desc = "Open the Obsidian vault status dashboard",
  })
end

M.open = open_dashboard
M.refresh = render
M._collect_section = collect_section
M._section_directories = section_directories
M._build_model = build_model
M._format_time = format_time
M._valid_note_name = valid_note_name

return M

local M = {}

local sidebar_width = 36
local group = vim.api.nvim_create_augroup("ObsidianExtensionSidebar", { clear = true })
local state = {
  bufnr = nil,
  winid = nil,
  source_bufnr = nil,
  source_winid = nil,
  note = nil,
  backlinks = nil,
  generation = 0,
  entries = {},
}

local function sidebar_is_open()
  return state.winid ~= nil and vim.api.nvim_win_is_valid(state.winid)
end

local function source_window()
  if state.source_winid and vim.api.nvim_win_is_valid(state.source_winid) then
    return state.source_winid
  end

  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if winid ~= state.winid then
      return winid
    end
  end
end

local function add_line(lines, highlights, entries, text, highlight, entry)
  lines[#lines + 1] = text
  if highlight then
    highlights[#highlights + 1] = { #lines - 1, highlight }
  end
  if entry then
    entries[#lines] = entry
  end
end

local function section(lines, highlights, title)
  if #lines > 0 and lines[#lines] ~= "" then
    add_line(lines, highlights, {}, "")
  end
  add_line(lines, highlights, {}, title, "Title")
  add_line(lines, highlights, {}, "")
end

local function note_name(note)
  if not note then
    return "Unknown note"
  end
  if note.title and note.title ~= "" then
    return tostring(note.title)
  end
  if note.aliases and note.aliases[1] then
    return tostring(note.aliases[1])
  end
  return tostring(note.id)
end

local function collect_outline(bufnr)
  local headings = {}
  local links = {}
  local seen_links = {}

  for lnum, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local hashes, heading = line:match("^(#+)%s+(.+)$")
    if hashes and heading then
      headings[#headings + 1] = {
        level = #hashes,
        text = heading:gsub("%s+#+%s*$", ""),
        line = lnum,
      }
    end

    for raw_link in line:gmatch("%[%[([^%]]+)%]%]") do
      local target, label = raw_link:match("^([^|]+)|(.+)$")
      target = target or raw_link
      local display = label or target
      target = target:gsub("#.*$", "")
      if target ~= "" and not seen_links[target] then
        seen_links[target] = true
        links[#links + 1] = {
          text = display,
          target = target,
          line = lnum,
        }
      end
    end
  end

  return headings, links
end

local function render()
  if
    not sidebar_is_open()
    or not state.bufnr
    or not vim.api.nvim_buf_is_valid(state.bufnr)
    or not state.source_bufnr
    or not vim.api.nvim_buf_is_valid(state.source_bufnr)
  then
    return
  end

  local note = state.note
  local lines = {}
  local highlights = {}
  local entries = {}
  local headings, links = collect_outline(state.source_bufnr)

  add_line(lines, highlights, entries, note_name(note), "Directory")

  local client = require("obsidian").get_client()
  local relative_path = note.path and client:vault_relative_path(note.path) or nil
  if relative_path then
    add_line(lines, highlights, entries, tostring(relative_path), "Comment")
  end

  local metadata = note.metadata or {}
  if metadata.status then
    add_line(lines, highlights, entries, "status  " .. tostring(metadata.status), "DiagnosticInfo")
  end
  if note.tags and #note.tags > 0 then
    add_line(lines, highlights, entries, "tags    #" .. table.concat(note.tags, "  #"), "Special")
  end
  if note.aliases and #note.aliases > 0 then
    add_line(lines, highlights, entries, "aliases " .. table.concat(note.aliases, ", "), "Comment")
  end

  section(lines, highlights, "HEADINGS")
  if #headings == 0 then
    add_line(lines, highlights, entries, "  (none)", "Comment")
  else
    for _, heading in ipairs(headings) do
      add_line(
        lines,
        highlights,
        entries,
        string.rep("  ", math.max(heading.level - 1, 0)) .. " " .. heading.text,
        "Normal",
        { kind = "source", line = heading.line }
      )
    end
  end

  section(lines, highlights, "LINKS")
  if #links == 0 then
    add_line(lines, highlights, entries, "  (none)", "Comment")
  else
    for _, link in ipairs(links) do
      add_line(lines, highlights, entries, "   " .. link.text, "Underlined", {
        kind = "source",
        line = link.line,
      })
    end
  end

  section(lines, highlights, "BACKLINKS")
  if state.backlinks == nil then
    add_line(lines, highlights, entries, "  Loading…", "Comment")
  elseif #state.backlinks == 0 then
    add_line(lines, highlights, entries, "  (none)", "Comment")
  else
    for _, backlink in ipairs(state.backlinks) do
      local backlink_note = backlink.note
      for _, match in ipairs(backlink.matches) do
        add_line(lines, highlights, entries, "   " .. note_name(backlink_note), "Underlined", {
          kind = "backlink",
          path = tostring(backlink.path),
          line = match.line,
        })
        local context = vim.trim(match.text or "")
        if context ~= "" then
          add_line(lines, highlights, entries, "    " .. context, "Comment", {
            kind = "backlink",
            path = tostring(backlink.path),
            line = match.line,
          })
        end
      end
    end
  end

  add_line(lines, highlights, entries, "")
  add_line(lines, highlights, entries, "<CR> open   R refresh   q close", "Comment")

  vim.bo[state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(state.bufnr, -1, 0, -1)
  for _, highlight in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(state.bufnr, -1, highlight[2], highlight[1], 0, -1)
  end
  vim.bo[state.bufnr].modifiable = false
  state.entries = entries
end

local function close_sidebar()
  local winid = state.winid
  state.generation = state.generation + 1
  state.winid = nil
  state.bufnr = nil
  state.entries = {}
  if winid and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_close(winid, true)
  end
end

local function open_entry()
  local entry = state.entries[vim.api.nvim_win_get_cursor(0)[1]]
  if not entry then
    return
  end

  local winid = source_window()
  if not winid then
    return
  end

  vim.api.nvim_set_current_win(winid)
  state.source_winid = winid

  if entry.kind == "backlink" then
    vim.cmd.edit(vim.fn.fnameescape(entry.path))
    state.source_bufnr = vim.api.nvim_get_current_buf()
  elseif vim.api.nvim_buf_is_valid(state.source_bufnr) then
    vim.api.nvim_win_set_buf(winid, state.source_bufnr)
  end

  local line_count = vim.api.nvim_buf_line_count(0)
  vim.api.nvim_win_set_cursor(winid, { math.min(entry.line, line_count), 0 })
end

local function configure_sidebar_buffer(bufnr)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "obsidian-sidebar"
  vim.bo[bufnr].modifiable = false

  vim.keymap.set(
    "n",
    "q",
    close_sidebar,
    { buffer = bufnr, silent = true, nowait = true, desc = "Close Obsidian sidebar" }
  )
  vim.keymap.set("n", "<CR>", open_entry, { buffer = bufnr, silent = true, desc = "Open Obsidian sidebar entry" })
  vim.keymap.set("n", "R", function()
    M.refresh(state.source_bufnr, state.source_winid)
  end, { buffer = bufnr, silent = true, desc = "Refresh Obsidian sidebar" })
end

local function create_sidebar()
  local source_winid = vim.api.nvim_get_current_win()
  vim.cmd("botright " .. sidebar_width .. "vsplit")

  state.winid = vim.api.nvim_get_current_win()
  state.bufnr = vim.api.nvim_create_buf(false, true)
  state.source_winid = source_winid
  vim.api.nvim_win_set_buf(state.winid, state.bufnr)
  vim.api.nvim_buf_set_name(state.bufnr, "obsidian-sidebar://info")
  configure_sidebar_buffer(state.bufnr)

  vim.wo[state.winid].cursorline = true
  vim.wo[state.winid].foldcolumn = "0"
  vim.wo[state.winid].number = false
  vim.wo[state.winid].relativenumber = false
  vim.wo[state.winid].signcolumn = "no"
  vim.wo[state.winid].spell = false
  vim.wo[state.winid].winfixwidth = true
  vim.wo[state.winid].wrap = false
  vim.wo[state.winid].winbar = "%#Title# OBSIDIAN %*· Note info"

  vim.api.nvim_set_current_win(source_winid)
end

function M.refresh(bufnr, winid)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) or bufnr == state.bufnr then
    return false
  end

  local client = require("obsidian").get_client()
  local note = client:current_note(bufnr, { collect_anchor_links = true })
  if not note then
    return false
  end

  state.source_bufnr = bufnr
  if winid and vim.api.nvim_win_is_valid(winid) and winid ~= state.winid then
    state.source_winid = winid
  end
  state.note = note
  state.backlinks = nil
  state.generation = state.generation + 1
  local generation = state.generation
  render()

  client:find_backlinks_async(note, function(backlinks)
    vim.schedule(function()
      if generation ~= state.generation or not sidebar_is_open() then
        return
      end
      state.backlinks = backlinks
      render()
    end)
  end, { search = { sort = true } })

  return true
end

local function toggle_sidebar()
  if sidebar_is_open() then
    close_sidebar()
    return
  end

  local source_bufnr = vim.api.nvim_get_current_buf()
  local client = require("obsidian").get_client()
  if not client:current_note(source_bufnr) then
    vim.notify("Current buffer is not an Obsidian note", vim.log.levels.WARN)
    return
  end

  create_sidebar()
  M.refresh(source_bufnr, state.source_winid)
end

function M.setup()
  vim.api.nvim_create_user_command("ObsidianSidebar", toggle_sidebar, {
    desc = "Toggle note information in a right sidebar",
  })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(args)
      if not sidebar_is_open() or args.buf == state.bufnr then
        return
      end
      M.refresh(args.buf, vim.api.nvim_get_current_win())
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "*.md",
    callback = function(args)
      if sidebar_is_open() and args.buf == state.source_bufnr then
        M.refresh(args.buf, state.source_winid)
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(args)
      if tonumber(args.match) == state.winid then
        state.generation = state.generation + 1
        state.winid = nil
        state.bufnr = nil
        state.entries = {}
      end
    end,
  })
end

return M

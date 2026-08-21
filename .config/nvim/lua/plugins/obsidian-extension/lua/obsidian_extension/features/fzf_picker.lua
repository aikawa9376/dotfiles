local M = {}

local patched = false

local function aliases_for_entry(entry)
  if type(entry) ~= "table" then
    return {}
  end

  local aliases = entry.aliases
  if type(aliases) ~= "table" and type(entry.value) == "table" then
    aliases = entry.value.aliases
  end

  local result = {}
  for _, alias in ipairs(type(aliases) == "table" and aliases or {}) do
    alias = tostring(alias)
    if alias ~= "" then
      result[#result + 1] = alias
    end
  end
  return result
end

local function alias_suffix(entry)
  local aliases = aliases_for_entry(entry)
  if #aliases == 0 then
    return ""
  end

  return " [" .. table.concat(aliases, ", ") .. "]"
end

local function color_alias_suffix(suffix)
  local ok, utils = pcall(require, "fzf-lua.utils")
  if not ok then
    return suffix
  end

  local aliases = suffix:match("^ %[(.*)%]$")
  if not aliases then
    return suffix
  end
  return utils.ansi_from_hl("Comment", " [") .. utils.ansi_from_hl("String", aliases) .. utils.ansi_from_hl("Comment", "]")
end

local function color_file_name(display, entry)
  if type(entry) ~= "table" or type(entry.filename) ~= "string" or entry.filename == "" then
    return display
  end

  local ok, utils = pcall(require, "fzf-lua.utils")
  if not ok then
    return display
  end

  local filename = vim.fs.basename(entry.filename)
  local start_col
  local offset = 1
  while true do
    local candidate = display:find(filename, offset, true)
    if not candidate then
      break
    end
    start_col = candidate
    offset = candidate + #filename
  end
  if not start_col then
    return display
  end

  return display:sub(1, start_col - 1)
    .. utils.ansi_from_hl("Directory", filename)
    .. display:sub(start_col + #filename)
end

local function colored_displays(picker, values)
  local displays = {}
  for _, entry in ipairs(values or {}) do
    local display = picker:_make_display(entry)
    local suffix = alias_suffix(entry)
    local colored
    if suffix ~= "" then
      colored = color_file_name(display:sub(1, #display - #suffix), entry) .. color_alias_suffix(suffix)
    else
      colored = color_file_name(display, entry)
    end
    if colored ~= display then
      displays[display] = colored
    end
  end
  return displays
end

local function note_entries(client, paths)
  local Note = require("obsidian.note")
  local entries = {}
  for _, relative_path in ipairs(paths or {}) do
    if relative_path ~= "" then
      local path = vim.fs.joinpath(tostring(client.dir), relative_path)
      local ok, note = pcall(Note.from_file, path, { max_lines = client.opts.search_max_lines })
      entries[#entries + 1] = {
        value = path,
        filename = path,
        aliases = ok and note.aliases or nil,
      }
    end
  end
  return entries
end

local function strip_ansi(text)
  local ok, utils = pcall(require, "fzf-lua.utils")
  if ok then
    return utils.strip_ansi_coloring(text)
  end
  return tostring(text or ""):gsub("\27%[[0-9;]*[A-Za-z]", "")
end

local function display_keys(text)
  text = strip_ansi(text)
  local ok, utils = pcall(require, "fzf-lua.utils")
  if ok and utils.nbsp then
    text = text:gsub(vim.pesc(utils.nbsp), " ")
  end
  text = vim.trim(text:gsub("\194\160", " "):gsub("%s+", " "))

  local keys = {}
  local seen = {}
  local function add(key)
    key = vim.trim(key)
    if key ~= "" and not seen[key] then
      keys[#keys + 1] = key
      seen[key] = true
    end
  end

  add(text)
  local without_icon = text:gsub("^%S+%s+", "", 1)
  add(without_icon)
  add(text:gsub("%s+%b[]$", "", 1))
  add(without_icon:gsub("%s+%b[]$", "", 1))
  return keys
end

local function resolve_preview_location(locations, entry_str)
  for _, key in ipairs(display_keys(entry_str)) do
    if locations[key] then
      return locations[key]
    end
  end
end

local function preview_location(entry)
  if type(entry) ~= "table" or not entry.filename or entry.filename == "" then
    return nil
  end

  local location = tostring(entry.filename)
  if entry.lnum then
    location = location .. ":" .. tostring(entry.lnum)
    if entry.col then
      location = location .. ":" .. tostring(entry.col)
    end
  end
  return location
end

local function preview_locations(picker, values)
  local locations = {}
  for _, entry in ipairs(values or {}) do
    local location = preview_location(entry)
    if location then
      for _, key in ipairs(display_keys(picker:_make_display(entry))) do
        locations[key] = location
      end
    end
  end
  return locations
end

local function location_previewer(locations)
  local Parent = require("fzf-lua.previewer.builtin").buffer_or_file
  local Previewer = Parent:extend()

  function Previewer:new(opts, fzf_opts)
    local instance = setmetatable({}, Previewer)
    return Parent.new(instance, opts, fzf_opts)
  end

  function Previewer:entry_to_file(entry_str)
    return Parent.entry_to_file(self, resolve_preview_location(locations, entry_str) or entry_str)
  end

  function Previewer:parse_entry(entry_str, callback)
    return Parent.parse_entry(self, resolve_preview_location(locations, entry_str) or entry_str, callback)
  end

  return Previewer
end

local function with_preview(fzf_opts, locations)
  if not next(locations) then
    return fzf_opts
  end

  fzf_opts = fzf_opts or {}
  fzf_opts.previewer = fzf_opts.previewer or location_previewer(locations)
  fzf_opts.fzf_opts = fzf_opts.fzf_opts or {}
  fzf_opts.fzf_opts["--ansi"] = true
  fzf_opts.winopts = vim.tbl_deep_extend("force", fzf_opts.winopts or {}, {
    preview = {
      hidden = false,
      layout = "horizontal",
      horizontal = "right:55%",
    },
  })
  return fzf_opts
end

function M.setup()
  if patched then
    return
  end

  local ok, FzfPicker = pcall(require, "obsidian.pickers._fzf")
  if not ok then
    return
  end

  local original_make_display = FzfPicker._make_display
  FzfPicker._make_display = function(self, entry)
    local display, highlights = original_make_display(self, entry)
    return display .. alias_suffix(entry), highlights
  end

  local original_pick = FzfPicker.pick
  FzfPicker.pick = function(self, values, opts)
    local locations = preview_locations(self, values)
    local colored = colored_displays(self, values)
    if not next(locations) then
      return original_pick(self, values, opts)
    end

    -- Obsidian's fzf picker turns PickerEntry objects into display-only
    -- strings. Decorate the synchronous fzf_exec call so filename/position
    -- metadata can still drive fzf-lua's builtin previewer.
    local fzf = require("fzf-lua")
    local original_exec = fzf.fzf_exec
    fzf.fzf_exec = function(contents, fzf_opts)
      if type(contents) == "table" and next(colored) then
        contents = vim.tbl_map(function(display)
          return colored[display] or display
        end, contents)
      end
      return original_exec(contents, with_preview(fzf_opts, locations))
    end

    local result = { pcall(original_pick, self, values, opts) }
    fzf.fzf_exec = original_exec
    if not result[1] then
      error(result[2], 0)
    end
    return unpack(result, 2)
  end

  -- Upstream QuickSwitch delegates to find_files(), whose source only contains
  -- paths. Materialize note entries so aliases can be shown and searched too.
  FzfPicker.find_notes = function(self, opts)
    self.calling_bufnr = vim.api.nvim_get_current_buf()
    opts = opts or {}

    local query_mappings
    local selection_mappings
    if not opts.no_default_mappings then
      query_mappings = self:_note_query_mappings()
      selection_mappings = self:_note_selection_mappings()
    end

    vim.system(self:_build_find_cmd(), {
      cwd = tostring(self.client.dir),
      text = true,
    }, vim.schedule_wrap(function(result)
      local paths = vim.split(result.stdout or "", "\n", { plain = true, trimempty = true })
      self:pick(note_entries(self.client, paths), {
        prompt_title = opts.prompt_title or "Notes",
        callback = opts.callback or function(path)
          self.client:open_note(path)
        end,
        no_default_mappings = opts.no_default_mappings,
        query_mappings = query_mappings,
        selection_mappings = selection_mappings,
      })
    end))
  end

  patched = true
end

M._preview_location = preview_location
M._preview_locations = preview_locations
M._with_preview = with_preview
M._aliases_for_entry = aliases_for_entry
M._alias_suffix = alias_suffix
M._color_alias_suffix = color_alias_suffix
M._color_file_name = color_file_name
M._colored_displays = colored_displays
M._note_entries = note_entries
M._display_keys = display_keys
M._resolve_preview_location = resolve_preview_location
M._location_previewer = location_previewer

return M

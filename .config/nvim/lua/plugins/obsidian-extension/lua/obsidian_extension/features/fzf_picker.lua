local M = {}

local patched = false

local function strip_ansi(text)
  local ok, utils = pcall(require, "fzf-lua.utils")
  if ok then
    return utils.strip_ansi_coloring(text)
  end
  return tostring(text or ""):gsub("\27%[[0-9;]*[A-Za-z]", "")
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
      locations[strip_ansi(picker:_make_display(entry))] = location
    end
  end
  return locations
end

local function location_previewer(locations)
  local Parent = require("fzf-lua.previewer.builtin").buffer_or_file
  local Previewer = Parent:extend()

  function Previewer:parse_entry(entry_str)
    local location = locations[strip_ansi(entry_str)]
    return Parent.parse_entry(self, location or entry_str)
  end

  return Previewer
end

local function with_preview(fzf_opts, locations)
  if not next(locations) then
    return fzf_opts
  end

  fzf_opts = fzf_opts or {}
  fzf_opts.previewer = fzf_opts.previewer or location_previewer(locations)
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

  local original_pick = FzfPicker.pick
  FzfPicker.pick = function(self, values, opts)
    local locations = preview_locations(self, values)
    if not next(locations) then
      return original_pick(self, values, opts)
    end

    -- Obsidian's fzf picker turns PickerEntry objects into display-only
    -- strings. Decorate the synchronous fzf_exec call so filename/position
    -- metadata can still drive fzf-lua's builtin previewer.
    local fzf = require("fzf-lua")
    local original_exec = fzf.fzf_exec
    fzf.fzf_exec = function(contents, fzf_opts)
      return original_exec(contents, with_preview(fzf_opts, locations))
    end

    local result = { pcall(original_pick, self, values, opts) }
    fzf.fzf_exec = original_exec
    if not result[1] then
      error(result[2], 0)
    end
    return unpack(result, 2)
  end

  patched = true
end

M._preview_location = preview_location
M._preview_locations = preview_locations
M._with_preview = with_preview

return M

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(source))

vim.opt.runtimepath:prepend(root)
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

local fzf_picker = require("obsidian_extension.features.fzf_picker")

local alias_suffix = fzf_picker._alias_suffix({
  value = { aliases = { "Quick switch alias", "日本語の別名" } },
})
assert(alias_suffix == " [Quick switch alias, 日本語の別名]", "aliases use the compact searchable display")
assert(fzf_picker._alias_suffix({ display = "No aliases" }) == "", "entries without aliases are unchanged")

local original_utils = package.loaded["fzf-lua.utils"]
package.loaded["fzf-lua.utils"] = {
  ansi_from_hl = function(_, text)
    return "\27[36m" .. text .. "\27[0m"
  end,
}
local colored_name = fzf_picker._color_file_name(" notes/nested/topic.md", {
  filename = "/vault/notes/nested/topic.md",
})
package.loaded["fzf-lua.utils"] = original_utils
assert(colored_name:gsub("\27%[[0-9;]*[A-Za-z]", "") == " notes/nested/topic.md", "filename color preserves display text")
assert(colored_name:find("notes/nested/\27[", 1, true), "only the basename starts the filename highlight")

local alias_path = "/vault/notes/LazyAgent Obsidian skills architecture.md"
local daily_path = "/vault/daily/2026-08-21.md"
local fallback_locations = {
  ["notes/LazyAgent Obsidian skills architecture.md"] = alias_path,
  ["daily/2026-08-21.md"] = daily_path,
}
assert(fzf_picker._resolve_preview_location(fallback_locations,
  " notes/LazyAgent Obsidian skills architecture.md [LazyAgent Obsidian skills architecture]") == alias_path,
  "preview ignores both the note icon and aliases")
assert(fzf_picker._resolve_preview_location(fallback_locations, " daily/2026-08-21.md") == daily_path,
  "preview ignores the note icon when there are no aliases")

assert(fzf_picker._preview_location({ filename = "/vault/daily/2026-08-01.md" })
  == "/vault/daily/2026-08-01.md", "daily preview path")
assert(fzf_picker._preview_location({
  filename = "/vault/notes/topic.md",
  lnum = 12,
  col = 4,
}) == "/vault/notes/topic.md:12:4", "located preview path")
assert(fzf_picker._preview_location({ display = "no file" }) == nil, "non-file entry")

local picker = {
  _make_display = function(_, entry)
    return "\27[32m" .. (entry.display or entry.filename or tostring(entry.value)) .. "\27[0m"
  end,
}
local locations = fzf_picker._preview_locations(picker, {
  { display = "Today", filename = "/vault/daily/2026-08-01.md" },
  { display = "Backlink", filename = "/vault/notes/ref.md", lnum = 8 },
  "plain value",
})
assert(locations.Today == "/vault/daily/2026-08-01.md", "ANSI display maps to daily path")
assert(locations.Backlink == "/vault/notes/ref.md:8", "backlink line is retained")

package.loaded["fzf-lua.previewer.builtin"] = {
  buffer_or_file = {
    extend = function()
      return {}
    end,
    new = function(self)
      return self
    end,
    parse_entry = function(_, entry)
      return entry
    end,
    entry_to_file = function(_, entry)
      return entry
    end,
  },
}
local opts = fzf_picker._with_preview({}, locations)
assert(opts.previewer ~= nil, "builtin previewer configured")
assert(opts.winopts.split == nil, "preview picker inherits the global bottom split")
assert(opts.winopts.height == nil, "preview picker does not override the global height")
assert(opts.winopts.width == nil, "preview picker does not override the global width")
assert(opts.winopts.preview.hidden == false, "preview is initially visible")
assert(opts.fzf_opts["--ansi"] == true, "alias colors are enabled")
assert(type(opts.previewer.new) == "function", "custom previewer keeps an explicit constructor")
local fallback_opts = fzf_picker._with_preview({}, fallback_locations)
assert(fallback_opts.previewer.entry_to_file({},
  " notes/LazyAgent Obsidian skills architecture.md [LazyAgent Obsidian skills architecture]") == alias_path,
  "preview entry-to-file conversion ignores icons and aliases")

local captured_opts
local original_fake_exec
local fake_fzf = {
  fzf_exec = function(_, exec_opts)
    captured_opts = exec_opts
  end,
}
original_fake_exec = fake_fzf.fzf_exec
local FakeFzfPicker = {
  find_notes = function() end,
  _make_display = function(self, entry)
    return self.__make_display(self, entry)
  end,
  pick = function(self, values)
    local entries = {}
    for _, entry in ipairs(values) do
      entries[#entries + 1] = self:_make_display(entry)
    end
    fake_fzf.fzf_exec(entries, {})
  end,
}
package.loaded["fzf-lua"] = fake_fzf
package.loaded["obsidian.pickers._fzf"] = FakeFzfPicker

fzf_picker.setup()
picker.__make_display = picker._make_display
picker._make_display = FakeFzfPicker._make_display
FakeFzfPicker.pick(picker, {
  {
    filename = "/vault/daily/2026-08-01.md",
    aliases = { "今日" },
  },
})
assert(captured_opts.previewer ~= nil, "Obsidian picker receives a previewer")
local colored_today = picker:_make_display({ filename = "/vault/daily/2026-08-01.md", aliases = { "今日" } })
assert(colored_today:gsub("\27%[[0-9;]*[A-Za-z]", "") == "/vault/daily/2026-08-01.md [今日]",
  "note filename and aliases use the compact display")
assert(captured_opts.previewer.parse_entry({}, colored_today) == "/vault/daily/2026-08-01.md",
  "Obsidian picker preview resolves the selected display")
assert(fake_fzf.fzf_exec == original_fake_exec, "fzf_exec restored after picker setup")

print("ok - fzf_picker_spec")

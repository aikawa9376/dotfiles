local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(source))

vim.opt.runtimepath:prepend(root)
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

local fzf_picker = require("obsidian_extension.features.fzf_picker")

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
    return "\27[32m" .. entry.display .. "\27[0m"
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
    parse_entry = function(_, entry)
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

local captured_opts
local original_fake_exec
local fake_fzf = {
  fzf_exec = function(_, exec_opts)
    captured_opts = exec_opts
  end,
}
original_fake_exec = fake_fzf.fzf_exec
local FakeFzfPicker = {
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
FakeFzfPicker.pick(picker, {
  { display = "Today", filename = "/vault/daily/2026-08-01.md" },
})
assert(captured_opts.previewer ~= nil, "Obsidian picker receives a previewer")
assert(captured_opts.previewer.parse_entry({}, "Today") == "/vault/daily/2026-08-01.md",
  "Obsidian picker preview resolves the selected display")
assert(fake_fzf.fzf_exec == original_fake_exec, "fzf_exec restored after picker setup")

print("ok - fzf_picker_spec")

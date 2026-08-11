local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(source))

vim.opt.runtimepath:prepend(root)
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

local captured
package.loaded["fzf-lua"] = {
  fzf_exec = function(entries, opts)
    captured = { entries = entries, opts = opts }
  end,
}

require("obsidian_extension.features.menu").setup()
vim.cmd("ObsidianMenu")

assert(#captured.entries > 0, "menu entries passed to fzf-lua")
assert(captured.opts.winopts == nil, "menu inherits the global bottom split")
assert(captured.opts.actions.default ~= nil, "default menu action configured")

print("ok - menu_spec")

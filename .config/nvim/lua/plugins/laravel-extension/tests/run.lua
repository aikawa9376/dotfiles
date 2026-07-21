local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.dirname(source))

vim.opt.runtimepath:prepend(root)
package.path = table.concat({ root .. "/?.lua", root .. "/?/init.lua", package.path }, ";")

require("tests.definition_spec").run()
require("tests.component_spec").run()
require("tests.fzf_picker_spec").run()
print("all laravel-extension tests passed")

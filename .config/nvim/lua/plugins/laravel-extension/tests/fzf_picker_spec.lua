local M = {}

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local original_fzf = package.loaded["fzf-lua"]
  local original_picker = package.loaded["laravel_extension.fzf_picker"]
  local captured_entries, captured_opts
  local actions = {
    file_edit_or_qf = function() end,
    file_split = function() end,
    file_vsplit = function() end,
    file_sel_to_qf = function() end,
  }
  package.loaded["fzf-lua"] = {
    actions = actions,
    fzf_exec = function(entries, opts)
      captured_entries, captured_opts = entries, opts
    end,
  }
  package.loaded["laravel_extension.fzf_picker"] = nil
  local picker = require("laravel_extension.fzf_picker")
  picker.select({
    { path = "/repo/app/View/Components/Hoge.php", row = 7, col = 9, kind = "php", text = "class Hoge" },
    { path = "/repo/resources/views/show.blade.php", row = 12, col = 5, kind = "blade", text = "<x-hoge />" },
  }, { prompt = "Component references > " })

  assert_equal(captured_entries, {
    "/repo/app/View/Components/Hoge.php:7:9:[php] class Hoge",
    "/repo/resources/views/show.blade.php:12:5:[blade] <x-hoge />",
  }, "file entries include previewable positions")
  assert(captured_opts, "fzf options captured")
  assert_equal(captured_opts.prompt, "Component references > ", "custom prompt")
  assert_equal(captured_opts.previewer, "builtin", "builtin file preview enabled")
  assert_equal(captured_opts.winopts, nil, "global bottom split options inherited")
  assert_equal(captured_opts.actions.enter, actions.file_edit_or_qf, "enter uses standard file action")
  assert_equal(captured_opts.actions["ctrl-s"], actions.file_split, "split action available")
  assert_equal(captured_opts.actions["ctrl-v"], actions.file_vsplit, "vsplit action available")

  package.loaded["fzf-lua"] = original_fzf
  package.loaded["laravel_extension.fzf_picker"] = original_picker
end

return M

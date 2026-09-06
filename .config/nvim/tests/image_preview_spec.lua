-- nvim --headless --clean -u NONE -l .config/nvim/tests/image_preview_spec.lua
local config = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
vim.opt.rtp:prepend(config)
vim.opt.rtp:append(vim.fn.stdpath("data") .. "/lazy/snacks.nvim")
local preview
local fixture = vim.fn.tempname()
local original_cwd = vim.fn.getcwd()
local original_select = vim.ui.select
local original_notify = vim.notify
local render
local messages = {}

local function eq(expected, actual)
  assert(vim.deep_equal(expected, actual), vim.inspect({ expected = expected, actual = actual }))
end

local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines or { "fixture" }, path)
end

local function wait_for(fn)
  assert(vim.wait(3000, fn, 10), "async operation timed out")
end

local function close_float()
  local win = vim.api.nvim_get_current_win()
  assert(vim.api.nvim_win_get_config(win).relative ~= "", "expected a float")
  local mapping = vim.fn.maparg("q", "n", false, true)
  assert(type(mapping.callback) == "function", "missing close action")
  mapping.callback()
  wait_for(function() return not vim.api.nvim_win_is_valid(win) end)
end

local ok, err = xpcall(function()
  vim.notify = function(message) messages[#messages + 1] = message end
  dofile(config .. "/lua/plugins/snack.lua").config()
  preview = dofile(config .. "/lua/plugins/image-preview.lua").config()
  local snacks = require("snacks")
  render = snacks.image.buf.attach
  local rendered = {}
  -- Keep the real Snacks window/lifecycle; capture the terminal-renderer handoff.
  snacks.image.buf.attach = function(buf, opts)
    rendered[#rendered + 1] = { buf = buf, path = opts.src }
  end

  write(fixture .. "/project/.git/HEAD", { "ref: refs/heads/main" })
  local root = fixture .. "/project"
  local source = root .. "/src/example.md"
  write(source, { "source" })
  write(root .. "/assets/icons/logo.png")
  write(root .. "/assets/screenshots/logo.png")
  write(root .. "/assets/logo-small.png")
  write(root .. "/assets/space image.png")
  write(root .. "/assets/unique.jpg")
  write(root .. "/.hidden/secret.png")
  write(root .. "/.git/ignored.png")
  write(root .. "/.gitignore", { "ignored/" })
  write(root .. "/ignored/unique.jpg")
  vim.cmd.cd({ args = { fixture } })
  vim.cmd.edit({ args = { source } })
  local source_win = vim.api.nvim_get_current_win()
  local source_buf = vim.api.nvim_get_current_buf()
  eq(root, preview.project_root(source_buf))

  local extraction = {
    { '![[assets/space image.png|caption]]', 12, 'assets/space image.png' },
    { '![caption](<assets/space image.png> "title")', 4, 'assets/space image.png' },
    { '![caption](assets/foo(bar).png)', 4, 'assets/foo(bar).png' },
    { 'src="assets/space image.png"', 12, 'assets/space image.png' },
    { '`assets/logo.png`', 5, 'assets/logo.png' },
    { 'assets/logo.png', 5, 'assets/logo.png' },
    { '![x](assets/logo.png?v=2#preview)', 3, 'assets/logo.png' },
    { '![x](assets/logo.png)', 0, 'assets/logo.png' },
  }
  for _, item in ipairs(extraction) do
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { item[1] })
    vim.api.nvim_win_set_cursor(0, { 1, item[2] })
    eq(item[3], preview.path_at_cursor())
  end
  eq('assets/space image.png', preview.normalize('assets/space%20image.png'))
  eq('assets/space image.png', preview.normalize('assets/space\\ image.png'))
  eq('/tmp/a.png', preview.normalize('file:///tmp/a.png'))
  eq('C:/assets/a.png', preview.normalize('C:\\assets\\a.png'))
  local ranked = preview.rank('old/icons/logo.png', {
    'assets/screenshots/logo.png', 'assets/logo-small.png', 'assets/icons/logo.png', 'logo.txt',
  })
  eq('assets/icons/logo.png', ranked[1].path)
  eq('assets/screenshots/logo.png', ranked[2].path)
  eq('assets/logo-small.png', ranked[3].path)
  eq(3, #ranked)

  vim.ui.select = function() error('unexpected picker for an exact path') end
  preview.open('../assets/space%20image.png')
  eq(root .. '/assets/space image.png', rendered[#rendered].path)
  eq(source_buf, vim.api.nvim_win_get_buf(source_win))
  local image_buf = vim.api.nvim_get_current_buf()
  assert(image_buf ~= source_buf)
  close_float()
  wait_for(function() return not vim.api.nvim_buf_is_valid(image_buf) end)
  eq(source_win, vim.api.nvim_get_current_win())
  -- Exact root-relative paths and command arguments containing spaces.
  vim.cmd('ImagePreview assets/space image.png')
  eq(root .. '/assets/space image.png', rendered[#rendered].path)
  close_float()

  local before = #rendered
  preview.open('/old/machine/unique.jpg')
  wait_for(function() return #rendered > before end)
  eq(root .. '/assets/unique.jpg', vim.fs.normalize(rendered[#rendered].path))
  close_float()

  local picked
  vim.ui.select = function(items, _, choose)
    picked = items
    choose(items[2])
  end
  before = #rendered
  preview.open('old/icons/logo.png')
  wait_for(function() return #rendered > before end)
  eq('./assets/icons/logo.png', picked[1].path)
  eq(root .. '/assets/screenshots/logo.png', vim.fs.normalize(rendered[#rendered].path))
  close_float()

  local selection_done = false
  vim.ui.select = function(_, _, choose) selection_done = true; choose(nil) end
  before = #rendered
  preview.open('logo.png')
  wait_for(function() return selection_done end)
  vim.wait(30)
  eq(before, #rendered)
  eq(source_win, vim.api.nvim_get_current_win())

  local notified = #messages
  preview.open('does-not-exist.png')
  wait_for(function() return #messages > notified end)
  assert(messages[#messages]:find('No matching image', 1, true))
  eq(before, #rendered)
  -- New requests invalidate pending searches; the old callback cannot reopen a float.
  preview.open('logo.png')
  preview.open(root .. '/assets/unique.jpg')
  close_float()
  vim.wait(100)
  eq(before + 1, #rendered)
  eq(source_win, vim.api.nvim_get_current_win())
  print('PASS: image extraction, ranking, real project search, selection/cancel, command, float cleanup, stale requests')
end, debug.traceback)

if render then require('snacks').image.buf.attach = render end
vim.ui.select = original_select
vim.notify = original_notify
vim.cmd.cd({ args = { original_cwd } })
vim.fn.delete(fixture, 'rf')
if not ok then error(err) end
vim.cmd('qa!')

-- Run with a UI: nvim --clean -u NONE -c 'luafile .config/nvim/tests/inkstone.lua' -c 'qa!'
-- Neovim 0.13-dev's diagnostic statusline redraw can crash without an allocated UI grid.
local source = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
local root = vim.fs.dirname(vim.fs.dirname(source))
local data = vim.fn.stdpath('data')
vim.opt.rtp:prepend(vim.env.INKSTONE_RTP or (data .. '/lazy/inkstone.nvim'))
vim.opt.rtp:append(data .. '/site')
for _, plugin in ipairs({ 'lazyagent', 'git', 'obsidian-extension' }) do
  vim.opt.rtp:append(root .. '/lua/plugins/' .. plugin)
end
vim.o.columns, vim.o.lines, vim.o.swapfile = 140, 45, false
local spec = dofile(root .. '/lua/plugins/inkstone.lua')
spec.init()
local renderer = require('inkstone')
renderer.setup(spec.opts)
vim.cmd('runtime plugin/inkstone.lua')
local state = require('inkstone.state')
assert(#state.validate() == 0, vim.inspect(state.validate()))
assert(vim.g.markdown_renderer == 'inkstone')
assert(require('lazyagent.markdown_renderer').name() == 'inkstone')

local lines = {
  'RAW METADATA', '', '# Heading', '', '- [ ] unchecked', '- [x] checked', '- [-] todo', '',
  '| 項目 | 説明 |', '| --- | --- |', '| 日本語 | ｶﾞ / ﾊﾟ |', '',
  '```lua', 'local value = 1', '```',
}
local ui = require('inkstone.core.ui')
for _, ft in ipairs(spec.ft) do
  assert(vim.treesitter.language.get_lang(ft) == 'markdown', ft)
  local buf = vim.api.nvim_create_buf(false, true)
  if ft == 'markdown' then vim.bo[buf].buftype = '' end
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft
  if ft == 'gitpr' or ft == 'gitissue' then
    local pr = require('git.features.pr_markdown')
    assert(pr.prepare(buf))
    pr.update(buf, { { 2, #lines } })
  else
    renderer.render({ buf = buf })
  end
  assert(vim.wait(3000, function() return ui.cache[buf] and ui.cache[buf].n > 0 end), ft .. ': no render')
  local marks = vim.api.nvim_buf_get_extmarks(buf, ui.ns, 0, -1, { details = true })
  assert(#marks > 0, ft .. ': empty decorations')
  assert(not vim.inspect(marks):find('RenderMarkdown', 1, true), ft .. ': old highlight namespace')
  local config = state.get(buf)
  if ft == 'blink-cmp-documentation' then
    assert(config.code.left_pad == 0 and config.code.right_pad == 0 and config.debounce == 0)
  else
    assert(config.code.left_pad == 1 and config.code.right_pad == 1)
  end
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines), ft .. ': source changed')
  vim.api.nvim_buf_delete(buf, { force = true })
  assert(ui.cache[buf] == nil and state.cache[buf] == nil, ft .. ': stale cache')
  print('PASS: Inkstone configuration and adapter: ' .. ft)
end
-- Right-aligned language labels must stay visible even when a body line wraps.
vim.cmd('vsplit')
vim.api.nvim_win_set_width(0, 60)
local restore_buf = vim.api.nvim_get_current_buf()
for _, ft in ipairs({ 'lazyagent', 'lazyagent_acp' }) do
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  vim.bo[buf].filetype = ft
  local source_lines = {
    '```lua', 'local value = 1', '```', '',
    '```python', 'print("' .. string.rep('x', 160) .. '")', '```', '',
  }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, source_lines)
  renderer.render({ buf = buf })
  assert(vim.wait(3000, function() return ui.cache[buf] and ui.cache[buf].n > 0 end), ft .. ': no code render')
  local width = require('inkstone.lib.env').win.width(vim.api.nvim_get_current_win())
  local labels = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ui.ns, 0, -1, { details = true })) do
    local opts = mark[4]
    if opts.virt_text_pos == 'overlay' and opts.virt_text then
      local text = ''
      for _, chunk in ipairs(opts.virt_text) do text = text .. chunk[1] end
      for _, language in ipairs({ 'lua', 'python' }) do
        if text:find(language, 1, true) then
          assert(vim.fn.strdisplaywidth(text) <= width, ft .. ': ' .. language .. ' is outside the window')
          labels[language] = true
        end
      end
    end
  end
  assert(labels.lua and labels.python, ft .. ': missing language label')
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), source_lines), ft .. ': code source changed')
  vim.api.nvim_win_set_buf(0, restore_buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  print('PASS: visible Lua/Python labels for short and wrapped code: ' .. ft)
end
vim.cmd('close')
for name in pairs(package.loaded) do
  assert(not name:match('^render%-markdown'), 'Loaded old renderer: ' .. name)
end
vim.api.nvim_set_hl(0, 'InkstoneCode', {})
vim.api.nvim_exec_autocmds('ColorScheme', {})
assert(vim.api.nvim_get_hl(0, { name = 'InkstoneCode' }).bg == 0x073642)
print('PASS: isolated namespaces, custom highlights survive ColorScheme, source/cache lifetimes')

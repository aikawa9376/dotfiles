-- Integration contract against installed render-markdown and Markdown/Lua parsers.
local source = debug.getinfo(1, 'S').source:gsub('^@', '')
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
vim.opt.rtp:prepend(root)
vim.opt.rtp:append(assert(vim.env.LAZYAGENT_MARKDOWN_RTP, 'set LAZYAGENT_MARKDOWN_RTP'))
vim.opt.rtp:append(assert(vim.env.LAZYAGENT_PARSER_RTP, 'set LAZYAGENT_PARSER_RTP'))
vim.treesitter.language.register('markdown', 'lazyagent_acp')
require('render-markdown').setup({
  file_types = { 'lazyagent_acp' },
  anti_conceal = { enabled = false },
  code = { sign = false, left_pad = 1 },
  custom_handlers = { markdown = { parse = require('lazyagent.render_markdown').parse } },
  overrides = {
    buftype = { nofile = { code = { left_pad = 0 } } },
    filetype = { lazyagent_acp = { code = { left_pad = 1 }, debounce = 100 } },
  },
})
local ui = require('render-markdown.core.ui')
local manager = require('render-markdown.core.manager')
local state = require('render-markdown.state')
local Preview = require('lazyagent.acp.transcript_preview')
local ns = vim.api.nvim_create_namespace('lazyagent_acp_preview')
local lines = {
  '─ 󰋽 System', 'Connected',
  '─ 󰍩 User · 2026-10-24 08:13 ' .. string.rep('─', 80), 'prompt',
  '─ 󰭹 Codex 6.1 Sol High · 2026-10-24 08:14 ' .. string.rep('─', 80),
  '```lua', 'local value = 42', '```',
  '─ 󱁤 Tool execute completed', ' - System output remains literal',
}
local starting = #manager.buffers
for cycle = 1, 5 do
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  local view = Preview.attach(buf)
  view.set(lines, {transcript=true, provider='Codex'})
  assert(vim.wait(2000, function() return ui.cache[buf] and ui.cache[buf].n > 0 end, 10), 'external renderer completes')
  local parser = assert(vim.treesitter.highlighter.active[buf]).tree
  assert(vim.wait(1000, function()
    local child = parser:children().lua
    return child and next(child:trees()) ~= nil
  end, 10), 'injected Lua is highlighted')
  assert(state.get(buf).code.left_pad == 1, 'ACP padding override is selected')
  local painted = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {details=true})) do painted[mark[2]+1]=mark[4].hl_group end
  assert(painted[1]=='LazyAgentACPSystemHeader' and painted[5]=='LazyAgentACPAssistantHeader' and painted[9]=='LazyAgentACPToolHeader', 'ACP role colors coexist with external Markdown marks')
  view.set({'# Details', '', '```lua', 'print(42)', '```'}, {transcript=false})
  assert(vim.wait(2000, function() return ui.cache[buf].n > 1 end, 10), 'quick mode switch gets a trailing render')
  assert(#vim.api.nvim_buf_get_extmarks(buf,ns,0,-1,{})==0, 'details clears role colors')
  view.set(lines, {transcript=true,provider='Codex'})
  vim.wait(100)
  local timer = ui.cache[buf].timer
  vim.api.nvim_buf_delete(buf, {force=true})
  vim.wait(50)
  assert(timer:is_closing(), 'renderer timer is closed')
  assert(ui.cache[buf]==nil and state.cache[buf]==nil and not manager.attached(buf), 'external caches are released')
end
assert(#manager.buffers==starting, 'preview cycles do not accumulate external renderer attachments')
print('PASS: real Markdown renderer, injected Lua, ACP colors, mode switches and 5 wipe cycles')

-- Theme-linked accents shared by editable Git panels. No buffer text changes.
local M = {}
local ns = vim.api.nvim_create_namespace('git_panel_highlight')
local links = { Title = 'Title', Label = 'Type', Hash = 'String', Ref = 'Directory', Key = 'Special',
  Pick = 'String', Reword = 'Type', Edit = 'DiagnosticWarn', Squash = 'Special',
  Fixup = 'Constant', Drop = 'GitSignsDelete', Break = 'DiagnosticWarn', Exec = 'DiagnosticInfo' }
local function setup()
  for name, link in pairs(links) do vim.api.nvim_set_hl(0, 'GitPanel' .. name, { default = true, link = link }) end
end
setup()
vim.api.nvim_create_autocmd('ColorScheme', {
  group = vim.api.nvim_create_augroup('GitPanelHighlights', { clear = true }), callback = setup,
})
local function span(buf, row, first, last, group)
  if last > first then vim.api.nvim_buf_set_extmark(buf, ns, row, first, {
    end_col = last, hl_group = group, priority = 120 }) end
end
local function all(buf, row, line, group) span(buf, row, 0, #line, group) end
local function tokens(buf, row, line)
  for first, text, after in line:gmatch('()([%x]+)()') do
    if #text >= 7 then span(buf, row, first - 1, after - 1, 'GitPanelHash') end
  end
end
local actions = { p = 'Pick', pick = 'Pick', r = 'Reword', reword = 'Reword', e = 'Edit', edit = 'Edit',
  s = 'Squash', squash = 'Squash', f = 'Fixup', fixup = 'Fixup', d = 'Drop', drop = 'Drop',
  b = 'Break', x = 'Exec', exec = 'Exec' }
actions['break'] = 'Break'
function M.rebase(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local row = i - 1
    if line:match('^# Rebase plan:') then
      all(buf, row, line, 'GitPanelTitle')
      span(buf, row, 15, #line, 'GitPanelRef')
    elseif (line:match('^# Old base') or line:match('^# New base')) then
      all(buf, row, line, 'GitPanelLabel'); tokens(buf, row, line)
    elseif line:match('^#') then
      all(buf, row, line, 'Comment')
      -- Each guide item starts with its key(s), followed by a colon.
      for first, keys, after in line:gmatch('()([^|#]+):()') do
        local skip = #(keys:match('^%s*') or '')
        span(buf, row, first - 1 + skip, after - 2, 'GitPanelKey')
      end
    else
      local first, action, after = line:match('^%s*()(%a+)()')
      if action and actions[action] then
        span(buf, row, first - 1, after - 1, 'GitPanel' .. actions[action])
        local a, hash, b = line:match('^%s*%a+%s+()(%x+)()')
        if hash and action ~= 'exec' and action ~= 'x' then span(buf, row, a - 1, b - 1, 'GitPanelHash') end
        if action == 'exec' or action == 'x' then span(buf, row, after, #line, 'GitPanelExec') end
      end
    end
  end
end
function M.patch(state)
  local right, left = state.right, state.left
  vim.api.nvim_buf_clear_namespace(right, ns, 0, -1)
  local preview = false
  for i, line in ipairs(vim.api.nvim_buf_get_lines(right, 0, -1, false)) do
    local row = i - 1
    if i == 1 then all(right, row, line, 'GitPanelTitle'); tokens(right, row, line)
    elseif i == 2 then
      all(right, row, line, 'Comment')
      for first, key, after in line:gmatch('()(<Space>)()') do span(right, row, first - 1, after - 1, 'GitPanelKey') end
      for first, key, after in line:gmatch('()([crq]) [a-z]+()') do span(right, row, first - 1, first, 'GitPanelKey') end
    elseif line == '# --- Collected patch (read-only) ---' then
      preview = true; all(right, row, line, 'GitPanelTitle')
    elseif not preview and i == 4 then all(right, row, line, 'GitPanelTitle')
    elseif line == '# No changes selected' then all(right, row, line, 'Comment')
    elseif preview and line:match('^diff %-%-git ') then all(right, row, line, 'GitPanelRef')
    elseif preview and line:match('^@@') then all(right, row, line, 'GitPanelLabel')
    end
  end
  vim.api.nvim_buf_clear_namespace(left, ns, 0, -1)
  local commit = require('git.features.commit')
  for i = 1, vim.api.nvim_buf_line_count(left) do
    local entry, info = commit.entry_at(left, i)
    local selected = entry and state.selected[entry.path]
    if selected and (selected.whole or not info.patch_row or selected.lines[info.patch_row]) then
      local opts = { sign_text = '✓', sign_hl_group = 'GitSignsAdd', priority = 120 }
      if not info.patch_row then
        opts.virt_text = { { selected.whole and ' [collected]' or ' [partly collected]', 'GitPanelKey' } }
        opts.virt_text_pos = 'eol'
      end
      vim.api.nvim_buf_set_extmark(left, ns, i - 1, 0, opts)
    end
  end
end
return M

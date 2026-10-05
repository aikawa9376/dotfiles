-- Normal panel keys. Magit's transient specifications are deliberately separate.
local M = {}
local utils = require('git.utils')
local configured = {}
local panels = {
  fugitivestatus = 'status', fugitivelog = 'log', fugitivebranch = 'branch',
  fugitivereflog = 'reflog', fugitivestash = 'stash', fugitiveworktree = 'worktree',
  fugitivecommit = 'commit', gitwip = 'wip',
}

local function mapping(buf, key, mode)
  return vim.api.nvim_buf_call(buf, function() return vim.fn.maparg(key, mode or 'n', false, true) end)
end

local function bind(buf, key, callback, label, mode, nowait)
  vim.keymap.set(mode or 'n', key, callback,
    { buffer = buf, silent = true, nowait = nowait ~= false, desc = label })
end

local function invoke(map)
  if map.callback then return map.callback() end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(map.rhs, true, false, true), 'n', false)
end

function M.context(buf)
  local state = configured[buf]
  if state and state.context then return state.context() end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ''
  local panel = panels[vim.bo[buf].filetype]
  if panel == 'reflog' then
    local entry = require('git.features.reflog').entry_at(buf, row)
    if entry then return { kind = 'reflog', commit = entry.hash, value = entry.selector, label = entry.selector .. ' (' .. entry.short_hash .. ')' } end
  elseif panel == 'branch' then
    local ref = (vim.b[buf].branch_map or {})[row]
    if ref then return { kind = 'branch', branch = ref, value = ref, label = ref } end
  elseif panel == 'worktree' then
    local entry = (vim.b[buf].worktree_entries or {})[row]
    if entry then return { kind = 'worktree', path = entry.path, value = entry.path, label = entry.path } end
  elseif panel == 'stash' then
    local ref = line:match('^(stash@{%d+})')
    if ref then return { kind = 'stash', stash = ref, value = ref, label = ref } end
  elseif panel == 'log' then
    local hash = line:match('^(%x%x%x%x%x%x%x+)%s')
    if hash then return { kind = 'commit', commit = hash, value = hash:sub(1, 7), label = hash:sub(1, 7) } end
  end
  return { kind = 'repository', label = 'Repository' }
end

local function copy(buf)
  local ctx = M.context(buf)
  local value = ctx.value or ctx.stash or ctx.branch or ctx.path or (ctx.commit and ctx.commit:sub(1, 7))
  if not value then vim.notify('No identifier at cursor', vim.log.levels.INFO); return end
  vim.fn.setreg('"', value); vim.fn.setreg('+', value)
  vim.notify('Copied: ' .. value, vim.log.levels.INFO)
end

local function info(buf)
  local ctx = M.context(buf)
  local object = ctx.commit or ctx.branch or ctx.stash
  if not object then vim.notify('No commit or ref at cursor', vim.log.levels.INFO); return end
  require('git.features.commands').show_commit_info_float(object, true, true)
end

local labels = {
  ['<CR>'] = 'Open selected item', ['<2-LeftMouse>'] = 'Open selected item',
  q = 'Close panel', R = 'Refresh panel', o = 'Toggle selected diff', ['='] = 'Toggle selected diff',
  ['>'] = 'Expand selected diff', ['<'] = 'Collapse selected diff',
  ['[m'] = 'Previous file', [']m'] = 'Next file', ['[/'] = 'Previous file', [']/'] = 'Next file',
  ['[c'] = 'Previous hunk', [']c'] = 'Next hunk', J = 'Next hunk', K = 'Previous hunk',
  ['[['] = 'Previous file and expand', [']]'] = 'Next file and expand',
  ['('] = 'Previous item', [')'] = 'Next item', i = 'Expand and move to next diff item',
  gf = 'Open worktree file', gq = 'Populate file quickfix',
  d = 'Compare selected item', dd = 'Vertical diff', dv = 'Vertical diff', dh = 'Horizontal diff', ds = 'Horizontal diff',
  D = 'Diffview for entire commit', A = 'Edit commit message', cw = 'Edit selected message or name',
  a = 'Apply selected patch or snapshot', cv = 'Reverse selected patch', X = 'Discard / remove selected item',
  ['~'] = 'Open parent commit', p = 'Previous commit affecting selected file', gp = 'Select comparison parent',
  C = 'Show commit information', O = 'Open pull request', ['<C-Space>'] = 'Toggle graph',
}

local function dynamic_label(key, ctx, fallback)
  local target = ctx.label or ctx.value or ctx.path or ctx.commit
  if key == 'gy' then return 'Copy identifier: ' .. (target or 'no selected item') end
  if key == 'cw' then
    if ctx.kind == 'stash' then return 'Rename stash: ' .. target end
    if ctx.kind == 'branch' then return 'Rename branch: ' .. target end
    if ctx.commit then return 'Edit commit message: ' .. target end
  end
  if key == 'X' then
    if ctx.kind == 'commit_patch' then return 'Remove commit changes (Hard / Mixed): ' .. target end
    local action = ({ commit = 'Drop commit', stash = 'Drop stash', branch = 'Delete branch',
      worktree = 'Remove worktree', index_flag = 'Clear index flag', reflog = 'Reset HEAD to' })[ctx.kind]
    if ctx.entry then
      action = ctx.entry.section == 'conflicted' and 'Keep ours / resolve conflict'
        or ctx.entry.section == 'untracked' and 'Delete untracked path'
        or 'Discard ' .. ctx.entry.section .. (ctx.in_hunk and ' hunk' or ' changes')
    end
    if action then return action .. ': ' .. target end
  end
  return fallback
end

function M.help(buf)
  local state = configured[buf] or {}
  if state.help then return state.help() end
  local ctx = M.context(buf)
  local lines = { 'Target: ' .. (ctx.label or 'Repository'), '' }
  local entries, key_width = {}, 0
  local maps = vim.api.nvim_buf_get_keymap(buf, 'n')
  local menu_heading
  local by_key, aliases = {}, {}
  for _, map in ipairs(maps) do by_key[map.lhs] = map end
  local display = {}
  for _, family in ipairs({
    { 'd', 'dd', 'dv' }, { 'dh', 'ds' }, { 'o', '=' },
    { ']m', ']/' }, { '[m', '[/' }, { 'J', ']c' }, { 'K', '[c' },
  }) do
    local present = {}
    for _, key in ipairs(family) do if by_key[key] then present[#present + 1] = key end end
    if #present > 0 then
      display[present[1]] = table.concat(present, ' / ')
      for index = 2, #present do aliases[present[index]] = true end
    end
  end
  -- Mouse/close/help aliases add little to a keyboard guide; the footer closes it.
  aliases['<2-LeftMouse>'], aliases.q, aliases['?'] = true, true, true
  table.sort(maps, function(a, b) return a.lhs < b.lhs end)
  for _, map in ipairs(maps) do
    local has_identifier = ctx.value or ctx.stash or ctx.branch or ctx.path or ctx.commit
    local has_commit = ctx.commit or ctx.branch or ctx.stash
    local irrelevant = (map.lhs == 'gy' and not has_identifier) or (map.lhs == 'C' and not has_commit)
    local menu_key = map.lhs == '  ' or map.lhs == '<Space><Space>'
    if menu_key and map.desc then menu_heading = map.desc end
    if not menu_key and not (state.hidden or {})[map.lhs] and not aliases[map.lhs] and not irrelevant then
      local label = dynamic_label(map.lhs, ctx, map.desc or labels[map.lhs])
      if map.lhs == 'X' and vim.bo[buf].filetype == 'fugitivecommit' and ctx.kind == 'commit' then
        label = 'Select a changed file or hunk to remove its changes (Hard / Mixed)'
      end
      if label then
        local key = display[map.lhs] or map.lhs:gsub(' ', '<Space>')
        entries[#entries + 1] = { key = key, label = label }
        key_width = math.max(key_width, vim.fn.strdisplaywidth(key))
      end
    end
  end
  local headings = { ['Visual selections'] = true }
  if menu_heading then
    headings[menu_heading], headings['Panel keys'] = true, true
    vim.list_extend(lines, { menu_heading, '<Space><Space>  Open menu', '', 'Panel keys' })
  end
  for _, entry in ipairs(entries) do
    lines[#lines + 1] = entry.key .. string.rep(' ', key_width - vim.fn.strdisplaywidth(entry.key) + 2) .. entry.label
  end
  local visual = {}
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'x')) do
    if map.desc and map.lhs ~= '  ' and map.lhs ~= '<Space><Space>' then
      local key = map.lhs:gsub(' ', '<Space>')
      visual[#visual + 1] = key .. string.rep(' ', math.max(2, 14 - vim.fn.strdisplaywidth(key))) .. map.desc
    end
  end
  if #visual > 0 then
    table.sort(visual); vim.list_extend(lines, { '', 'Visual selections' }); vim.list_extend(lines, visual)
  end
  vim.list_extend(lines, state.guide or {})
  return require('git.features.help').show_text('Git ' .. (panels[vim.bo[buf].filetype] or 'panel'), lines, { headings = headings })
end

-- A non-Magit action chooser; captures the source row so refresh cannot retarget it.
local function chooser(buf, title, actions)
  local win = vim.api.nvim_get_current_win()
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
  local ctx = M.context(buf)
  local choices = {}
  for index, action in ipairs(actions) do
    choices[#choices + 1] = { key = tostring(index), label = action.label, callback = function()
      if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then return end
      if vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] ~= line then
        vim.notify('Selected item changed; reopen the action chooser', vim.log.levels.WARN); return
      end
      vim.api.nvim_set_current_win(win); vim.api.nvim_win_set_cursor(win, { row, 0 })
      action.callback()
    end }
  end
  return require('git.features.action_menu').show(title, { { title = 'Actions', actions = choices } }, { context = ctx.label })
end

function M.configure(buf, opts)
  opts = opts or {}
  local state = { context = opts.context, help = opts.help, guide = opts.guide, hidden = {}, history = {}, display = {}, operations = {} }
  configured[buf] = state
  local panel = panels[vim.bo[buf].filetype]
  local function move(old, new, group, label, keep)
    local map = mapping(buf, old)
    if map.buffer ~= 1 or not (map.callback or map.rhs) then return end
    local callback = function() return invoke(map) end
    if new then bind(buf, new, callback, label or map.desc, 'n', map.nowait == 1) end
    if group then state[group][#state[group] + 1] = { label = label or map.desc or old, callback = callback } end
    if keep then state.hidden[map.lhs] = true else vim.keymap.del('n', old, { buffer = buf }) end
  end
  -- These aliases are still called by Magit's existing_key(). Do not modify that layer.
  for _, pair in ipairs({ { 'bs', 'cos' }, { 'bS', 'coS' } }) do move(pair[1], pair[2], nil, nil, true) end
  move('bw', 'cw'); move('bu', 'cou'); move('bU', 'coU')
  move('cot', 'cZt'); move('gws', 'cZs')
  if panel == 'worktree' then move('gs', 'cZs', nil, 'Sync primary to selected HEAD', true); move('a', 'cZa', nil, 'Add worktree') end
  if panel == 'status' then
    move('co', 'mo'); move('ct', 'mt'); move('cr', 'mr')
    for _, key in ipairs({ 'mi', 'mu', 'ms' }) do move(key, nil, 'operations') end
    move('mU', nil, 'operations', 'Set current branch upstream')
    move('P', nil)
    move('rD', 'dR', nil, 'Compare outgoing stack with range-diff')
    for _, key in ipairs({ 'cF', 'cW', 'cs', 'cn', 'cS' }) do move(key, nil, 'history') end
  elseif panel == 'stash' then
    move('A', 'a'); move('P', 'czp')
  elseif panel == 'branch' then
    move('<Leader>gp', nil, 'operations', 'Push current branch with force-with-lease')
    move('cP', nil, 'operations', 'Cherry-pick clipboard commits')
    move('f', nil, 'operations', 'Fetch all remotes')
    move('p', nil, 'operations', 'Pull current branch')
    move('P', nil, 'operations', 'Pull selected branch')
    move('r<Space>', nil, 'operations', 'Stash, fetch, rebase selected branch')
    move('m<Space>', nil, 'operations', 'Merge selected branch')
    bind(buf, 'B', '<Cmd>Gbranch<CR>', 'Open branch list')
  elseif panel == 'reflog' then
    move('B', 'con', nil, 'Create rescue branch at selected destination', true)
    move('<C-y>', nil, 'operations', 'Copy selected commit hash')
    state.hidden.y = true -- selector alias used by Magit
  elseif panel == 'log' then
    move('<Leader>R', nil, 'history', 'Reset HEAD to selected commit (mixed)')
    move('<M-j>', nil, 'history', 'Move commit down')
    move('<M-k>', nil, 'history', 'Move commit up')
  elseif panel == 'commit' then
    move('gA', nil, 'history', 'Edit message in a float')
  end
  move('<Leader>cf', nil, 'history', 'Fixup selected commit into its parent')
  move('<Leader>wd', nil, 'display', 'Cycle word-diff style')
  if panel == 'status' or panel == 'commit' then
    state.display[#state.display + 1] = { label = 'Toggle diff foreground colors', callback = function()
      local value = require('git.features.syntax_highlight').toggle_changed_fg()
      vim.notify('Diff foreground: ' .. value, vim.log.levels.INFO)
    end }
  end
  local old_copy = mapping(buf, '<C-y>', 'x')
  if old_copy.buffer == 1 and old_copy.callback then
    bind(buf, 'gy', old_copy.callback, 'Copy selected commit hashes', 'x')
    vim.keymap.del('x', '<C-y>', { buffer = buf })
  end
  if mapping(buf, '<C-y>').buffer == 1 then vim.keymap.del('n', '<C-y>', { buffer = buf }) end
  bind(buf, 'gy', function() copy(buf) end, 'Copy selected identifier')
  if mapping(buf, 'C').buffer ~= 1 then bind(buf, 'C', function() info(buf) end, 'Show selected commit/ref information') end
  bind(buf, '?', function() M.help(buf) end, 'Show contextual key guide')
  for key, title in pairs({ history = 'History editing', display = 'Display settings', operations = 'Repository actions' }) do
    if #state[key] > 0 then
      local actions = state[key]
      local shortcut = ({ history = 'gH', display = 'gD', operations = 'gO' })[key]
      bind(buf, shortcut, function() chooser(buf, title, actions) end, title .. ' chooser')
    end
  end
  -- Short d must wait for dd/dv/dh/ds/dR regardless of registration order.
  local d = mapping(buf, 'd')
  if d.buffer == 1 and (panel == 'status' or panel == 'commit') then
    bind(buf, 'd', d.callback or d.rhs, d.desc or 'Compare selected item', 'n', false)
  end
  for _, key in ipairs({ 'X', 'gr' }) do
    local select = mapping(buf, key, 's')
    if select.buffer == 1 then vim.keymap.del('s', key, { buffer = buf }) end
  end
  vim.api.nvim_create_autocmd({ 'BufUnload', 'BufWipeout' }, { buffer = buf, once = true, callback = function()
    if configured[buf] == state then configured[buf] = nil end
  end })
end

return M

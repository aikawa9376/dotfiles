-- A directory view over the same porcelain-v2 model used by Status.
local M = {}
local renderer = require('git.features.status_renderer')
local workflow = require('git.features.workflow')
local utils = require('git.utils')
local display = require('git.features.change_display')
local states = {}
local ns = vim.api.nvim_create_namespace('GitStatusTree')
local sections = { 'conflicted', 'untracked', 'unstaged', 'staged' }
local titles = { conflicted = 'Unmerged paths', untracked = 'Untracked files', unstaged = 'Unstaged changes', staged = 'Staged changes' }
local function escape(text) return text:gsub('\n', '\\n'):gsub('\r', '\\r') end
local function key(node) return node.section .. '\0' .. node.path end
local function collect(node, result)
  if node.entry then result[#result + 1] = node.entry else
    for _, child in ipairs(node.children) do collect(child, result) end
  end
  return result
end
local function build(entries, section)
  local root = { path = '', name = titles[section], section = section, children = {}, dirs = {} }
  for _, entry in ipairs(entries) do
    local parent, prefix = root, ''
    local parts = vim.split(entry.path, '/', { plain = true, trimempty = true })
    for i = 1, #parts - 1 do
      prefix = prefix .. parts[i] .. '/'
      if not parent.dirs[parts[i]] then
        local dir = { path = prefix, name = parts[i], section = section, children = {}, dirs = {} }
        parent.dirs[parts[i]] = dir; parent.children[#parent.children + 1] = dir
      end
      parent = parent.dirs[parts[i]]
    end
    parent.children[#parent.children + 1] = { path = entry.path, name = parts[#parts], section = section, entry = entry }
  end
  local function sort(node)
    if node.entry then return end
    table.sort(node.children, function(a,b) if (a.entry == nil) ~= (b.entry == nil) then return a.entry == nil end; return a.name < b.name end)
    for _, child in ipairs(node.children) do sort(child) end
  end
  sort(root); return root
end
local function render(buf)
  local state = states[buf]; if not state or not vim.api.nvim_buf_is_valid(buf) then return end
  local win = vim.fn.bufwinid(buf)
  local row = win ~= -1 and vim.api.nvim_win_get_cursor(win)[1] or 1
  local selected = state.rows and state.rows[row]
  local selected_key = selected and key(selected)
  local lines, rows, colors = { 'Changed files · ' .. escape(state.root), 'o/Tab fold  s stage/unstage  u unstage  d diff  R refresh  Space Space actions', '' }, {}, {}
  local function append(node, depth)
    local text, color
    if node.entry then
      local shown = vim.deepcopy(node.entry); shown.path = node.name
      -- Keep rename origin visible, including when it lives in another directory.
      shown.display_path = nil
      text = string.rep('  ', depth) .. display.line(shown):gsub('\n', '\\n'):gsub('\r', '\\r')
      color = node.section == 'conflicted' and 'DiagnosticError' or node.entry.status == 'D' and 'GitSignsDelete'
        or (node.entry.status == 'A' or node.entry.status == '?') and 'GitSignsAdd'
        or vim.tbl_contains({ 'M', 'R', 'C' }, node.entry.status) and 'GitSignsChange' or 'Normal'
    else
      text = string.rep('  ', depth) .. (state.closed[key(node)] and '▸ ' or '▾ ') .. escape(node.name) .. ' (' .. #collect(node, {}) .. ')'
      color = depth == 0 and 'Title' or 'Directory'
    end
    lines[#lines + 1] = text; rows[#lines] = node; colors[#lines] = color
    if not node.entry and not state.closed[key(node)] then for _, child in ipairs(node.children) do append(child, depth + 1) end end
  end
  for _, section in ipairs(sections) do
    local tree = build(state.entries[section] or {}, section)
    if #tree.children > 0 then append(tree, 0); lines[#lines + 1] = '' end
  end
  state.rows = rows
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable, vim.bo[buf].modified = false, false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for at, color in pairs(colors) do
    vim.api.nvim_buf_set_extmark(buf, ns, at - 1, 0, { line_hl_group = color,
      virt_text = rows[at].entry and display.statistics(rows[at].entry) or nil })
  end
  if win ~= -1 then
    if selected_key then for at, node in pairs(rows) do if key(node) == selected_key then row = at; break end end end
    vim.api.nvim_win_set_cursor(win, { math.min(row, #lines), 0 })
  end
end
function M.entry_at(buf, row) local state = states[buf]; return state and state.rows[row] end
function M.refresh(buf)
  local state = states[buf]; if not state then return end
  state.generation = state.generation + 1; local generation = state.generation
  renderer.snapshot_async(state.modelbuf, state.root, { is_current = function() return states[buf] == state and generation == state.generation end }, function(lines, err)
    if not lines then vim.notify(err, vim.log.levels.WARN); return end
    local entries, seen = {}, {}
    for _, section in ipairs(sections) do entries[section] = {} end
    for row = 1, #lines do
      local entry = renderer.entry_at(state.modelbuf, row)
      if entry and not entry.header and not seen[entry] then entries[entry.section][#entries[entry.section] + 1] = entry; seen[entry] = true end
    end
    state.entries = entries; render(buf)
  end)
end
function M.toggle(buf, row)
  local state, node = states[buf], M.entry_at(buf, row)
  if not node or node.entry then return end
  state.closed[key(node)] = not state.closed[key(node)]; render(buf)
end
function M.change_index(buf, row, action)
  local state, node = states[buf], M.entry_at(buf, row)
  if not node then return end
  if action == 'unstage' and node.section ~= 'staged' then vim.notify('Select staged files to unstage', vim.log.levels.WARN); return end
  local entries, paths, seen = collect(node, {}), {}, {}
  for _, entry in ipairs(entries) do
    local entry_paths = { entry.path }
    if entry.old_path and entry.status == 'R' then entry_paths[#entry_paths + 1] = entry.old_path end
    for _, path in ipairs(entry_paths) do if not seen[path] then paths[#paths + 1] = path; seen[path] = true end end
  end
  local unstage = action == 'unstage' or node.section == 'staged'
  local args = { '--literal-pathspecs', unstage and 'reset' or 'add', '--' }; vim.list_extend(args, paths)
  return workflow.run(state.root, args, { callback = function(ok, err)
    if not ok then vim.notify(err, vim.log.levels.ERROR) end
    if states[buf] then M.refresh(buf) end
  end })
end
function M.open(opts)
  opts = opts or {}; local root = opts.work_tree or utils.get_buf_work_tree(0)
  if not root then vim.notify('Git work tree not found', vim.log.levels.WARN); return end
  utils.open_panel_split()
  local buf = vim.api.nvim_create_buf(false, true); vim.api.nvim_win_set_buf(0, buf)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile, vim.bo[buf].filetype = 'nofile', 'wipe', false, 'gitstatustree'
  vim.api.nvim_buf_set_name(buf, 'git-status-tree://' .. buf)
  utils.set_buf_work_tree(buf, root)
  local state = { root = root, modelbuf = vim.api.nvim_create_buf(false, true), closed = {}, rows = {}, entries = {}, generation = 0 }
  states[buf] = state
  require('git.features.magit_actions').attach(buf)
  local function selected() return vim.api.nvim_win_get_cursor(0)[1] end
  for _, lhs in ipairs({ 'o', '<Tab>' }) do vim.keymap.set('n', lhs, function() M.toggle(buf, selected()) end, { buffer = buf }) end
  vim.keymap.set('n', '<CR>', function()
    local node = M.entry_at(buf, selected()); if not node then return end
    if not node.entry then M.toggle(buf, selected()); return end
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/' .. node.path))
  end, { buffer = buf })
  vim.keymap.set('n', 's', function() M.change_index(buf, selected(), 'toggle') end, { buffer = buf })
  vim.keymap.set('n', 'u', function() M.change_index(buf, selected(), 'unstage') end, { buffer = buf })
  vim.keymap.set('n', 'd', function()
    local node = M.entry_at(buf, selected()); if not node then return end
    local paths = vim.tbl_map(function(entry) return entry.path end, collect(node, {}))
    local ok, err = require('git.features.commit_diff').open_paths(root, paths, node.section)
    if not ok then vim.notify(err, vim.log.levels.WARN) end
  end, { buffer = buf })
  vim.keymap.set('n', 'R', function() M.refresh(buf) end, { buffer = buf })
  vim.keymap.set('n', 'q', '<Cmd>close<CR>', { buffer = buf })
  local group = vim.api.nvim_create_augroup('GitStatusTree' .. buf, { clear = true })
  vim.api.nvim_create_autocmd('User', { group = group, pattern = 'FugitiveChanged', callback = function(ev)
    if not ev.data or not ev.data.work_tree or ev.data.work_tree == root then M.refresh(buf) end
  end })
  vim.api.nvim_create_autocmd('BufEnter', { group = group, buffer = buf, callback = function() M.refresh(buf) end })
  vim.api.nvim_create_autocmd('BufWipeout', { group = group, buffer = buf, once = true, callback = function()
    states[buf] = nil; renderer.cleanup(state.modelbuf)
    if vim.api.nvim_buf_is_valid(state.modelbuf) then vim.api.nvim_buf_delete(state.modelbuf, { force = true }) end
    vim.api.nvim_del_augroup_by_id(group)
  end })
  M.refresh(buf); return buf
end
return M

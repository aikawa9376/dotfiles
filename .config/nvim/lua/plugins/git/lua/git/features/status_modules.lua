-- Providers own data and actions. This module owns their projection into Status.
local M = {}
local sections = require('git.features.status_sections')
local loading = require('git.features.loading')
local definitions, states = {}, {}
local ns = vim.api.nvim_create_namespace('git_status_modules')
local function setup_item_highlight()
  local normal = vim.api.nvim_get_hl(0, { name = 'Normal', link = false })
  vim.api.nvim_set_hl(0, 'GitStatusModuleItem', { fg = normal.fg, ctermfg = normal.ctermfg })
end
vim.api.nvim_create_autocmd('ColorScheme', {
  group = vim.api.nvim_create_augroup('GitStatusModuleHighlights', { clear = true }), callback = setup_item_highlight,
})
local function clean(value) return tostring(value or ''):gsub('[%z\1-\31\127]', ' ') end
local function identity(info)
  return info.definition.id .. '\0' .. info.kind .. '\0' .. (info.item and info.item.id or '')
end
function M.enabled() return #definitions > 0 end
function M.setup(specs)
  local seen, next_definitions = {}, {}
  for _, spec in ipairs(specs or {}) do
    assert(type(spec.id) == 'string' and spec.id:match('^[%w_-]+$'), 'Status module needs a stable id')
    assert(not seen[spec.id], 'Duplicate Status module: ' .. spec.id)
    assert(type(spec.title) == 'string' and spec.title ~= '', 'Status module needs a title')
    assert(type(spec.load) == 'function', 'Status module needs load(context, done)')
    assert(spec.open == nil or type(spec.open) == 'function', 'Invalid Status module open action')
    assert(not (spec.before and spec.after), 'Status module accepts either before or after')
    assert(sections.valid(spec.before or spec.after or 'bottom'), 'Unknown Status module placement')
    seen[spec.id] = true
    next_definitions[#next_definitions + 1] = vim.deepcopy(spec)
  end
  definitions = next_definitions
end
function M.attach(buf, changed)
  M.cleanup(buf)
  local state = { changed = changed, results = {}, marks = {}, generation = 0, cancels = {}, finishes = {} }
  states[buf] = state
  state.group = vim.api.nvim_create_augroup('GitStatusModules' .. buf, { clear = true })
  local scheduled = false
  for _, definition in ipairs(definitions) do
    for _, event in ipairs(definition.events or {}) do
      vim.api.nvim_create_autocmd(event.event, { group = state.group, pattern = event.pattern, callback = function()
        if scheduled then return end
        scheduled = true
        vim.schedule(function()
          scheduled = false
          if states[buf] == state then M.refresh(buf) end
        end)
      end })
    end
  end
end
local function cancel(state)
  state.generation = state.generation + 1
  for _, stop in ipairs(state.cancels) do pcall(stop) end
  for _, finish in ipairs(state.finishes) do finish() end
  state.cancels = {}
  state.finishes = {}
end
local function normalize(items)
  assert(type(items) == 'table', 'Status module must return a list of items')
  local result, seen = {}, {}
  for _, item in ipairs(items) do
    assert(type(item) == 'table' and type(item.id) == 'string' and item.id ~= '', 'Status item needs a stable id')
    assert(not seen[item.id], 'Duplicate Status item: ' .. item.id)
    assert(type(item.text) == 'string', 'Status item needs text')
    assert(item.detail == nil or type(item.detail) == 'string', 'Status item detail must be text')
    seen[item.id] = true
    result[#result + 1] = vim.deepcopy(item)
  end
  return result
end
function M.refresh(buf, context)
  local state = states[buf]
  if not state then return end
  context = context or state.context
  if not context then return end
  local same_context = vim.deep_equal(state.context, context)
  cancel(state)
  state.context = vim.deepcopy(context)
  local generation = state.generation
  for _, definition in ipairs(definitions) do
    local finish = loading.begin(buf, 'module:' .. definition.id)
    state.finishes[#state.finishes + 1] = finish
    local previous = same_context and state.results[definition.id]
    state.results[definition.id] = { items = previous and previous.items or {}, loading = true }
    local completed = false
    local function done(items, err)
      if completed then return end
      completed = true
      vim.schedule(function()
        if states[buf] ~= state or generation ~= state.generation or not vim.api.nvim_buf_is_loaded(buf) then return end
        local ok, normalized = pcall(normalize, items or {})
        state.results[definition.id] = { items = ok and normalized or {},
          error = err or (not ok and tostring(normalized) or nil), finish = finish }
        state.changed()
      end)
    end
    -- Providers always start outside the initial status-rendering call stack.
    vim.schedule(function()
      if states[buf] ~= state or generation ~= state.generation then return end
      local ok, stop = pcall(definition.load, vim.deepcopy(context), done)
      if not ok then done(nil, (tostring(stop):gsub('^.-:%d+: ', '')))
      elseif type(stop) == 'function' then state.cancels[#state.cancels + 1] = stop end
    end)
  end
  if #definitions > 0 then state.changed() end
end
function M.rows(buf)
  local state, rows = states[buf], {}
  if not state then return rows end
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  if state.row_tick == tick then return state.row_cache end
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})) do
    if state.marks[mark[1]] then rows[mark[2] + 1] = state.marks[mark[1]] end
  end
  state.row_tick, state.row_cache = tick, rows
  return rows
end
function M.at(buf, row)
  local info = M.rows(buf)[row]
  return info and info.kind ~= 'spacer' and info or nil
end
function M.key(buf, row)
  local info = M.at(buf, row)
  return info and identity(info)
end
-- Existing Git selectors may parse the current row. Shelf presentation must
-- never become an alternate source of file, commit, stash or ref identities.
function M.git_line()
  local buf, row = vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)[1]
  return M.at(buf, row) and '' or vim.api.nvim_get_current_line()
end
function M.strip(buf, lines)
  local owned, native, mapping = M.rows(buf), {}, {}
  for row, line in ipairs(lines) do
    if not owned[row] then native[#native + 1] = line; mapping[row] = #native end
  end
  return native, mapping, owned
end
function M.compose(buf, lines)
  local state, insertions = states[buf], {}
  if not state then return lines, {}, {} end
  local ranges = sections.ranges(lines)
  for _, definition in ipairs(definitions) do
    local result = state.results[definition.id]
    if result and (#result.items > 0 or result.error or (not result.loading and definition.hide_empty == false)) then
      local anchor = definition.before or definition.after or 'bottom'
      local range = ranges[anchor]
      local position = anchor == 'top' and 0 or #lines
      if range then position = definition.before and range.first - 1 or range.last end
      insertions[position] = insertions[position] or {}
      insertions[position][#insertions[position] + 1] = { definition = definition, result = result }
    end
  end
  local projected, mapping, rows = {}, {}, {}
  for position = 0, #lines do
    if position > 0 then projected[#projected + 1] = lines[position]; mapping[position] = #projected end
    for _, insertion in ipairs(insertions[position] or {}) do
      local definition, result = insertion.definition, insertion.result
      local function append(text, kind, item)
        projected[#projected + 1] = text
        rows[#projected] = { definition = definition, kind = kind, item = item }
      end
      if #projected > 0 and projected[#projected] ~= '' then append('', 'spacer') end
      append(clean(definition.title) .. ' (' .. #result.items .. ')', 'header')
      for _, item in ipairs(result.items) do
        local detail = item.detail and item.detail ~= '' and ('  ' .. clean(item.detail)) or ''
        append(clean(item.text) .. detail, 'item', item)
      end
      if result.error then append('  Unavailable: ' .. clean(result.error), 'message')
      elseif not result.loading and #result.items == 0 then append('  No items', 'message') end
      -- Keep a following native section from becoming part of this module fold.
      if position < #lines and lines[position + 1] ~= '' then append('', 'spacer') end
    end
  end
  return projected, mapping, rows
end
function M.commit(buf, rows)
  local state = states[buf]
  if not state then return end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  state.row_tick, state.row_cache = nil, nil
  state.marks = {}
  setup_item_highlight()
  for row, info in pairs(rows) do
    -- Mask Git syntax in labels without overriding the window's background.
    local group
    if info.kind == 'header' then group = info.definition.highlight or 'Title'
    elseif info.kind == 'item' then group = info.item.highlight or 'GitStatusModuleItem'
    else group = 'Comment' end
    local opts = { right_gravity = true, line_hl_group = group }
    if info.kind == 'item' and not info.item.highlight then
      opts.line_hl_group = nil
      opts.hl_group, opts.end_col = group, #clean(info.item.text)
    end
    local id = vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, opts)
    state.marks[id] = info
    if info.kind == 'item' and info.item.detail and info.item.detail ~= '' then
      local start = #clean(info.item.text) + 2
      vim.api.nvim_buf_set_extmark(buf, ns, row - 1, start, {
        end_col = start + #clean(info.item.detail), hl_group = 'Comment', priority = 110,
      })
    end
  end
  -- A response is complete only after its projection reaches the buffer.
  for _, result in pairs(state.results) do
    if result.finish then result.finish(); result.finish = nil end
  end
end
function M.sections(buf)
  local rows, found = M.rows(buf), {}
  for row, info in pairs(rows) do if info.kind == 'header' then
    local last = row
    while rows[last + 1] and rows[last + 1].kind ~= 'spacer' do last = last + 1 end
    found[#found + 1] = { first = row, last = last, key = 'module:' .. info.definition.id,
      count = 0, folded = info.definition.folded == true }
  end end
  return found
end
function M.open(buf, row)
  local info, state = M.at(buf, row), states[buf]
  if not info then return false end
  if info.kind == 'header' then require('git.features.status_folds').toggle(buf, row)
  elseif info.kind == 'item' and info.definition.open then
    local ok, err = pcall(info.definition.open, vim.deepcopy(state.context), vim.deepcopy(info.item))
    if not ok then vim.notify(tostring(err), vim.log.levels.ERROR) end
  end
  return true
end
function M.toggle(buf, row)
  local info = M.at(buf, row)
  if not info then return false end
  for header_row, header in pairs(M.rows(buf)) do
    if header.kind == 'header' and header.definition.id == info.definition.id then
      local toggled = require('git.features.status_folds').toggle(buf, header_row)
      if toggled and row ~= header_row then vim.api.nvim_win_set_cursor(0, { header_row, 0 }) end
      return true
    end
  end
  return true
end
function M.keys(lines, owned, fallback)
  local keys = fallback(lines)
  for row, info in pairs(owned) do keys[row] = 'module\0' .. identity(info) end
  return keys
end
function M.cleanup(buf)
  local state = states[buf]
  states[buf] = nil
  if state then cancel(state) end
  if state and state.group then pcall(vim.api.nvim_del_augroup_by_id, state.group) end
  if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1) end
end
return M

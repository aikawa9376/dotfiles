-- Window-owned rendering over native diff layouts. Comparators are shared
-- with unified views; neither source buffers nor native alignment are rewritten.
local M = {}
local api = vim.api
local syntax = require('git.features.syntax_highlight')
local structural = require('git.features.syntax_word_diff')
local jobs = require('git.features.highlight_jobs')
local sessions, windows = {}, {}
local ns = api.nvim_create_namespace('git_split_diff')
local initialized, scheduled = false, false
local frames = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
local neutral = { DiffAdd = true, DiffChange = true, DiffText = true, DiffTextAdd = true }
local refresh, discover

local function diff_side(win, buf)
  if vim.wo[win].diff then return true end
  local side = vim.w[win].git_split_side
  -- Diffview deliberately disables diff mode on an absent file's null pane.
  return api.nvim_buf_get_name(buf) == 'diffview://null' and type(side) == 'table'
    and side.buf == buf and type(side.layout) == 'string' and side.layout:match('^diff2') ~= nil
end
local function alive(s)
  if not s.active then return false end
  for _, side in ipairs({ 'old', 'new' }) do
    local win, buf = s[side].win, s[side].buf
    if not api.nvim_win_is_valid(win) or api.nvim_win_get_buf(win) ~= buf
      or not api.nvim_buf_is_loaded(buf) or not diff_side(win, buf) then return false end
  end
  return true
end
local function current(s, revision)
  return alive(s) and s.revision == revision
    and s.old.tick == api.nvim_buf_get_changedtick(s.old.buf)
    and s.new.tick == api.nvim_buf_get_changedtick(s.new.buf)
    and s.style == syntax.config.word_diff_style
end
local function redraw(s)
  for _, side in ipairs({ 'old', 'new' }) do
    if api.nvim_win_is_valid(s[side].win) then api.nvim__redraw({ win = s[side].win, valid = false }) end
  end
end
local function mappings(value)
  local result = {}
  for item in value:gmatch('[^,]+') do
    local key, target = item:match('^([^:]+):(.+)$')
    if key then result[key] = target end
  end
  return result
end
local function mask_native(side, restore)
  if not api.nvim_win_is_valid(side.win) then return end
  local mapped = mappings(vim.wo[side.win].winhighlight)
  if not restore then
    side.saved = side.saved or {}
    for key in pairs(neutral) do
      if mapped[key] ~= 'GitSplitDiffNeutral' then side.saved[key] = mapped[key] or false end
      mapped[key] = 'GitSplitDiffNeutral'
    end
  else
    for key, target in pairs(side.saved or {}) do
      if mapped[key] == 'GitSplitDiffNeutral' then mapped[key] = target or nil end
    end
  end
  local items = {}
  for key, target in pairs(mapped) do items[#items + 1] = key .. ':' .. target end
  table.sort(items)
  vim.wo[side.win].winhighlight = table.concat(items, ',')
end
local function close(s)
  if not s.active then return end
  s.active, s.pending, s.sources = false, false, nil
  sessions[s.old.win] = nil
  for _, side in ipairs({ 'old', 'new' }) do
    windows[s[side].win] = nil
    mask_native(s[side], true)
  end
  redraw(s)
end
local function schedule()
  if scheduled then return end
  scheduled = true
  vim.defer_fn(function() scheduled = false; discover() end, 16)
end
local function add(plan, row, col, options)
  plan[row] = plan[row] or {}
  plan[row][#plan[row] + 1] = { col = col, options = options }
end
local function publish(s, revision, changes)
  if not current(s, revision) or s.painting_revision == revision then return end
  s.painting_revision = revision
  jobs.run(function(checkpoint)
    local plan = { old = {}, new = {} }
    local structural_style = s.style == 'treesitter'
    for _, side in ipairs({ 'old', 'new' }) do
      local rows, lines = s.changed[side], s[side].lines
      local count = 0
      for row in pairs(rows) do
        count = count + 1
        if count % 32 == 0 then checkpoint() end
        local added = side == 'new'
        if not structural_style then
          add(plan[side], row, 0, { end_row = row + 1, end_col = 0, hl_eol = true,
            hl_group = added and 'GitExtAdd' or 'GitExtDelete', priority = 200 })
        end
        for _, level in ipairs({ { changes[side], structural_style and (added and 'GitExtSyntaxAdd' or 'GitExtSyntaxDelete')
            or (added and 'GitExtAddText' or 'GitExtDeleteText'), 360 },
          { changes.emphasis and changes.emphasis[side] or {}, added and 'GitExtSyntaxAddText' or 'GitExtSyntaxDeleteText', 361 } }) do
          for _, range in ipairs(syntax.merge_ranges(level[1][row + 1], lines[row + 1])) do
            local first, last = math.max(0, range[1] - 1), math.min(#lines[row + 1], range[2])
            if last > first then
              add(plan[side], row, first, { end_col = last, hl_group = level[2], priority = level[3] })
              if structural_style and syntax.config.changed_fg == 'difft' then
                add(plan[side], row, first, { end_col = last,
                  hl_group = added and 'GitExtNovelAdd' or 'GitExtNovelDelete', priority = 362 })
              end
            end
          end
        end
      end
    end
    return plan
  end, function() return current(s, revision) end, function(plan)
    if not plan or not current(s, revision) then return end
    s.plan, s.pending = plan, false
    redraw(s)
  end)
end
local function compare(s, revision)
  if not current(s, revision) then return end
  local result, pending
  if s.sources and s.sources.old and s.sources.new then
    result, pending = structural.compare_async(s.sources.old, s.sources.new, s.new.buf, nil, nil, true)
  end
  if pending then return end
  if result then publish(s, revision, result); return end
  if s.fallback_revision == revision then return end
  s.fallback_revision = revision
  jobs.run(function(checkpoint)
    return structural.text_fallback(s.old.lines, s.new.lines, checkpoint)
  end, function() return current(s, revision) end, function(changes)
    if changes then publish(s, revision, changes) end
  end)
end
refresh = function(s)
  if not alive(s) then close(s); return end
  local style = syntax.config.word_diff_style
  local opts = vim.mpack.encode(syntax.diff_opts())
  local fg = syntax.config.changed_fg
  local old_tick, new_tick = api.nvim_buf_get_changedtick(s.old.buf), api.nvim_buf_get_changedtick(s.new.buf)
  if s.old.tick == old_tick and s.new.tick == new_tick and s.style == style and s.opts == opts and s.fg == fg then
    if s.pending and s.sources and not s.parsing then compare(s, s.revision) end
    return
  end
  local changed = s.old.tick ~= old_tick or s.new.tick ~= new_tick
  if s.parsing then s.sources = nil end
  s.revision, s.style, s.opts, s.fg = s.revision + 1, style, opts, fg
  s.old.tick, s.new.tick = old_tick, new_tick
  if changed then
    s.sources = nil
    for _, side in ipairs({ 'old', 'new' }) do s[side].lines = api.nvim_buf_get_lines(s[side].buf, 0, -1, false) end
    s.blocks = nil
  end
  s.plan, s.pending, s.parsing = { old = {}, new = {} }, true, false
  local revision = s.revision
  jobs.run(function(checkpoint)
    local diff_opts = syntax.diff_opts()
    diff_opts.result_type = 'indices'
    local blocks = vim.diff(table.concat(s.old.lines, '\n') .. '\n', table.concat(s.new.lines, '\n') .. '\n', diff_opts)
    s.changed = { old = {}, new = {} }
    for _, block in ipairs(blocks) do
      for _, side in ipairs({ { 'old', 1 }, { 'new', 3 } }) do
        for row = block[side[2]], block[side[2]] + block[side[2] + 1] - 1 do s.changed[side[1]][row - 1] = true end
      end
      checkpoint()
    end
    s.blocks = blocks
    return true
  end, function() return current(s, revision) end, function(done, err)
    if not done then if err ~= 'cancelled' then close(s); vim.notify('Split diff: ' .. tostring(err), vim.log.levels.WARN) end; return end
    if #s.blocks == 0 then publish(s, revision, { old = {}, new = {} }); return end
    if style ~= 'treesitter' then
      jobs.run(function(checkpoint)
        local result = { old = {}, new = {} }
        for _, block in ipairs(s.blocks) do
          local old = block[2] > 0 and vim.list_slice(s.old.lines, block[1], block[1] + block[2] - 1) or {}
          local new = block[4] > 0 and vim.list_slice(s.new.lines, block[3], block[3] + block[4] - 1) or {}
          local ranges = syntax.word_diff_ranges(old, new, style)
          for _, side in ipairs({ { 'old', 1 }, { 'new', 3 } }) do
            for row, spans in pairs(ranges[side[1]]) do result[side[1]][block[side[2]] + row - 1] = spans end
          end
          checkpoint()
        end
        return result
      end, function() return current(s, revision) end, function(result) if result then publish(s, revision, result) end end)
    elseif s.sources then compare(s, revision)
    else
      s.parsing = true
      s.sources = {}
      local remaining = 2
      local ft = vim.bo[s.new.buf].filetype ~= '' and vim.bo[s.new.buf].filetype or vim.bo[s.old.buf].filetype
      local lang = ft ~= '' and vim.treesitter.language.get_lang(ft) or nil
      for _, side in ipairs({ 'old', 'new' }) do
        structural.parse_async(s[side].lines, lang, function() return current(s, revision) end, function(source)
          if not current(s, revision) then return end
          s.sources[side] = source or false
          remaining = remaining - 1
          if remaining == 0 then s.parsing = false; compare(s, revision) end
        end)
      end
    end
  end)
  redraw(s)
  api.nvim_exec_autocmds('User', { pattern = 'GitSplitDiffPending', modeline = false })
end

function M.attach(old_win, new_win)
  M.setup()
  if not api.nvim_win_is_valid(old_win) or not api.nvim_win_is_valid(new_win) or old_win == new_win then return end
  local old_buf, new_buf = api.nvim_win_get_buf(old_win), api.nvim_win_get_buf(new_win)
  if old_buf == new_buf then return end
  local existing = windows[old_win]
  if existing and alive(existing) and existing.old.win == old_win and existing.new.win == new_win then
    mask_native(existing.old, false); mask_native(existing.new, false)
    refresh(existing); return existing
  end
  for _, win in ipairs({ old_win, new_win }) do if windows[win] then close(windows[win]) end end
  local s = { old = { win = old_win, buf = old_buf }, new = { win = new_win, buf = new_buf }, active = true, revision = 0 }
  if not alive(s) then return end
  sessions[old_win], windows[old_win], windows[new_win] = s, s, s
  for _, side in ipairs({ 'old', 'new' }) do
    mask_native(s[side], false)
    pcall(vim.treesitter.start, s[side].buf)
  end
  refresh(s)
  return s
end
function M.session(win) return windows[win or api.nvim_get_current_win()] end
function M.source_is_active(buf, old, new)
  for _, s in pairs(sessions) do
    if alive(s) and s.new.buf == buf and s.sources and s.sources.old == old and s.sources.new == new then return true end
  end
  return false
end
function M.is_pending(buf)
  for _, s in pairs(sessions) do
    if alive(s) and s.pending and (s.old.buf == buf or s.new.buf == buf) then return true end
  end
  return false
end
function M.refresh_for(buf)
  local found = false
  for _, s in pairs(sessions) do
    if s.old.buf == buf or s.new.buf == buf then refresh(s); found = true end
  end
  return found
end
function M.refresh_all()
  local found = false
  for _, s in pairs(sessions) do refresh(s); found = true end
  return found
end
local function managed(win)
  local buf = api.nvim_win_get_buf(win)
  local side = vim.w[win].git_split_side
  if type(side) == 'table' and side.buf == buf and (side.symbol == 'a' or side.symbol == 'b') then return true end
  local name = api.nvim_buf_get_name(buf)
  return name:match('^git%-object:') or name:match('^git%-diff:') or name:match('^git%-commit%-blob:')
    or name:match('^git%-blame%-diff:') or name:match('^gitsigns:') or name:match('^diffview:')
end
discover = function()
  for _, s in pairs(sessions) do if not alive(s) then close(s) else refresh(s) end end
  for _, tab in ipairs(api.nvim_list_tabpages()) do
    local diff_windows, roles, owned = {}, {}, false
    for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
      if vim.wo[win].diff then diff_windows[#diff_windows + 1] = win; owned = owned or managed(win) end
      local buf, role = api.nvim_win_get_buf(win), vim.w[win].git_split_side
      if type(role) == 'table' and role.buf == buf and type(role.layout) == 'string'
        and (role.symbol == 'a' or role.symbol == 'b')
        and role.layout:match('^diff2') and diff_side(win, buf) then roles[role.symbol] = win end
    end
    if roles.a and roles.b then M.attach(roles.a, roles.b)
    elseif #diff_windows == 2 and owned then
      table.sort(diff_windows, function(a, b)
        local ap, bp = api.nvim_win_get_position(a), api.nvim_win_get_position(b)
        return ap[1] < bp[1] or ap[1] == bp[1] and ap[2] < bp[2]
      end)
      local old, new = diff_windows[1], diff_windows[2]
      -- A working file can be physically left/above its index. Diffview's
      -- hook provides logical symbols even when the layout is rotated.
      local function symbol(win)
        local side = vim.w[win].git_split_side
        return type(side) == 'table' and side.buf == api.nvim_win_get_buf(win) and side.symbol or nil
      end
      local a, b = symbol(old), symbol(new)
      if b == 'a' or a == 'b' or not a and not b and not managed(old) and managed(new) then old, new = new, old end
      M.attach(old, new)
    elseif #diff_windows ~= 2 then
      for _, win in ipairs(diff_windows) do if windows[win] then close(windows[win]) end end
    end
  end
end
function M.setup()
  if initialized then return end
  initialized = true
  syntax.setup_groups()
  api.nvim_set_hl(0, 'GitSplitDiffNeutral', {})
  local group = api.nvim_create_augroup('GitSplitDiff', { clear = true })
  api.nvim_create_autocmd({ 'DiffUpdated', 'BufWinEnter', 'WinClosed', 'BufUnload', 'TabEnter', 'TextChanged', 'TextChangedI' }, { group = group, callback = schedule })
  api.nvim_create_autocmd('OptionSet', { group = group, pattern = { 'diff', 'diffopt' }, callback = schedule })
  api.nvim_create_autocmd('ColorScheme', { group = group, callback = function()
    api.nvim_set_hl(0, 'GitSplitDiffNeutral', {}); M.refresh_all()
  end })
  local drawing = {}
  api.nvim_set_decoration_provider(ns, {
    on_start = function() drawing = {} end,
    on_win = function(_, win, buf, top)
      local s = windows[win]
      if not s or not alive(s) or not s.plan then return false end
      local side = s.old.win == win and 'old' or 'new'
      if s[side].tick ~= api.nvim_buf_get_changedtick(buf) then return false end
      drawing[win] = { session = s, side = side, top = top }
      return true
    end,
    -- Emit only drawn rows, including when native diff folds hide huge ranges.
    -- Ephemeral marks stay scoped to this window's redraw, never its buffer.
    on_line = function(_, win, buf, row)
      local view = drawing[win]
      if not view then return end
      local s, side = view.session, view.side
      for _, mark in ipairs(s.plan[side][row] or {}) do
        local options = vim.tbl_extend('force', {}, mark.options, { ephemeral = true, strict = false })
        api.nvim_buf_set_extmark(buf, ns, row, mark.col, options)
      end
      if s.pending and row == view.top then
        api.nvim_buf_set_extmark(buf, ns, row, 0, { ephemeral = true,
          virt_text = { { frames[math.floor(vim.uv.hrtime() / 1e8) % #frames + 1], 'Comment' } }, virt_text_pos = 'eol' })
      end
    end,
  })
  local function spin()
    local pending = false
    for _, s in pairs(sessions) do if alive(s) and s.pending then redraw(s); pending = true end end
    if pending then vim.defer_fn(spin, 100) else M.spinning = false end
  end
  api.nvim_create_autocmd('User', { group = group, pattern = 'GitSplitDiffPending', callback = function()
    if not M.spinning then M.spinning = true; vim.defer_fn(spin, 100) end
  end })
  schedule()
end
return M

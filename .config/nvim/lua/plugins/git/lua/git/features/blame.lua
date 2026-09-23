local M = {}
local utils = require("git.utils")
local diffdim = require('git.features.diffdim')

local BLAME_COLORS = {
  '#50c878', '#70cd80', '#90d288', '#b0d790', '#d0dc98', '#f0e1a0', '#ffc580',
  '#ffb060', '#ff9b40', '#ff8620', '#ff7100', '#e85040', '#d03030',
}
local heatmap_ns = vim.api.nvim_create_namespace('fugitive_blame_heatmap')
local panel_winbar = '%=Blame panel%='

local function hex_rgb(color)
  color = tostring(color or ''):gsub('^#', '')
  if #color ~= 6 then return nil end
  return tonumber(color:sub(1, 2), 16), tonumber(color:sub(3, 4), 16), tonumber(color:sub(5, 6), 16)
end

local function blend_color(foreground, background, alpha)
  local fr, fg, fb = hex_rgb(foreground)
  local br, bg, bb = hex_rgb(background)
  if not fr or not br then return foreground end
  local function channel(front, back)
    return math.floor(back + (front - back) * alpha + 0.5)
  end
  return string.format('#%02x%02x%02x', channel(fr, br), channel(fg, bg), channel(fb, bb))
end

local function normal_background()
  local ok, normal = pcall(vim.api.nvim_get_hl, 0, { name = 'Normal', link = false })
  if ok and normal and normal.bg then return string.format('#%06x', normal.bg) end
  return '#1e1e2e'
end

local function first_path(value)
  if type(value) == 'table' then return tostring(value[1] or '') end
  return tostring(value or '')
end

local function setup_blame_gradients()
  local background = normal_background()
  for index, color in ipairs(BLAME_COLORS) do
    vim.api.nvim_set_hl(0, 'FugitiveBlameDate' .. (index - 1), { fg = color })
    vim.api.nvim_set_hl(0, 'FugitiveBlameHeat' .. (index - 1), {
      bg = blend_color(color, background, 0.22),
    })
  end
end

local function parse_blame_porcelain(output)
  local records = {}
  local current
  for line in tostring(output or ''):gmatch('([^\n]*)\n?') do
    local commit, final_line = line:match('^(%x+)%s+%d+%s+(%d+)')
    if commit then
      current = {
        commit = commit,
        line = tonumber(final_line),
        uncommitted = commit:match('^0+$') ~= nil,
      }
    elseif current then
      local timestamp = line:match('^author%-time%s+(%d+)$')
      if timestamp then
        current.timestamp = tonumber(timestamp)
      elseif line:sub(1, 1) == '\t' then
        records[#records + 1] = current
        current = nil
      end
    end
  end
  return records
end

local function heatmap_buckets(records, now, mode)
  now = tonumber(now) or os.time()
  mode = mode or 'absolute'
  local oldest
  local newest
  if mode == 'relative' then
    for _, record in ipairs(records or {}) do
      if not record.uncommitted and record.timestamp then
        oldest = math.min(oldest or record.timestamp, record.timestamp)
        newest = math.max(newest or record.timestamp, record.timestamp)
      end
    end
  end

  local buckets = {}
  for _, record in ipairs(records or {}) do
    local bucket = 0
    if not record.uncommitted and record.timestamp then
      if mode == 'relative' and oldest and newest and newest > oldest then
        local ratio = (record.timestamp - oldest) / (newest - oldest)
        bucket = math.floor((1 - ratio) * 12)
      elseif mode ~= 'relative' then
        local diff_seconds = math.max(0, now - record.timestamp)
        bucket = math.floor(diff_seconds / (2 * 30 * 24 * 60 * 60))
      end
    end
    buckets[record.line] = math.max(0, math.min(bucket, 12))
  end
  return buckets
end

local function clear_heatmap(bufnr)
  if utils.is_valid_buf(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, heatmap_ns, 0, -1)
  end
end

local function apply_heatmap(bufnr, records)
  if not utils.is_valid_buf(bufnr) then return end
  clear_heatmap(bufnr)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local buckets = heatmap_buckets(records, os.time(), vim.g.fugitive_blame_gradient_mode)
  for line, bucket in pairs(buckets) do
    if line >= 1 and line <= line_count then
      vim.api.nvim_buf_set_extmark(bufnr, heatmap_ns, line - 1, 0, {
        end_row = line,
        hl_group = 'FugitiveBlameHeat' .. bucket,
        hl_eol = true,
        priority = 50,
      })
    end
  end
end

function M.is_heatmap_enabled(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return utils.is_valid_buf(bufnr) and vim.b[bufnr].fugitive_blame_heatmap_enabled == true
end

function M.refresh_heatmap(bufnr, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  opts = opts or {}
  if not utils.is_valid_buf(bufnr) or not M.is_heatmap_enabled(bufnr) then return false end
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == '' or vim.bo[bufnr].buftype ~= '' then
    clear_heatmap(bufnr)
    if opts.notify ~= false then vim.notify('Git heatmap requires a normal file buffer', vim.log.levels.WARN) end
    return false
  end

  local work_tree
  if vim.fs and type(vim.fs.root) == 'function' then
    local ok, root = pcall(vim.fs.root, path, '.git')
    if ok then work_tree = root end
  end
  if not work_tree then
    local directory = vim.fn.fnamemodify(path, ':h')
    local marker = first_path(vim.fn.finddir('.git', directory .. ';'))
    if marker == '' then marker = first_path(vim.fn.findfile('.git', directory .. ';')) end
    if marker ~= '' then work_tree = vim.fn.fnamemodify(marker, ':h') end
  end
  work_tree = utils.normalize_path(work_tree)
  if not work_tree or path:sub(1, #work_tree + 1) ~= work_tree .. '/' then
    clear_heatmap(bufnr)
    if opts.notify ~= false then vim.notify('Git heatmap: file is not inside a Git worktree', vim.log.levels.WARN) end
    return false
  end
  local relative_path = path:sub(#work_tree + 2)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local input = table.concat(lines, '\n') .. '\n'
  local generation = (tonumber(vim.b[bufnr].fugitive_blame_heatmap_generation) or 0) + 1
  vim.b[bufnr].fugitive_blame_heatmap_generation = generation

  vim.system({ 'git', '-C', work_tree, 'blame', '--line-porcelain', '--contents', '-', '--', relative_path }, {
    text = true,
    stdin = input,
  }, function(result)
    vim.schedule(function()
      if not utils.is_valid_buf(bufnr)
        or not M.is_heatmap_enabled(bufnr)
        or vim.b[bufnr].fugitive_blame_heatmap_generation ~= generation
      then
        return
      end
      if result.code ~= 0 then
        clear_heatmap(bufnr)
        if opts.notify ~= false then
          local message = vim.trim(result.stderr or '')
          vim.notify('Git heatmap failed' .. (message ~= '' and ': ' .. message or ''), vim.log.levels.WARN)
        end
        return
      end
      apply_heatmap(bufnr, parse_blame_porcelain(result.stdout))
    end)
  end)
  return true
end

function M.set_heatmap_enabled(bufnr, enabled, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not utils.is_valid_buf(bufnr) then return false end
  vim.b[bufnr].fugitive_blame_heatmap_enabled = enabled == true
  if enabled then
    return M.refresh_heatmap(bufnr, opts)
  end
  vim.b[bufnr].fugitive_blame_heatmap_generation =
    (tonumber(vim.b[bufnr].fugitive_blame_heatmap_generation) or 0) + 1
  clear_heatmap(bufnr)
  return true
end

function M.toggle_heatmap(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return M.set_heatmap_enabled(bufnr, not M.is_heatmap_enabled(bufnr))
end

M._parse_blame_porcelain = parse_blame_porcelain
M._heatmap_buckets = heatmap_buckets

local model = require('git.features.blame_model')
local sessions = {}
local pending_opens = {}
local serial = 0
local ui_ns = vim.api.nvim_create_namespace('git_blame_panel')
local selected_ns = vim.api.nvim_create_namespace('git_blame_selected')
local function valid(win) return win and vim.api.nvim_win_is_valid(win) end
local function tell(message) vim.notify(message, vim.log.levels.INFO) end
local function local_options(win, opts)
  for name, value in pairs(opts) do vim.api.nvim_set_option_value(name, value, { win = win, scope = 'local' }) end
end
local function view(win)
  return vim.api.nvim_win_call(win, vim.fn.winsaveview)
end
local function close_float(s)
  if valid(s.float_win) then vim.api.nvim_win_close(s.float_win, true) end
  s.float_win = nil
end
local function current(s)
  local f = s.history[s.index]
  local win = vim.api.nvim_get_current_win() == s.code_win and s.code_win or s.win
  local row = valid(win) and vim.api.nvim_win_get_cursor(win)[1] or 1
  return f and f.rows[row], f, row
end
local function preview(s)
  if not s.active or not s.preview or not valid(s.win) then return end
  local r, f = current(s)
  if not r then close_float(s); return end
  local key = s.preview .. r.commit .. r.path
  local lines = s.messages[key]
  if not lines then
    local text
    if r.uncommitted then
      if s.preview == 'message' then text = 'Not committed yet\n\nThese lines include working-tree or unsaved changes.'
      else
        local base = model.git(s.root, { 'show', 'HEAD:' .. f.path }) or ''
        text = vim.diff(base, table.concat(f.lines, '\n') .. '\n', { ctxlen = 3 })
      end
    elseif s.preview == 'message' then
      text = model.git(s.root, { 'show', '-s', '--format=%h  %an%n%ad%n%n%B', '--date=iso', r.commit })
    else
      text = model.git(s.root, { 'show', '--format=fuller', '--no-ext-diff', r.commit, '--', r.path })
    end
    lines = vim.split(text or 'Could not load commit information', '\n', { plain = true })
    -- Git adds a record terminator after the message's own trailing newline.
    while #lines > 1 and lines[#lines]:match('^%s*$') do table.remove(lines) end
    if not r.uncommitted then s.messages[key] = lines end
  end
  local row = select(3, current(s))
  local height = math.max(1, math.min(#lines, vim.api.nvim_win_get_height(s.code_win) - 4))
  local config = {
    relative = 'win', win = s.code_win,
    width = math.max(1, math.min(80, vim.api.nvim_win_get_width(s.code_win) - 4)),
    height = height, row = 1, col = 1, anchor = 'NW',
    style = 'minimal', border = 'rounded', focusable = false,
    title = s.preview == 'message' and ' Commit message · gk ' or ' Commit diff · Ctrl-p ',
    zindex = 60,
  }
  if s.preview == 'message' then
    config.bufpos = { row - 1, 0 }
    local screen_row = vim.fn.screenpos(s.code_win, row, 1).row
    local bottom = vim.api.nvim_win_get_position(s.code_win)[1] + vim.api.nvim_win_get_height(s.code_win)
    if screen_row + height + 2 > bottom then config.anchor, config.row = 'SW', 0 end
  end
  if not valid(s.float_win) then
    local b = vim.api.nvim_create_buf(false, true)
    vim.bo[b].bufhidden = 'wipe'
    s.float_win = vim.api.nvim_open_win(b, false, config)
  else
    vim.api.nvim_win_set_config(s.float_win, config)
  end
  local b = vim.api.nvim_win_get_buf(s.float_win)
  vim.bo[b].modifiable = true
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].modifiable = false
  vim.bo[b].filetype = s.preview == 'message' and 'gitcommit' or 'diff'
  local_options(s.float_win, { wrap = s.preview == 'message', list = false })
end
local function history_info(s, refresh)
  local f = s.history[s.index]
  local revision = f and (f.pinned_commit or f.revision)
  if not revision or (f.pinned_commit and f.pin_info_hidden) then
    if valid(s.info_win) then vim.api.nvim_win_close(s.info_win, true) end
    s.info_win = nil
    return
  end
  if refresh or s.info_revision ~= revision then
    s.info_revision = revision
    if revision:match('^0+$') then
      s.info_lines = { 'Not committed yet', '', 'This line includes working-tree or unsaved changes.' }
    else
      s.info_lines = require('git.features.commit_info').lines(s.root, revision) or { 'Could not load commit information' }
    end
  end
  local lines = s.info_lines
  local width = math.max(1, math.min(80, vim.api.nvim_win_get_width(s.code_win) - 4))
  local config = { relative = 'win', win = s.code_win, row = 0,
    col = math.max(0, vim.api.nvim_win_get_width(s.code_win) - width - 2),
    width = width, height = math.max(1, math.min(#lines, vim.api.nvim_win_get_height(s.code_win) - 4)),
    style = 'minimal', border = 'single', focusable = false,
    title = f.pinned_commit and ' Dimmed Commit ' or ' Commit Info ', zindex = 50 }
  if not valid(s.info_win) then
    local b = vim.api.nvim_create_buf(false, true)
    vim.bo[b].bufhidden = 'wipe'
    s.info_win = vim.api.nvim_open_win(b, false, config)
  else vim.api.nvim_win_set_config(s.info_win, config) end
  local b = vim.api.nvim_win_get_buf(s.info_win)
  vim.bo[b].modifiable = true
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].modifiable = false
  if vim.bo[b].filetype ~= 'gitblameinfo' then
    vim.bo[b].filetype = 'gitblameinfo'
    vim.bo[b].syntax = 'git'
  end
  local_options(s.info_win, { wrap = false, list = false })
end
local function hash_group(hash)
  local r, g, b = hash:match('(%x)%x(%x)%x(%x)')
  local function channel(c)
    local n = tonumber(c, 16)
    return math.min(0xdf, 0x20 + math.floor((n * 0x10 + (15 - n)) * 0.75))
  end
  local name = 'GitBlameHash' .. r .. g .. b
  vim.api.nvim_set_hl(0, name, { fg = channel(r) * 0x10000 + channel(g) * 0x100 + channel(b) })
  return name
end
local function update_panel_winbar(s)
  if not valid(s.win) then return end
  local f = s.history[s.index]
  local top = vim.api.nvim_win_call(s.win, function() return vim.fn.line('w0') end)
  local record = f and f.rows[top]
  local label = panel_winbar
  if record and top > 1 and f.rows[top - 1] and f.rows[top - 1].commit == record.commit then
    if record.uncommitted then
      label = '%=Not committed%='
    else
      local hash = record.commit:sub(1, 8)
      local date = os.date('%Y-%m-%d %H:%M', record.timestamp or os.time())
      local width = vim.api.nvim_win_get_width(s.win) - 2
      local suffix = width >= #hash + #date + 1 and (' ' .. date) or ''
      local author = record.author or ''
      if author ~= '' and vim.fn.strdisplaywidth(hash .. suffix .. ' ' .. author) <= width then
        suffix = suffix .. ' ' .. author
      end
      label = '%=%#' .. hash_group(record.commit) .. '#' .. hash .. '%*' .. suffix:gsub('%%', '%%%%') .. '%='
    end
  end
  if vim.wo[s.win].winbar ~= label then vim.wo[s.win].winbar = label end
end
local function fit_width(s)
  local total = vim.api.nvim_win_get_width(s.win) + vim.api.nvim_win_get_width(s.code_win)
  local requested = (s.width_override or s.content_width or 1) + 1
  local width = math.max(1, math.min(requested, total - math.max(20, vim.o.winminwidth)))
  if vim.api.nvim_win_get_width(s.win) ~= width then vim.api.nvim_win_set_width(s.win, width) end
end
local function save_frame(s)
  local f = s.history[s.index]
  if not f then return end
  if valid(s.win) then f.panel_view = view(s.win) end
  if valid(s.code_win) then f.code_view = view(s.code_win) end
end
local function setup_selected_highlight()
  vim.api.nvim_set_hl(0, 'GitBlameSelected', { bg = '#002b36' })
  vim.api.nvim_set_hl(0, 'GitBlameUnselected', { bg = '#073642' })
end

local function highlight_selected(s)
  local r, f = current(s)
  vim.api.nvim_buf_clear_namespace(s.buf, selected_ns, 0, -1)
  if not r then return end
  local selected = f.pinned_commit or r.commit
  for row, entry in ipairs(f.rows) do
    vim.api.nvim_buf_set_extmark(s.buf, selected_ns, row - 1, 0, { end_row = row, end_col = 0, hl_eol = true,
      hl_group = entry.commit == selected and 'GitBlameSelected' or 'GitBlameUnselected', hl_mode = 'combine' })
  end
end
local function sync_dim(s)
  if s.dimmed_buf then diffdim.clear_blame(s.dimmed_buf); s.dimmed_buf = nil end
  local f = s.history[s.index]
  if f and f.pinned_commit and f.code_buf and diffdim.select_blame(f.code_buf, f.rows, f.pinned_commit) then
    s.dimmed_buf = f.code_buf
  end
end
local function annotation_lines(f)
  local lines, width = {}, 1
  for row, r in ipairs(f.rows) do
    local previous, following = f.rows[row - 1], f.rows[row + 1]
    local first = not previous or previous.commit ~= r.commit
    local last = not following or following.commit ~= r.commit
    local edge = first and (last and '╺' or '┍') or (last and '┕' or '│')
    local author = r.uncommitted and 'Not committed' or (r.author or '')
    local date = os.date('%Y-%m-%d %H:%M', r.timestamp or os.time())
    lines[row] = first and not r.uncommitted
      and (edge .. ' ' .. r.commit:sub(1, 8) .. ' ' .. date .. ' ' .. author):gsub('%s+$', '') or edge
  end
  for row, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line), f.rows[row].uncommitted and 15 or 1)
  end
  return lines, width
end
local function paint(s, f)
  local lines = annotation_lines(f)
  local buckets = heatmap_buckets(f.rows, os.time(), vim.g.fugitive_blame_gradient_mode)
  vim.bo[s.buf].modifiable = true
  vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, #lines > 0 and lines or { 'No lines to blame' })
  vim.bo[s.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(s.buf, ui_ns, 0, -1)
  s.content_width = 1
  for row, line in ipairs(lines) do
    s.content_width = math.max(s.content_width, vim.fn.strdisplaywidth(line))
    local start, finish = line:find('%d%d%d%d%-%d%d%-%d%d %d%d:%d%d')
    if start then
      vim.api.nvim_buf_set_extmark(s.buf, ui_ns, row - 1, start - 1, { end_col = finish, hl_group = 'FugitiveBlameDate' .. buckets[row] })
    end
    local record, previous = f.rows[row], f.rows[row - 1]
    if record.uncommitted and (not previous or not previous.uncommitted) then
      s.content_width = math.max(s.content_width, vim.fn.strdisplaywidth('Not committed') + 2)
      vim.api.nvim_buf_set_extmark(s.buf, ui_ns, row - 1, 0, {
        virt_text = { { 'Not committed ', 'Comment' } }, virt_text_pos = 'right_align', hl_mode = 'combine',
      })
    end
    local group = record.uncommitted and 'Comment' or hash_group(record.commit)
    vim.api.nvim_buf_set_extmark(s.buf, ui_ns, row - 1, 0, { end_col = 3, hl_group = group })
    if start then vim.api.nvim_buf_set_extmark(s.buf, ui_ns, row - 1, 4, { end_col = 12, hl_group = group }) end
  end
  fit_width(s)
  update_panel_winbar(s)
end
local show_frame, bind, cleanup
show_frame = function(s, f)
  s.switching = true
  for _, win in ipairs({ s.win, s.code_win }) do local_options(win, { scrollbind = false, cursorbind = false }) end
  if not f.code_buf or not vim.api.nvim_buf_is_valid(f.code_buf) then
    local b = vim.api.nvim_create_buf(false, true)
    f.code_buf = b
    vim.api.nvim_buf_set_name(b, ('git-blame-code://%d/%s/%s'):format(s.id, f.revision or 'worktree', f.path))
    vim.api.nvim_buf_set_lines(b, 0, -1, false, #f.lines > 0 and f.lines or { '' })
    vim.bo[b].bufhidden, vim.bo[b].modifiable, vim.bo[b].readonly = 'hide', false, true
    utils.set_buf_work_tree(b, s.root)
    vim.b[b].lazyagent_note_source = { kind = 'fugitive', root = s.root, path = f.path, revision = f.revision }
    s.owned[b] = true
    bind(s, b, true)
  end
  vim.api.nvim_win_set_buf(s.code_win, f.code_buf)
  if s.owned[f.code_buf] then vim.bo[f.code_buf].filetype = vim.filetype.match({ filename = f.path }) or '' end
  if not f.subject then
    f.subject = vim.trim(model.git(s.root, { 'show', '-s', '--format=%s', f.revision or 'HEAD' }) or '')
  end
  local_options(s.code_win, { wrap = false, foldenable = false, scrollbind = false, cursorbind = false,
    winbar = ' ' .. f.path:gsub('%%', '%%%%') .. ' · ' .. (f.revision and f.revision:sub(1, 8) or 'working tree')
      .. (f.subject ~= '' and (' · ' .. f.subject:gsub('[\r\n]', ' '):gsub('%%', '%%%%')) or ''),
  })
  paint(s, f)
  for _, pair in ipairs({ { s.win, f.panel_view }, { s.code_win, f.code_view } }) do
    if pair[2] then vim.api.nvim_win_call(pair[1], function() vim.fn.winrestview(pair[2]) end) end
  end
  for _, win in ipairs({ s.win, s.code_win }) do local_options(win, { scrollbind = true, cursorbind = false }) end
  s.switching = false
  update_panel_winbar(s)
  sync_dim(s)
  highlight_selected(s)
  history_info(s, true)
  preview(s)
end
local function request(s, path, revision, line, contents, initial, replace_index, loaded)
  s.generation = s.generation + 1
  local generation = s.generation
  if s.job then s.job:kill(15) end
  save_frame(s)
  local previous = s.history[s.index]
  local screen_offset = previous and previous.panel_view and (previous.panel_view.lnum - previous.panel_view.topline) or 5
  local source_tick = initial and vim.api.nvim_buf_get_changedtick(s.origin) or nil
  local function publish(f, err)
    if not s.active or generation ~= s.generation then return end
    if not valid(s.win) or not valid(s.code_win) then cleanup(s); return end
    s.job = nil
    if not f then
      tell(err)
      if initial then cleanup(s) end
      return
    end
    if initial and not revision and vim.api.nvim_buf_get_changedtick(s.origin) ~= source_tick then
      local latest = table.concat(vim.api.nvim_buf_get_lines(s.origin, 0, -1, false), '\n')
        .. (vim.bo[s.origin].endofline and '\n' or '')
      request(s, path, revision, line, latest, initial, replace_index)
      return
    end
    -- Frames are immutable snapshots; returning to the worktree restores its real buffer.
    if initial then
      f.code_buf, f.source_tick = s.origin, source_tick
    end
    f.panel_view = { lnum = math.min(line, math.max(#f.lines, 1)), col = 0, topline = math.max(1, line - screen_offset) }
    f.code_view = vim.deepcopy(f.panel_view)
    if initial and not replace_index then
      f.code_view = vim.deepcopy(s.origin_view)
      f.panel_view = vim.deepcopy(s.origin_view); f.panel_view.col = 0
    end
    if replace_index then
      local replaced = s.history[replace_index]
      f.code_buf, f.code_view, f.panel_view = replaced.code_buf, replaced.code_view, replaced.panel_view
      for _, entry in ipairs(f.rows) do
        if entry.commit == replaced.pinned_commit then
          f.pinned_commit, f.pin_info_hidden = replaced.pinned_commit, replaced.pin_info_hidden
          break
        end
      end
      s.history[replace_index] = f
      if s.index == replace_index then show_frame(s, f) end
      return
    end
    for i = #s.history, s.index + 1, -1 do
      local stale = table.remove(s.history, i)
      if s.owned[stale.code_buf] then pcall(vim.api.nvim_buf_delete, stale.code_buf, { force = true }); s.owned[stale.code_buf] = nil end
    end
    s.history[#s.history + 1], s.index = f, #s.history + 1
    show_frame(s, f)
  end
  if loaded then publish(loaded) else s.job = model.load(s.root, path, revision, contents, publish) end
end
local function refresh_worktree(s)
  local f = s.history[s.index]
  if not f or f.revision or not vim.api.nvim_buf_is_valid(s.origin) then return end
  local contents = table.concat(vim.api.nvim_buf_get_lines(s.origin, 0, -1, false), '\n')
    .. (vim.bo[s.origin].endofline and '\n' or '')
  request(s, f.path, nil, vim.api.nvim_win_get_cursor(s.code_win)[1], contents, true, s.index)
end
local function history(s, direction)
  local next_index = math.min(#s.history, math.max(1, s.index + direction * vim.v.count1))
  s.generation = s.generation + 1
  if s.job then s.job:kill(15); s.job = nil end
  if next_index == s.index then return end
  save_frame(s)
  s.index = next_index
  show_frame(s, s.history[s.index])
  local f = s.history[s.index]
  if not f.revision and f.source_tick ~= vim.api.nvim_buf_get_changedtick(s.origin) then refresh_worktree(s) end
end
local function navigate(s, parent, numbered)
  local r, f, row = current(s)
  if not r then return end
  local revision, path, line = r.commit, r.path, r.original
  if r.uncommitted then
    revision = vim.trim(model.git(s.root, { 'rev-parse', 'HEAD' }) or '')
    path = f.path
    local old = model.git(s.root, { 'show', revision .. ':' .. path })
    if not old then tell('This file has no committed version'); return end
    line = model.old_line(old, table.concat(f.lines, '\n') .. '\n', row)
  elseif parent then
    local target = numbered and (r.commit .. '^' .. vim.v.count1) or (r.commit .. '~' .. vim.v.count1)
    revision = model.git(s.root, { 'rev-parse', '--verify', target })
    if not revision then tell('No earlier parent for this line'); return end
    revision = vim.trim(revision)
    if vim.v.count1 == 1 and not numbered and r.previous then
      revision, path = r.previous, r.previous_path
    else
      -- Resolve renames against the requested ancestor rather than the worktree path.
      local names = model.git(s.root, { 'diff', '--name-status', '-z', '-M', revision, r.commit }) or ''
      local parts = vim.split(names, '\0', { plain = true })
      local i = 1
      while i <= #parts do
        if parts[i]:match('^R') then
          if parts[i + 2] == r.path then path = parts[i + 1]; break end
          i = i + 3
        else i = i + 2 end
      end
    end
    local old = model.git(s.root, { 'show', revision .. ':' .. path })
    local new = model.git(s.root, { 'show', r.commit .. ':' .. r.path })
    if not old then tell('This file did not exist before the selected change'); return end
    line = model.old_line(old, new or '', line)
  end
  if revision == f.revision and path == f.path then return end
  request(s, path, revision, line)
end
local function open_commit(s, layout)
  local r = current(s)
  if not r or r.uncommitted then tell('This line is not committed yet'); return end
  local hash, path = r.commit, r.path
  local b = require('git.features.commit').open({ work_tree = s.root, revision = hash, split = layout == 'split', tab = layout ~= 'split' })
  if b then
    -- Keep the blame/code pair intact, including its history and window views.
    -- Window-local ownership survives commit parent navigation and jump-list returns.
    vim.w.fugitive_commit_return_win = s.win
    local commit = require('git.features.commit')
    commit.expand_file(b, path)
    local line_number, target
    for row, text in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
      local entry, info = commit.entry_at(b, row)
      if entry and entry.path == path then
        if info.header then target = row; line_number = nil end
        local start = tonumber(text:match('^@@ %-%d+,?%d* %+(%d+)'))
        if start then line_number = start
        elseif line_number and text:match('^[ +]') then
          if line_number == r.original then target = row; break end
          line_number = line_number + 1
        end
      end
    end
    if target then vim.api.nvim_win_set_cursor(0, { target, 0 }); vim.cmd('normal! zz') end
  end
end
cleanup = function(s)
  if not s.active then return end
  s.active = false
  if s.dimmed_buf then diffdim.clear_blame(s.dimmed_buf); s.dimmed_buf = nil end
  sessions[s.buf] = nil
  if s.job then s.job:kill(15) end
  close_float(s)
  if valid(s.info_win) then vim.api.nvim_win_close(s.info_win, true) end
  pcall(vim.api.nvim_del_augroup_by_id, s.group)
  for b, maps in pairs(s.maps) do
    if vim.api.nvim_buf_is_valid(b) then
      for key, old in pairs(maps) do
        pcall(vim.keymap.del, 'n', key, { buffer = b })
        if old then vim.api.nvim_buf_call(b, function() vim.fn.mapset('n', false, old) end) end
      end
    end
  end
  if vim.api.nvim_buf_is_valid(s.origin) then vim.bo[s.origin].bufhidden = s.origin_hidden end
  if valid(s.code_win) then
    local shown = vim.api.nvim_win_get_buf(s.code_win)
    if (s.owned[shown] or shown == s.origin) and vim.api.nvim_buf_is_valid(s.origin) then
      vim.api.nvim_win_set_buf(s.code_win, s.origin)
      vim.api.nvim_win_call(s.code_win, function() vim.fn.winrestview(s.origin_view) end)
    end
    local_options(s.code_win, s.options)
  end
  if valid(s.win) then pcall(vim.api.nvim_win_close, s.win, true) end
  for b in pairs(s.owned) do pcall(vim.api.nvim_buf_delete, b, { force = true }) end
  pcall(vim.api.nvim_buf_delete, s.buf, { force = true })
end
bind = function(s, b, code)
  s.maps[b] = {}
  local function map(keys, fn)
    for _, key in ipairs(type(keys) == 'table' and keys or { keys }) do
      local old = vim.api.nvim_buf_call(b, function() return vim.fn.maparg(key, 'n', false, true) end)
      s.maps[b][key] = old.buffer == 1 and old or false
      vim.keymap.set('n', key, fn, { buffer = b, silent = true, nowait = true })
    end
  end
  map('<C-o>', function() history(s, -1) end)
  map('<C-i>', function() history(s, 1) end)
  local function move_block(direction)
    local r, f, row = current(s); if not r then return end
    for _ = 1, vim.v.count1 do
      local hash = f.rows[row].commit
      repeat row = row + direction until not f.rows[row] or f.rows[row].commit ~= hash
      row = math.max(1, math.min(#f.rows, row))
    end
    for _, win in ipairs({ s.win, s.code_win }) do
      if valid(win) then
        local col = win == s.win and 0 or vim.api.nvim_win_get_cursor(win)[2]
        vim.api.nvim_win_set_cursor(win, { row, col })
      end
    end
    highlight_selected(s)
    preview(s)
  end
  map(']]', function() move_block(1) end)
  map('[[', function() move_block(-1) end)
  map('gk', function() if s.preview == 'message' then s.preview = nil else s.preview = 'message' end; close_float(s); preview(s) end)
  map('<C-p>', function() if s.preview == 'diff' then s.preview = nil else s.preview = 'diff' end; close_float(s); preview(s) end)
  map('gD', function() M.toggle_dim_for_buffer(b) end)
  map('gC', function()
    local f = s.history[s.index]
    if not f or not f.pinned_commit then tell('Pin a commit with gD first'); return end
    f.pin_info_hidden = not f.pin_info_hidden
    history_info(s)
  end)
  if code then return end
  map({ 'q', 'gq' }, function() cleanup(s) end)
  map({ '-', 's', 'u' }, function() navigate(s) end)
  map({ '~', '<BS>' }, function() navigate(s, true) end)
  map('P', function() if vim.v.count == 0 then tell('Use ~, or a parent number such as 2P'); else navigate(s, true, true) end end)
  map({ '<CR>', '<2-LeftMouse>', 'i' }, function() open_commit(s, 'tab') end)
  map('o', function() open_commit(s, 'split') end)
  map('O', function() open_commit(s, 'tab') end)
  map('p', function() s.preview = 'diff'; close_float(s); preview(s) end)
  map('R', function() refresh_worktree(s) end)
  map('c', function()
    vim.g.fugitive_blame_gradient_mode = vim.g.fugitive_blame_gradient_mode == 'absolute' and 'relative' or 'absolute'
    local f = s.history[s.index]; if f then paint(s, f); highlight_selected(s) end
  end)
  map('y', function() local r = current(s); if r then vim.fn.setreg('"', r.commit); vim.fn.setreg('+', r.commit) end end)
  map('.', function() local r = current(s); if r then vim.fn.feedkeys(':' .. (r.uncommitted and 'HEAD' or r.commit) .. ' ', 'n') end end)
  for key, width in pairs({ A = 0, C = 10, D = 27 }) do
    local size = width
    map(key, function()
      s.width_override = size > 0 and (size + vim.v.count) or nil
      fit_width(s); history_info(s); preview(s)
    end)
  end
  for key, direction in pairs({ [')'] = 1, ['('] = -1 }) do
    local step = direction
    map(key, function() move_block(step) end)
  end
  map({ 'g?', '<F1>' }, function() require('git.features.help').show_text('Git blame', {
    '- / s / u    blame at the selected commit',
    '~ / <BS>     blame before the change (count supported)',
    '{count}P     blame a numbered parent',
    '<C-o> / <C-i>  back / forward (code and blame together)',
    'gk           toggle following commit message',
    '<C-p> / p    toggle / open following diff preview',
    '<CR> / i     inspect commit in a tab (q returns)',
    'o / O        open commit in split / tab',
    'd            compare before/after the change',
    'gD           pin/unpin commit and dim other code lines',
    'gC           hide/show the dimmed commit info',
    'c            absolute / relative date heatmap',
    '[[ / ]]      previous / next commit block (count supported)',
    '( / )        previous / next commit block',
    'y            copy full hash',
    '.            put hash on command line',
    'A / C / D    full / hash / date panel width',
    'R            refresh working-tree blame',
    'q / gq       close and restore original file',
  }) end)
  map('d', function()
    local r, f = current(s); if not r then return end
    local old, new, path
    if r.uncommitted then
      path = f.path
      old = model.git(s.root, { 'show', 'HEAD:' .. path }) or ''
      new = table.concat(f.lines, '\n') .. '\n'
    else
      path = r.path
      old = model.git(s.root, { 'show', (r.previous or (r.commit .. '^')) .. ':' .. (r.previous_path or path) }) or ''
      new = model.git(s.root, { 'show', r.commit .. ':' .. path }) or ''
    end
    serial = serial + 1
    local diff_id = serial
    vim.cmd('tabnew')
    local diff_tab = vim.api.nvim_get_current_tabpage()
    local diff_buffers = {}
    local function close_diff()
      vim.schedule(function()
        if not vim.api.nvim_tabpage_is_valid(diff_tab) then return end
        if vim.api.nvim_get_current_tabpage() ~= diff_tab then return end
        if #vim.api.nvim_list_tabpages() > 1 then
          vim.cmd('tabclose')
        else
          for _, w in ipairs(vim.api.nvim_tabpage_list_wins(diff_tab)) do
            vim.api.nvim_win_call(w, function() vim.cmd('diffoff') end)
          end
          vim.cmd('enew')
        end
        for _, buf in ipairs(diff_buffers) do pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
        if s.active and valid(s.win) then vim.api.nvim_set_current_win(s.win) end
      end)
    end
    for i, text in ipairs({ old, new }) do
      if i == 2 then vim.cmd('rightbelow vnew') end
      local buf = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_name(buf, ('git-blame-diff://%d/%s/%s'):format(diff_id, i == 1 and 'before' or 'after', path))
      local_options(0, { wrap = false, number = vim.go.number, relativenumber = vim.go.relativenumber })
      vim.bo[buf].buftype, vim.bo[buf].bufhidden = 'nofile', 'wipe'
      local lines = vim.split(text, '\n', { plain = true }); if lines[#lines] == '' then table.remove(lines) end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].filetype = vim.filetype.match({ filename = path }) or ''
      vim.bo[buf].modifiable = false
      vim.cmd('diffthis')
      diff_buffers[#diff_buffers + 1] = buf
      vim.keymap.set('n', 'q', close_diff, { buffer = buf, silent = true, nowait = true, desc = 'Close blame diff and return' })
    end
    vim.api.nvim_win_set_cursor(0, { math.min(r.original, vim.api.nvim_buf_line_count(0)), 0 })
  end)
end
function M.toggle_dim_for_buffer(bufnr)
  for _, s in pairs(sessions) do
    local f = s.history[s.index]
    if s.active and f and (s.buf == bufnr or f.code_buf == bufnr) then
      local r = current(s)
      if not r then return false end
      if f.pinned_commit == r.commit then f.pinned_commit = nil else f.pinned_commit = r.commit end
      f.pin_info_hidden = false
      sync_dim(s)
      highlight_selected(s)
      history_info(s, true)
      update_panel_winbar(s)
      return true
    end
  end
  return false
end
function M.clear_dim_for_buffer(bufnr)
  for _, s in pairs(sessions) do
    local f = s.history[s.index]
    if s.active and f and (f.code_buf == bufnr or s.buf == bufnr) and f.pinned_commit then
      f.pinned_commit = nil
      f.pin_info_hidden = false
      sync_dim(s)
      highlight_selected(s)
      history_info(s, true)
      return true
    end
  end
  return false
end
function M.open(opts)
  opts = opts or {}
  local origin, code_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  for _, s in pairs(sessions) do
    if s.code_win == code_win or s.win == code_win or s.origin == origin then vim.api.nvim_set_current_win(s.win); return s.buf end
  end
  local source = vim.b[origin].lazyagent_note_source
  local absolute = vim.api.nvim_buf_get_name(origin)
  local root, path, revision = opts.work_tree, opts.path, opts.revision
  if source and source.kind == 'fugitive' then root, path, revision = source.root, source.path, source.revision end
  if not root then
    if vim.bo[origin].buftype ~= '' or absolute == '' then tell('Open a file or a commit blob to blame'); return end
    root = model.git(vim.fs.dirname(absolute), { 'rev-parse', '--show-toplevel' })
    root = root and vim.trim(root)
  end
  if not root then tell('Not inside a Git worktree'); return end
  path = path or absolute:sub(#root + 2)
  -- Validate before creating any buffers/windows or changing the source options.
  if not model.git(root, { 'cat-file', '-e', (revision or 'HEAD') .. ':' .. path }) then
    local tracked = model.git(root, { '--literal-pathspecs', 'ls-files', '--error-unmatch', '--', path })
    tell(not revision and not tracked and 'Untracked file: no Git blame history'
      or 'No committed version of this file to blame')
    return
  end
  local panel_name = 'git-blame://' .. root .. '//' .. (revision or 'worktree') .. '/' .. path
  for _, session in pairs(sessions) do
    if session.active and vim.api.nvim_buf_get_name(session.buf) == panel_name then
      vim.api.nvim_set_current_win(session.win)
      return session.buf
    end
  end
  for _, buf in pairs(pending_opens) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) == panel_name then return buf end
  end
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(b, panel_name)
  pending_opens[code_win] = b
  local function activate(frame)
    frame.subject = vim.trim(model.git(root, { 'show', '-s', '--format=%s', revision or 'HEAD' }) or '')
    local options = {}
    for _, name in ipairs({ 'scrollbind', 'cursorbind', 'wrap', 'foldenable', 'winbar' }) do options[name] = vim.api.nvim_get_option_value(name, { win = code_win }) end
    local origin_view = view(code_win)
    local origin_hidden = vim.bo[origin].bufhidden
    vim.bo[origin].bufhidden = 'hide'
    serial = serial + 1
    vim.bo[b].bufhidden, vim.bo[b].filetype = 'wipe', 'gitblame'
    utils.set_buf_work_tree(b, root)
    local lines, width = annotation_lines(frame)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, #lines > 0 and lines or { 'No lines to blame' })
    vim.bo[b].modifiable = false
    local_options(code_win, { scrollbind = false, cursorbind = false })
    width = math.max(1, math.min(width + 1, vim.api.nvim_win_get_width(code_win) - math.max(20, vim.o.winminwidth) - 1))
    local win = vim.api.nvim_open_win(b, true, { split = 'left', win = code_win, width = width })
    local_options(win, { winbar = panel_winbar, cursorline = false, winfixwidth = true, list = false, number = false, relativenumber = false, wrap = false, foldenable = false, foldcolumn = '0', signcolumn = 'no', scrollbind = false, cursorbind = false })
    local s = { id = serial, buf = b, win = win, code_win = code_win, origin = origin, root = root,
      origin_view = origin_view, origin_hidden = origin_hidden, options = options, active = true, generation = 0, history = {}, index = 0,
      messages = {}, maps = {}, owned = {}, group = vim.api.nvim_create_augroup('GitBlame' .. b, { clear = true }) }
    sessions[b] = s
    bind(s, b); bind(s, origin, true)
    vim.api.nvim_create_autocmd('CursorMoved', { group = s.group, callback = function(ev)
      if not s.active or s.switching then return end
      local w = vim.api.nvim_get_current_win()
      if w ~= s.win and w ~= s.code_win then return end
      local f = s.history[s.index]
      if not f or (ev.buf ~= b and ev.buf ~= f.code_buf) then return end
      local row = vim.api.nvim_win_get_cursor(w)[1]
      local other = w == s.win and s.code_win or s.win
      if valid(other) and vim.api.nvim_win_get_cursor(other)[1] ~= row then
        local cursor = vim.api.nvim_win_get_cursor(other)
        pcall(vim.api.nvim_win_set_cursor, other, { row, cursor[2] })
      end
      highlight_selected(s)
      s.preview_generation = (s.preview_generation or 0) + 1
      local generation = s.preview_generation
      vim.defer_fn(function() if s.active and generation == s.preview_generation then preview(s) end end, 80)
    end })
    vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'BufWritePost' }, { group = s.group, buffer = origin, callback = function()
      if not s.active then return end
      s.edit_generation = (s.edit_generation or 0) + 1
      local generation = s.edit_generation
      vim.defer_fn(function()
        if s.active and generation == s.edit_generation then refresh_worktree(s) end
      end, 120)
    end })
    vim.api.nvim_create_autocmd('BufEnter', { group = s.group, callback = function(ev)
      if not s.active or s.switching or vim.api.nvim_get_current_win() ~= s.code_win then return end
      local f = s.history[s.index]
      if ev.buf ~= s.origin and (not f or ev.buf ~= f.code_buf) then cleanup(s) end
    end })
    vim.api.nvim_create_autocmd({ 'WinScrolled', 'WinResized', 'VimResized', 'TabEnter' }, { group = s.group, callback = function()
      if not s.active or s.switching or s.layout_pending then return end
      s.layout_pending = true
      vim.schedule(function()
        s.layout_pending = false
        if not s.active or s.switching or not valid(s.win) or not valid(s.code_win)
          or vim.api.nvim_win_get_tabpage(s.win) ~= vim.api.nvim_get_current_tabpage() then return end
        fit_width(s); update_panel_winbar(s); history_info(s); preview(s)
      end)
    end })
    vim.api.nvim_create_autocmd('WinClosed', { group = s.group, callback = function(ev)
      if tonumber(ev.match) == s.win or tonumber(ev.match) == s.code_win then cleanup(s) end
    end })
    vim.api.nvim_create_autocmd('BufWipeout', { group = s.group, buffer = b, callback = function() cleanup(s) end })
    request(s, path, revision, origin_view.lnum, nil, true, nil, frame)
  end
  local job
  local function discard()
    if pending_opens[code_win] == b then pending_opens[code_win] = nil end
    if vim.api.nvim_buf_is_valid(b) then vim.api.nvim_buf_delete(b, { force = true }) end
  end
  vim.api.nvim_create_autocmd('BufWipeout', { buffer = b, once = true, callback = function()
    if pending_opens[code_win] == b then pending_opens[code_win] = nil; if job then job:kill(15) end end
  end })
  local function load_initial()
    local tick = vim.api.nvim_buf_get_changedtick(origin)
    local contents = table.concat(vim.api.nvim_buf_get_lines(origin, 0, -1, false), '\n') .. (vim.bo[origin].endofline and '\n' or '')
    job = model.load(root, path, revision, contents, function(frame, err)
      if pending_opens[code_win] ~= b then return end
      if not valid(code_win) or vim.api.nvim_get_current_win() ~= code_win
        or vim.api.nvim_win_get_buf(code_win) ~= origin then discard(); return end
      if not frame then discard(); tell(err); return end
      if not revision and tick ~= vim.api.nvim_buf_get_changedtick(origin) then load_initial(); return end
      pending_opens[code_win] = nil
      activate(frame)
    end)
  end
  load_initial()
  return b
end

function M.setup(group)
  diffdim.setup()
  setup_blame_gradients()
  setup_selected_highlight()

  -- グラデーションモード: 'absolute' または 'relative'
  vim.g.fugitive_blame_gradient_mode = vim.g.fugitive_blame_gradient_mode or 'absolute'

  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = function()
      setup_blame_gradients()
      setup_selected_highlight()
      for _, s in pairs(sessions) do
        local f = s.history[s.index]
        if s.active and f then paint(s, f); highlight_selected(s) end
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = group,
    callback = function(ev)
      if M.is_heatmap_enabled(ev.buf) then M.refresh_heatmap(ev.buf, { notify = false }) end
    end,
  })
  vim.api.nvim_create_user_command('GitHeatmap', function(cmd)
    local bufnr = vim.api.nvim_get_current_buf()
    local action = cmd.args ~= '' and cmd.args or 'toggle'
    if action == 'on' then
      M.set_heatmap_enabled(bufnr, true)
    elseif action == 'off' then
      M.set_heatmap_enabled(bufnr, false)
    elseif action == 'refresh' then
      if not M.is_heatmap_enabled(bufnr) then vim.b[bufnr].fugitive_blame_heatmap_enabled = true end
      M.refresh_heatmap(bufnr)
    else
      M.toggle_heatmap(bufnr)
    end
  end, {
    nargs = '?',
    complete = function() return { 'toggle', 'on', 'off', 'refresh' } end,
    desc = 'Toggle Git blame recency heatmap for the current buffer',
    force = true,
  })

  vim.api.nvim_create_user_command('GitBlame', function() M.open() end, { desc = 'Open paired Git blame' })
end

return M

-- Editable PR metadata above an immutable, lazily expanded merge-base diff.
local M = {}
local utils = require('git.utils')
local github = require('git.features.github')
local actions = require('git.features.github_actions')
local model_api = require('git.features.pr_model')
local changes = require('git.features.commit_model')
local display = require('git.features.change_display')
local syntax = require('git.features.syntax_highlight')
local viewed = require('git.features.pr_viewed_state')
local conversation = require('git.features.pr_conversation')
local markdown = require('git.features.pr_markdown')
vim.api.nvim_set_hl(0, 'GitPrViewedFile', { default = true, link = 'Comment' })
vim.api.nvim_set_hl(0, 'GitPrTitle', { default = true, link = 'Title' })
vim.api.nvim_set_hl(0, 'GitPrCommentSelf', { default = true, link = 'DiagnosticInfo' })
local states = {}
local window_options = {}
local ns = vim.api.nvim_create_namespace('git_pr_status')
local title_ns = vim.api.nvim_create_namespace('git_pr_title')
local function comment_markers(threads, unread, file_header)
  local published, current, pending, unread_count, resolved, known = 0, 0, 0, 0, 0, true
  for _, thread in ipairs(threads) do
    local has_public, has_draft = false, false
    for _, comment in ipairs(thread.comments) do
      if comment.pending then has_draft = true
      else
        has_public, published = true, published + 1
        if thread.outdated == false then current = current + 1
        elseif thread.outdated == nil then known = false end
      end
      if unread[comment.id] then unread_count = unread_count + 1 end
    end
    if has_public then
      if thread.resolved then resolved = resolved + 1 end
    end
    if has_draft then pending = pending + 1 end
  end
  local chunks = {}
  local count = file_header and known and (current .. '/' .. published) or tostring(published)
  if published > 0 then chunks[#chunks + 1] = { ' 💬 ' .. count, 'DiagnosticInfo' } end
  if unread_count > 0 then chunks[#chunks + 1] = { ' 🆕', 'DiagnosticWarn' } end
  if pending > 0 then chunks[#chunks + 1] = { ' 📝 ' .. pending .. ' [pending]', 'DiagnosticWarn' } end
  if resolved > 0 then chunks[#chunks + 1] = { ' ✅ ' .. resolved, 'GitPrPositive' } end
  return chunks
end
local function configure_window(win)
  local options = { number = false, relativenumber = false, wrap = false, foldenable = false, list = false,
    signcolumn = 'yes:1', statuscolumn = '%s', foldcolumn = '0' }
  if not window_options[win] then
    window_options[win] = {}
    for name in pairs(options) do window_options[win][name] = vim.api.nvim_get_option_value(name, { win = win, scope = 'local' }) end
    for _, name in ipairs({ 'conceallevel', 'concealcursor' }) do
      window_options[win][name] = vim.api.nvim_get_option_value(name, { win = win, scope = 'local' })
    end
  end
  for name, value in pairs(options) do vim.api.nvim_set_option_value(name, value, { win = win, scope = 'local' }) end
end
local function restore_window(win)
  local saved = window_options[win]
  window_options[win] = nil
  if saved and vim.api.nvim_win_is_valid(win) then
    for name, value in pairs(saved) do vim.api.nvim_set_option_value(name, value, { win = win, scope = 'local' }) end
  end
end
local window_group = vim.api.nvim_create_augroup('GitPrWindows', { clear = true })
vim.api.nvim_create_autocmd('BufWinEnter', { group = window_group, callback = function(ev)
  local win = vim.api.nvim_get_current_win()
  if states[ev.buf] then configure_window(win) else restore_window(win) end
end })
vim.api.nvim_create_autocmd('WinClosed', { group = window_group, callback = function(ev) window_options[tonumber(ev.match)] = nil end })
local function notify(err) vim.notify(tostring(err), vim.log.levels.ERROR) end
function M.model(buf) local s = states[buf or vim.api.nvim_get_current_buf()]; return s and s.model end
local function live(s) return states[s.buf] == s and vim.api.nvim_buf_is_loaded(s.buf) end
local function draft(s)
  local lines = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
  if #lines < #s.prefix + #s.suffix + 2 then return nil, 'Only the PR title and description may be edited' end
  for i, line in ipairs(s.prefix) do
    if lines[i] ~= line then return nil, 'PR metadata is read-only; undo those edits before saving' end
  end
  local tail = #lines - #s.suffix
  for i, line in ipairs(s.suffix) do
    if lines[tail + i] ~= line then return nil, 'PR diffs are read-only; undo those edits before saving' end
  end
  local editable = vim.list_slice(lines, #s.prefix + 1, tail)
  if not editable[1] or vim.trim(editable[1]) == '' then return nil, 'PR title cannot be empty' end
  if editable[2] ~= '' then return nil, 'Keep a blank line between the PR title and description' end
  return editable
end
local function edited(s)
  local current = draft(s)
  return not current or not vim.deep_equal(current, s.original)
end
local function delta(s) return vim.api.nvim_buf_line_count(s.buf) - s.line_count end
function M.entry_at(buf, row)
  local s = states[buf]
  if not s or not s.model then return nil end
  local info = s.rows[row - delta(s)]
  return info and info.entry, info
end
function M.commit_at(buf, row)
  local s = states[buf]
  return s and s.commit_rows and s.commit_rows[row - delta(s)]
end
function M.check_at(buf, row)
  local s = states[buf]
  return s and s.ci_rows and s.ci_rows[row]
end
function M.conversation_at(buf, row)
  local s = states[buf]
  return s and s.conversation_rows and s.conversation_rows[row - delta(s)]
end
local function conversation_selected(s)
  local section = s.conversation_section
  local row = vim.fn.line('.') - delta(s)
  return section and row >= section.first and row <= section.last
end
local function editable_row(s, row)
  return row > #s.prefix and row <= vim.api.nvim_buf_line_count(s.buf) - #s.suffix
end
local function link_at(s)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local item = M.conversation_at(s.buf, cursor[1])
  if item then return item.url end
  local link = s.links[cursor[1]]
  if type(link) ~= 'table' then return link end
  if cursor[2] >= link.start_col and cursor[2] < link.end_col then return link.url end
end
local function paint_title(s)
  if not s.model or not vim.api.nvim_buf_is_valid(s.buf) then return end
  local row = #s.prefix
  local title = vim.api.nvim_buf_get_lines(s.buf, row, row + 1, false)[1]
  if not title then return end
  vim.api.nvim_buf_clear_namespace(s.buf, title_ns, 0, -1)
  vim.api.nvim_buf_set_extmark(s.buf, title_ns, row, 0, { end_col = #title, hl_group = 'GitPrTitle',
    priority = 300, right_gravity = false, end_right_gravity = true })
end
local function paint_markdown(s)
  -- Description is mutable; its end follows draft growth. Conversation bodies
  -- belong to the immutable suffix and all move by the same draft offset.
  local ranges = { { #s.prefix + 2, vim.api.nvim_buf_line_count(s.buf) - #s.suffix } }
  local offset = delta(s)
  for _, range in ipairs(s.markdown_ranges or {}) do
    ranges[#ranges + 1] = { range[1] + offset, range[2] + offset }
  end
  markdown.update(s.buf, ranges)
end
local function paint_comments(s)
  for _, id in ipairs(s.comment_marks or {}) do pcall(vim.api.nvim_buf_del_extmark, s.buf, ns, id) end
  s.comment_marks = {}
  local reads = require('git.features.pr_read_state')
  local viewer = s.model.review and s.model.review.viewer or s.model.viewed and s.model.viewed.viewer
  local unread = reads.unread(s.ctx, viewer, s.model.threads)
  for row, info in pairs(s.rows) do
    local chunks = info.header and display.statistics(info.entry) or {}
    vim.list_extend(chunks, comment_markers(info.threads, unread, info.header))
    if #chunks > 0 then s.comment_marks[#s.comment_marks + 1] = vim.api.nvim_buf_set_extmark(s.buf, ns, row + delta(s) - 1, 0,
      { virt_text = chunks, virt_text_pos = 'eol' }) end
  end
  local summary = comment_markers(s.model.threads, unread, false)
  if #summary > 0 then s.comment_marks[#s.comment_marks + 1] = vim.api.nvim_buf_set_extmark(s.buf, ns,
    vim.api.nvim_buf_line_count(s.buf) - 1, 0, { virt_text = summary, virt_text_pos = 'eol' }) end
  local entries = s.model.conversation and s.model.conversation.entries or {}
  for _, is_new in pairs(reads.unread_entries(s.ctx, viewer, entries)) do if is_new then
    s.comment_marks[#s.comment_marks + 1] = vim.api.nvim_buf_set_extmark(s.buf, ns,
      s.conversation_section.first + delta(s) - 1, 0, { virt_text = { { ' 🆕', 'DiagnosticWarn' } }, virt_text_pos = 'eol' })
    break
  end end
end
local function read_conversation(s)
  if not s.conversation_expanded then return end
  local reads = require('git.features.pr_read_state')
  local viewer = s.model.review and s.model.review.viewer or s.model.viewed and s.model.viewed.viewer
  local entries = s.model.conversation and s.model.conversation.entries or {}
  local unread, fresh = reads.unread_entries(s.ctx, viewer, entries), {}
  for _, entry in ipairs(entries) do if unread[entry.key or entry.id] then fresh[#fresh + 1] = entry end end
  if #fresh == 0 then return end
  local ok, err = pcall(reads.mark, s.ctx, viewer, fresh)
  if not ok then vim.notify('Could not save conversation read state: ' .. tostring(err), vim.log.levels.WARN) end
end
local function render(s, current)
  s.rendering = true
  local model, pr = s.model, s.model.pr
  markdown.prepare(s.buf)
  local header = require('git.features.pr_header').build(model, s.header_expanded ~= false, s.ci_expanded)
  local prefix, highlights = header.lines, header.highlights
  s.links = header.links
  s.ci_section = header.ci_section
  s.ci_rows = header.ci_rows
  s.metadata_rows = header.metadata_rows
  vim.list_extend(prefix, { '', 'Title / description · edit below, <C-s> / :w saves to GitHub' })
  local original = { pr.title, '' }
  if pr.body and pr.body ~= '' and pr.body ~= vim.NIL then vim.list_extend(original, vim.split(pr.body, '\n', { plain = true })) end
  local message = current or original
  local lines = vim.list_extend(vim.deepcopy(prefix), message)
  local suffix_start = #lines + 1
  local history = model.conversation or { entries = {}, errors = {} }
  vim.list_extend(lines, { '', ('Conversation (%d)%s'):format(#history.entries, #history.errors > 0 and ' · incomplete' or '') })
  local conversation_first = #lines
  s.conversation_rows, s.conversation_first_item, s.markdown_ranges = {}, nil, {}
  if s.conversation_expanded then
    s.conversation_rows, s.conversation_first_item, s.markdown_ranges = conversation.append(lines, highlights, history,
      model.review and model.review.viewer or model.viewed and model.viewed.viewer, markdown.active(s.buf))
  end
  s.conversation_section = { first = conversation_first, last = #lines }
  vim.list_extend(lines, { '', ('Commits (%d)'):format(model.commit_count) })
  local commit_first, commit_rows = #lines, {}
  if s.commits_expanded then
    for _, commit in ipairs(model.commits) do
      local line, col = '', 0
      for _, chunk in ipairs(require('git.features.pr_commits').chunks(commit)) do
        line = line .. chunk[1]
        highlights[#highlights + 1] = { row = #lines + 1, start = col, finish = col + #chunk[1], group = chunk[2] }
        col = col + #chunk[1]
      end
      lines[#lines + 1] = line
      commit_rows[#lines] = commit
    end
  end
  s.commit_section, s.commit_rows = { first = commit_first, last = #lines }, commit_rows
  local progress = 'Viewed unavailable'
  if model.viewed then
    local count = 0
    for _, entry in ipairs(model.entries) do if entry.viewed_state == 'VIEWED' then count = count + 1 end end
    progress = ('Viewed %d/%d'):format(count, #model.entries)
  end
  vim.list_extend(lines, { '', ('Changes (%d) · %s · merge-base %s → %s'):format(#model.entries, progress, model.base:sub(1, 7), model.hash:sub(1, 7)) })
  local changes_row = #lines
  local start, finish = lines[changes_row]:find(progress, 1, true)
  highlights[#highlights + 1] = { row = changes_row, start = start - 1, finish = finish,
    group = model.viewed and 'GitPrHeaderLabel' or 'DiagnosticWarn' }
  if model.viewed_error then lines[#lines + 1] = 'Viewed status unavailable: ' .. model.viewed_error:gsub('[\r\n]', ' ') end
  if model.comments_error then lines[#lines + 1] = 'Comments unavailable: ' .. model.comments_error:gsub('[\r\n]', ' ') end
  local rows = {}
  for _, entry in ipairs(s.changes_expanded ~= false and model.entries or {}) do
    lines[#lines + 1] = display.line(entry)
    rows[#lines] = { entry = entry, header = true, threads = model_api.threads_at(model, entry) }
    if s.expanded[entry.path] then
      local diff, start = changes.inline(model, entry)
      if not diff then notify(start); diff = { 'Diff unavailable; refresh to retry' } end
      local coordinates = entry.patch and model_api.coordinates(entry.patch) or {}
      for i, line in ipairs(diff) do
        local patch_row = start and start + i - 1
        lines[#lines + 1] = line
        rows[#lines] = { entry = entry, patch_row = patch_row, coordinate = coordinates[patch_row],
          threads = coordinates[patch_row] and model_api.threads_at(model, entry, coordinates[patch_row]) or {} }
      end
    end
  end
  s.changes_section = { first = changes_row, last = #lines }
  -- File/outdated comments are also accessible without a matching displayed line.
  lines[#lines + 1] = ''
  if model.thread_status_error then
    lines[#lines + 1] = 'Thread status unavailable: ' .. model.thread_status_error:gsub('[\r\n]', ' ')
  end
  local resolution = model.thread_status and ('%d unresolved'):format(model.thread_status.unresolved) or 'unresolved: unavailable'
  lines[#lines + 1] = ('Review threads (%d) · %s · gc opens · gR resolves · gC writes · gr reviews'):format(#model.threads, resolution)
  if model.thread_status then
    local start, finish = lines[#lines]:find(resolution, 1, true)
    highlights[#highlights + 1] = { row = #lines, start = start - 1, finish = finish,
      group = model.thread_status.unresolved == 0 and 'GitPrPositive' or 'DiagnosticWarn' }
  end
  s.prefix, s.suffix, s.original = prefix, vim.list_slice(lines, suffix_start), original
  s.rows, s.line_count = rows, #lines
  local old = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
  local first, tail = 0, 0
  while first < math.min(#old, #lines) and old[first + 1] == lines[first + 1] do first = first + 1 end
  while tail < math.min(#old, #lines) - first and old[#old - tail] == lines[#lines - tail] do tail = tail + 1 end
  vim.bo[s.buf].modifiable = true
  if first < #old or first < #lines then
    vim.api.nvim_buf_set_lines(s.buf, first, #old - tail, false, vim.list_slice(lines, first + 1, #lines - tail))
  end
  vim.bo[s.buf].modified = not vim.deep_equal(message, original)
  vim.api.nvim_buf_clear_namespace(s.buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(s.buf, ns, 0, 0, { sign_text = s.header_expanded == false and '▸' or '▾',
    sign_hl_group = 'GitPrHeaderLabel', priority = 200 })
  if s.ci_section then
    vim.api.nvim_buf_set_extmark(s.buf, ns, s.ci_section.first - 1, 0,
      { sign_text = s.ci_expanded and '▾' or '▸', sign_hl_group = 'GitPrHeaderLabel', priority = 200 })
  end
  vim.api.nvim_buf_set_extmark(s.buf, ns, commit_first - 1, 0,
    { sign_text = s.commits_expanded and '▾' or '▸', sign_hl_group = 'Title', priority = 200 })
  vim.api.nvim_buf_set_extmark(s.buf, ns, conversation_first - 1, 0,
    { sign_text = s.conversation_expanded and '▾' or '▸', sign_hl_group = 'Title', priority = 200 })
  vim.api.nvim_buf_set_extmark(s.buf, ns, changes_row - 1, 0,
    { sign_text = s.changes_expanded == false and '▸' or '▾', sign_hl_group = 'Title', priority = 200 })
  s.comment_marks = {}
  local title_rows = { #prefix, conversation_first, commit_first, changes_row, #lines }
  for _, row in ipairs(title_rows) do
    vim.api.nvim_buf_set_extmark(s.buf, ns, row - 1, 0, { end_col = #lines[row], hl_group = 'Title' })
  end
  for _, mark in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(s.buf, ns, mark.row - 1, mark.start,
      { end_col = mark.finish, hl_group = mark.group, priority = mark.priority or 200 })
  end
  for row, link in pairs(s.links) do
    if type(link) == 'table' then
      vim.api.nvim_buf_set_extmark(s.buf, ns, row - 1, link.start_col,
        { end_col = link.end_col, hl_group = 'Underlined' })
    end
  end
  for row, info in pairs(rows) do
    if info.header then
      local group = info.entry.status == 'A' and 'GitSignsAdd' or info.entry.status == 'D' and 'GitSignsDelete' or 'Structure'
      vim.api.nvim_buf_set_extmark(s.buf, ns, row - 1, 0, { end_col = 1, hl_group = group })
      local icon, hl = utils.get_devicon(info.entry.path)
      vim.api.nvim_buf_set_extmark(s.buf, ns, row - 1, 2, { end_col = #lines[row],
        hl_group = info.entry.viewed_state == 'VIEWED' and 'GitPrViewedFile' or hl,
        virt_text = { { icon .. ' ', hl } }, virt_text_pos = 'inline' })
    end
  end
  paint_title(s)
  paint_comments(s)
  syntax.refresh(s.buf)
  paint_markdown(s)
  read_conversation(s)
  s.rendering = false
  if s.edit_guard then s.edit_guard.sync() end
end
function M.show_checks(buf)
  local s = states[buf]
  if not s or not s.model then return end
  local current, err = draft(s)
  if not current then notify(err); return end
  local win
  for _, candidate in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(candidate) == buf then win = candidate; break end
  end
  if not win then return end
  s.header_expanded, s.ci_expanded = true, true
  render(s, current)
  vim.api.nvim_set_current_win(win)
  local row = s.ci_section.first
  vim.api.nvim_win_set_cursor(win, { s.ci_rows[row + 1] and row + 1 or row, 0 })
  return buf
end
function M.show_conversation(buf)
  local s = states[buf]
  if not s or not s.model then return end
  local current, err = draft(s)
  if not current then notify(err); return end
  local win
  for _, candidate in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(candidate) == buf then win = candidate; break end
  end
  if not win then return end
  s.conversation_expanded = true
  render(s, current)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { s.conversation_first_item or s.conversation_section.first, 0 })
  return buf
end
local function focus_section(s, section)
  -- CI belongs to the Repo header. Reveal its parent when needed, retaining
  -- the CI fold and the editable draft rather than opening check details.
  if section == 'ci' and s.header_expanded == false then
    local current, err = draft(s)
    if not current then notify(err); return end
    s.header_expanded = true
    render(s, current)
  end
  local row = 1
  if section == 'changes' then
    row = s.changes_section.first
    if s.changes_expanded ~= false then
      for at = row + 1, s.changes_section.last do
        if s.rows[at] and s.rows[at].header then row = at; break end
      end
    end
    row = row + delta(s)
  elseif section == 'commits' then
    row = s.commit_section.first
    if s.commit_rows[row + 1] then row = row + 1 end
    row = row + delta(s)
  elseif section == 'conversation' then
    row = (s.conversation_first_item or s.conversation_section.first) + delta(s)
  elseif section == 'ci' then
    row = s.ci_section.first
    if s.ci_rows[row + 1] then row = row + 1 end
  end
  vim.api.nvim_win_set_cursor(0, { row, 0 })
end
local function focus(s, path, win)
  if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= s.buf then return end
  for row, info in pairs(s.rows) do if info.header and info.entry.path == path then
    vim.api.nvim_win_set_cursor(win, { row + delta(s), 0 }); return
  end end
end
local function unfold_changes(s, win, from_end)
  if s.changes_expanded ~= false then return true end
  local current, err = draft(s)
  if not current then notify(err); return false end
  local first, row = s.changes_section.first + delta(s), vim.api.nvim_win_get_cursor(win)[1]
  s.changes_expanded = true; render(s, current)
  if row >= first then row = from_end and vim.api.nvim_buf_line_count(s.buf) or s.changes_section.first + delta(s) end
  vim.api.nvim_win_set_cursor(win, { row, 0 })
  return true
end
local function move_unviewed(s, direction)
  if not s.model.viewed then notify('File viewed status unavailable; refresh to retry'); return end
  local win = vim.api.nvim_get_current_win()
  if not unfold_changes(s, win, direction < 0) then return end
  local current, offset = vim.fn.line('.'), delta(s)
  local candidates = {}
  for row, info in pairs(s.rows) do
    if info.header and viewed.unviewed(info.entry) then candidates[#candidates + 1] = row + offset end
  end
  table.sort(candidates, function(a, b) return direction > 0 and a < b or direction < 0 and a > b end)
  local count, target = vim.v.count1, nil
  for _, row in ipairs(candidates) do
    if (row - current) * direction > 0 then
      target, count = row, count - 1
      if count == 0 then break end
    end
  end
  if target then vim.api.nvim_win_set_cursor(win, { target, 0 })
  else vim.notify('No further unviewed files', vim.log.levels.INFO) end
end
local function toggle_viewed(s)
  if s.viewed_pending or s.loading or s.saving then return end
  local entry = M.entry_at(s.buf, vim.fn.line('.'))
  if not entry then notify('Select a PR file or diff line to toggle Viewed'); return end
  if not s.model.viewed then notify('File viewed status unavailable; refresh to retry'); return end
  local ctx, snapshot, path = vim.deepcopy(s.ctx), vim.deepcopy(s.model.viewed), entry.path
  s.viewed_pending = true
  local task, err = require('git.features.async').run(ctx.root, function()
    return viewed.set(ctx, snapshot, path)
  end, function(ok, result)
    s.viewed_pending = false
    if not ok then notify(result); return end
    vim.api.nvim_exec_autocmds('User', { pattern = 'GitPrViewedChanged', data = {
      host = ctx.host, repo = ctx.repo, number = ctx.number, status = result,
    } })
  end, { mutation = true })
  if not task then s.viewed_pending = false; notify(err) end
end
local function toggle(s, mode, first, last, done)
  local current, err = draft(s)
  if not current then notify(err); return end
  if not first and s.ci_section and vim.fn.line('.') >= s.ci_section.first and vim.fn.line('.') <= s.ci_section.last then
    s.ci_expanded = mode == 'show' or (mode == 'toggle' and not s.ci_expanded)
    render(s, current)
    vim.api.nvim_win_set_cursor(0, { s.ci_section.first, 0 })
    if done then done() end
    return
  end
  if not first and vim.fn.line('.') <= #s.prefix then
    s.header_expanded = mode == 'show' or (mode == 'toggle' and s.header_expanded == false)
    render(s, current)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    if done then done() end
    return
  end
  local row = vim.fn.line('.') - delta(s)
  if not first and row >= s.conversation_section.first and row <= s.conversation_section.last then
    s.conversation_expanded = mode == 'show' or (mode == 'toggle' and not s.conversation_expanded)
    render(s, current)
    vim.api.nvim_win_set_cursor(0, { s.conversation_section.first, 0 })
    if done then done() end
    return
  end
  if not first and row >= s.commit_section.first and row <= s.commit_section.last then
    s.commits_expanded = mode == 'show' or (mode == 'toggle' and not s.commits_expanded)
    render(s, current)
    vim.api.nvim_win_set_cursor(0, { s.commit_section.first, 0 })
    if done then done() end
    return
  end
  if not first and row == s.changes_section.first then
    s.changes_expanded = mode == 'show' or (mode == 'toggle' and s.changes_expanded == false)
    render(s, current)
    vim.api.nvim_win_set_cursor(0, { s.changes_section.first + delta(s), 0 })
    if done then done() end
    return
  end
  local paths = {}
  for row = first or vim.fn.line('.'), last or vim.fn.line('.') do
    local entry = M.entry_at(s.buf, row)
    if entry then paths[entry.path] = entry end
  end
  if vim.tbl_isempty(paths) then for _, entry in ipairs(s.model.entries) do paths[entry.path] = entry end end
  local cursor = M.entry_at(s.buf, vim.fn.line('.'))
  local source_win = vim.api.nvim_get_current_win()
  local expanded = vim.deepcopy(s.expanded)
  local missing = false
  for path, entry in pairs(paths) do
    expanded[path] = mode == 'show' or (mode == 'toggle' and not s.expanded[path])
    if expanded[path] and not entry.patch then missing = true end
  end
  if missing then
      if s.expanding then return end
      s.expanding = true
      local task = require('git.features.async').run(s.model.root, function()
        for pending, item in pairs(paths) do if expanded[pending] then
          local patch, failure = changes.patch(s.model, item)
          if not patch then error(failure, 0) end
        end end
      end, function(ok, failure)
        s.expanding = false
        if not live(s) then return end
        if not ok then notify(failure); return end
        local latest, read_err = draft(s)
        if not latest then notify(read_err); return end
        s.expanded = expanded; render(s, latest)
        if cursor then focus(s, cursor.path, source_win) end
        if done then done() end
      end)
      s.patch_task = task
      return
  end
  s.expanded = expanded; render(s, current)
  if cursor then focus(s, cursor.path, source_win) end
  if done then done() end
end
local function next_diff_item(s, count, win)
  local function advance()
    if not live(s) or vim.api.nvim_get_current_win() ~= win or vim.api.nvim_win_get_buf(win) ~= s.buf then return end
    if not unfold_changes(s, win) then return end
    while count > 0 do
      local row = vim.api.nvim_win_get_cursor(win)[1]
      local entry = M.entry_at(s.buf, row)
      if entry and not s.expanded[entry.path] then
        toggle(s, 'show', row, row, advance)
        return
      end
      local lines = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
      local target
      for at = row + 1, #lines do
        local _, info = M.entry_at(s.buf, at)
        if info and (info.header or lines[at]:match('^@@')) then target = at; break end
      end
      if not target then break end
      vim.api.nvim_win_set_cursor(win, { target, 0 })
      count = count - 1
    end
    vim.cmd('normal! zt')
  end
  advance()
end
local function move(s, direction, hunks, expand)
  if not unfold_changes(s, vim.api.nvim_get_current_win(), direction < 0) then return end
  local entry = M.entry_at(s.buf, vim.fn.line('.'))
  if hunks and entry and not s.expanded[entry.path] then
    toggle(s, 'show', nil, nil, function() move(s, direction, hunks, expand) end)
    return
  end
  local row, lines = vim.fn.line('.'), vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
  local candidates = {}
  for at, info in pairs(s.rows) do
    local target = at + delta(s)
    if (target - row) * direction > 0 and (hunks and lines[target]:match('^@@') or not hunks and info.header) then
      candidates[#candidates + 1] = target
    end
  end
  table.sort(candidates, function(a, b) return direction > 0 and a < b or direction < 0 and a > b end)
  local index = math.min(vim.v.count1, #candidates)
  local target = candidates[index]
  if not target then return end
  local changed = false
  if expand then
    local current, err = draft(s)
    if not current then notify(err); return end
    local destination = M.entry_at(s.buf, target)
    local function collapse(item)
      if item and item.path ~= destination.path and s.expanded[item.path] then
        s.expanded[item.path], changed = false, true
      end
    end
    collapse(entry)
    for skipped = 1, index - 1 do collapse(M.entry_at(s.buf, candidates[skipped])) end
    if changed then
      render(s, current)
      -- Collapsing earlier diffs changes row numbers; retain the target by path.
      focus(s, destination.path, vim.api.nvim_get_current_win())
    end
  end
  if not changed then vim.api.nvim_win_set_cursor(0, { target, 0 }) end
  if expand then toggle(s, 'show') end
end
local function comments(s)
  if conversation_selected(s) then return require('git.features.pr_review').new_comment(s.model, nil, { destination = 'p' }) end
  local _, info = M.entry_at(s.buf, vim.fn.line('.'))
  require('git.features.pr_threads').select(s.model.ctx, info and info.threads or s.model.threads,
    s.model.review and s.model.review.viewer)
end
local function comment_actions(s)
  local item = M.conversation_at(s.buf, vim.fn.line('.'))
  local selected = {}
  if item then selected = { item }
  elseif conversation_selected(s) then selected = s.model.conversation and s.model.conversation.entries or {}
  else
    local _, info = M.entry_at(s.buf, vim.fn.line('.'))
    for _, thread in ipairs(info and info.threads or s.model.threads) do
      for _, comment in ipairs(thread.comments) do
        local copy = vim.deepcopy(comment)
        copy.kind, copy.review_id = 'inline', thread.review_id
        selected[#selected + 1] = copy
      end
    end
  end
  require('git.features.pr_comment_actions').select(s.ctx, selected, s.model.review and s.model.review.viewer)
end
local move_comment
local function resolve_comments(s)
  if conversation_selected(s) then notify('PR conversation comments do not have review-thread resolution'); return end
  local _, info = M.entry_at(s.buf, vim.fn.line('.'))
  require('git.features.pr_thread_status').toggle(s.ctx, info and info.threads or s.model.threads)
end
local function preview_comments(s, focus_preview)
  if conversation_selected(s) then return M.show_conversation(s.buf) end
  local _, info = M.entry_at(s.buf, vim.fn.line('.'))
  require('git.features.pr_comment_preview').show({ buf = s.buf, win = vim.api.nvim_get_current_win(),
    ctx = s.ctx, viewer = s.model.review and s.model.review.viewer,
    threads = info and info.threads or s.model.threads, focus = focus_preview,
    reply = function() comments(s) end,
    resolve = function() resolve_comments(s) end,
    navigate = function(direction, count) move_comment(s, direction, count) end })
end
local function comment_targets(s)
  local inline, targets, placed = {}, {}, {}
  local offset = delta(s)
  for row, info in pairs(s.rows) do if not info.header then
    for _, thread in ipairs(info.threads) do inline[thread.id] = math.min(inline[thread.id] or math.huge, row + offset) end
  end end
  for row, info in pairs(s.rows) do if info.header then
    for _, thread in ipairs(info.threads) do
      placed[thread.id] = true
      local closed = not s.expanded[info.entry.path]
      local at = not closed and inline[thread.id] or row + offset
      targets[at] = { row = at, entry = info.entry, closed = closed }
    end
  end end
  for _, thread in ipairs(s.model.threads) do if not placed[thread.id] then
    local at = vim.api.nvim_buf_line_count(s.buf)
    targets[at] = { row = at }
  end end
  return targets
end
move_comment = function(s, direction, count)
  local win, moved = vim.api.nvim_get_current_win(), false
  local function active()
    return live(s) and vim.api.nvim_win_is_valid(win) and vim.api.nvim_get_current_win() == win
      and vim.api.nvim_win_get_buf(win) == s.buf
  end
  local function finish()
    if moved and active() then vim.cmd('normal! zt'); preview_comments(s, false) end
  end
  local advance
  advance = function()
    if not active() then return end
    if not unfold_changes(s, win, direction < 0) then return end
    while count > 0 do
      local row, target = vim.api.nvim_win_get_cursor(win)[1], nil
      for at, item in pairs(comment_targets(s)) do
        if (at - row) * direction > 0 or (direction > 0 and at == row and item.closed) then
          if not target or (at - target.row) * direction < 0 then target = item end
        end
      end
      if not target then finish(); return end
      if target.closed then
        toggle(s, 'show', target.row, target.row, function()
          if not active() then return end
          local selected
          for _, item in pairs(comment_targets(s)) do
            if item.entry and item.entry.path == target.entry.path
              and (not selected or (item.row - selected.row) * direction < 0) then selected = item end
          end
          if not selected then return end
          vim.api.nvim_win_set_cursor(win, { selected.row, 0 })
          count, moved = count - 1, true
          advance()
        end)
        return
      end
      vim.api.nvim_win_set_cursor(win, { target.row, 0 })
      count, moved = count - 1, true
    end
    finish()
  end
  advance()
end
local function blob(s, entry, before, coordinate)
  local path = before and (entry.old_path or entry.path) or entry.path
  local revision = before and s.model.base or s.model.hash
  local missing = before and entry.status == 'A' or not before and entry.status == 'D'
  local content, err = '', nil
  if not missing then content, err = changes.git(s.model.root, { 'show', revision .. ':' .. path }) end
  if not content then notify(err); return end
  local b = vim.api.nvim_create_buf(false, true)
  local names = require('git.buffer_names')
  names.assign(b, names.uri('git-pr-blob', s.model.root, revision .. '/' .. (missing and 'missing/' or '') .. path))
  vim.bo[b].buftype, vim.bo[b].bufhidden, vim.bo[b].swapfile = 'nofile', 'wipe', false
  vim.api.nvim_buf_set_lines(b, 0, -1, false, changes.lines(content))
  vim.bo[b].modifiable, vim.bo[b].readonly = false, true
  utils.set_buf_work_tree(b, s.model.root)
  vim.api.nvim_win_set_buf(0, b)
  vim.bo[b].filetype = vim.filetype.match({ filename = path }) or ''
  vim.wo.wrap = false
  if coordinate then
    local line = before and coordinate.left or nil
    if not before then line = coordinate.right end
    if line then vim.api.nvim_win_set_cursor(0, { math.max(1, math.min(line, vim.api.nvim_buf_line_count(b))), 0 }) end
  end
  vim.keymap.set('n', 'q', function() if #vim.api.nvim_list_tabpages() > 1 then vim.cmd('tabclose') else vim.cmd('close') end end,
    { buffer = b, silent = true })
  return b
end
local function diff(s, horizontal)
  local entry, info = M.entry_at(s.buf, vim.fn.line('.'))
  if not entry then M.diffview(s.buf); return end
  if entry.binary then M.diffview(s.buf, entry.path); return end
  local source = vim.api.nvim_get_current_win()
  vim.cmd('tabnew')
  if not blob(s, entry, true, info.coordinate) then vim.cmd('tabclose'); return end
  vim.cmd('diffthis')
  local left = vim.api.nvim_get_current_win()
  vim.cmd(horizontal and 'belowright split' or 'rightbelow vsplit')
  if not blob(s, entry, false, info.coordinate) then vim.cmd('tabclose'); return end
  vim.cmd('diffthis')
  require('git.features.split_diff').attach(left, vim.api.nvim_get_current_win())
  require('git.features.pr_split').attach(s.model, entry, left, vim.api.nvim_get_current_win(), source)
  vim.cmd('wincmd =')
end
function M.diffview(buf, path)
  local s = states[buf]
  if not s or not s.model then return end
  vim.api.nvim_buf_call(buf, function()
    -- Diffview resolves its repository from cwd, so use its explicit -C flag.
    local args = { '-C=' .. s.model.root, s.model.base .. '..' .. s.model.hash }
    if path then vim.list_extend(args, { '--', path }) end
    vim.api.nvim_cmd({ cmd = 'DiffviewOpen', args = args }, {})
    local lib, bridge = package.loaded['diffview.lib'], package.loaded['diffview_extension.github_context']
    local view = lib and lib.get_current_view()
    if bridge and view then bridge.associate(view, s.ctx) end
  end)
end
function M.refresh(buf, discard, preserve)
  local s = states[buf]
  if not s or s.loading or s.saving or s.expanding or s.viewed_pending then return end
  if s.model and edited(s) then
    if not discard and not preserve then vim.notify('Save or undo the PR draft before refreshing', vim.log.levels.WARN); return end
    if discard then render(s) end
  end
  s.loading = true
  local expected = s.model
  local expanded = vim.deepcopy(s.expanded)
  s.task = actions.run(vim.tbl_extend('force', s.ctx, { notify_change = false }), function(ctx)
    return model_api.load(ctx, { previous = expected, expanded = expanded })
  end, function(model)
    s.loading = false
    if not live(s) or s.model ~= expected then return end
    -- An edit made during the network request must survive.
    local current = s.model and draft(s) or nil
    if s.model and not current then notify('PR changed locally during refresh; undo protected edits and refresh'); return end
    local dirty = s.model and edited(s)
    if not dirty then s.metadata_conflict = false
    elseif s.model.pr.title ~= model.pr.title or s.model.pr.body ~= model.pr.body then s.metadata_conflict = true end
    s.model, s.ctx = model, model.ctx
    local names = require('git.buffer_names')
    names.assign(s.buf, names.uri('git-pr', model.root, model.ctx.host .. '/' .. model.ctx.repo .. '/pull/' .. model.ctx.number))
    render(s, dirty and current or nil)
  end, true, function(err)
    s.loading = false
    if live(s) and not s.model then
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'Could not load PR: ' .. tostring(err):gsub('[\r\n]', ' '), 'R retries · q closes' })
      vim.bo[buf].modifiable, vim.bo[buf].modified = false, false
    end
  end)
end
function M.write(buf)
  local s = states[buf]
  if not s or not s.model then return end
  if s.saving or s.loading then error('A PR request is already running') end
  if s.metadata_conflict then error('PR metadata changed during refresh; preserve your draft and reload before saving') end
  local current, err = draft(s)
  if not current then error(err) end
  if not edited(s) then vim.bo[buf].modified = false; return end
  local title, body = current[1], table.concat(vim.list_slice(current, 3), '\n')
  local original = s.model.pr
  s.saving = true
  actions.run(s.ctx, function(ctx)
    local remote = github.pr(ctx)
    if remote.title ~= original.title or (remote.body or '') ~= (original.body or '') then
      error('PR title/description changed on GitHub; preserve your draft and reload before overwriting', 0)
    end
    return github.json(ctx, { 'api', '--hostname', ctx.host, '--method', 'PATCH',
      ('repos/%s/pulls/%d'):format(ctx.repo, ctx.number), '--input', '-' }, { stdin = vim.json.encode({ title = title, body = body }) })
  end, function()
    s.saving = false
    if not live(s) then return end
    local latest = draft(s)
    s.model.pr.title, s.model.pr.body = title, body
    if latest then render(s, latest) end
    vim.notify('PR title and description saved')
  end, true, function() s.saving = false end)
end
local function show_help()
  local groups = {
    { title = 'Title / description', entries = {
      { 'cw / A', 'Edit title and description' },
      { ':w', 'Save title and description to GitHub' },
      { '<C-s>', 'Save title and description to GitHub' },
    } },
    { title = 'Diff navigation', entries = {
      { 'gu', 'Go to changed files' },
      { 'gp', 'Go to commits' },
      { 'gh', 'Go to header' },
      { 'gU', 'Go to CI (UnitTest)' },
      { 'gco', 'Go to Conversation' },
      { ']u / [u', 'Next / previous unviewed file' },
      { 'o / = / <Tab>', 'Toggle section / file diff' },
      { '> / <', 'Expand / collapse section or files' },
      { 'i', 'Expand and move to next file / hunk' },
      { ']m / [m', 'Next / previous file' },
      { ']] / [[', 'Collapse current and expand next / previous file' },
      { 'J / K', 'Next / previous hunk (also ]c / [c)' },
    } },
    { title = 'Compare / open', entries = {
      { 'd / dd / dv', 'Vertical file diff' },
      { 'dh / ds', 'Horizontal file diff' },
      { 'D', 'Entire PR in Diffview' },
      { '<CR>', 'Toggle section / open target or CI details' },
      { 'gf', 'Open worktree file' },
      { 'gq', 'Changed files in quickfix' },
      { 'gD', 'Diff display settings' },
    } },
    { title = 'Comments / review', entries = {
      { 'gF', 'Toggle file Viewed on GitHub' },
      { ']t / [t', 'Comment and preview (also ]C / [C)' },
      { 'gk', 'Preview conversation (repeat to focus)' },
      { 'gc', 'Read / reply to review threads' },
      { 'gA', 'Reactions / edit / delete / apply suggestion' },
      { 'gc (Conversation)', 'Read history / write PR comment' },
      { 'gR', 'Resolve / reopen a published review thread' },
      { 'gC', 'New PR / diff / review draft comment' },
      { 'gcn / gcr / gcp', 'Direct comment / review draft / PR comment' },
      { 'gr', 'Start / resume / migrate / submit review' },
      { 'gra / grm / grr', 'Direct approval / comment review / change request' },
      { 'O', 'Review PR in Octo' },
    } },
    { title = 'GitHub / panel', entries = {
      { 'gE', 'Change header metadata / open metadata menu' },
      { '<Space><Space> / N', 'PR actions: comments, review, diffs and GitHub' },
      { 'gx', 'Browser: PR / commit / CI / comment' },
      { 'gy', 'Copy PR URL' },
      { 'R', 'Collapse all diffs and refresh' },
      { 'q', 'Close PR status' },
    } },
    { title = 'Visual selections', entries = {
      { 'o / =', 'Toggle selected file diffs' },
      { '> / <', 'Expand / collapse selected file diffs' },
      { 'gC', 'Comment on selected diff lines' },
    } },
  }
  local width, lines, headings = 0, {}, {}
  for _, group in ipairs(groups) do
    for _, entry in ipairs(group.entries) do width = math.max(width, vim.fn.strdisplaywidth(entry[1])) end
  end
  for _, group in ipairs(groups) do
    if #lines > 0 then lines[#lines + 1] = '' end
    lines[#lines + 1], headings[group.title] = group.title, true
    for _, entry in ipairs(group.entries) do
      local prefix = entry[1] .. string.rep(' ', width - vim.fn.strdisplaywidth(entry[1]) + 2)
      local available = math.max(1, vim.o.columns - 4 - width - 2)
      local label = ''
      for word in entry[2]:gmatch('%S+') do
        local next_label = label == '' and word or label .. ' ' .. word
        if label ~= '' and vim.fn.strdisplaywidth(next_label) > available then
          lines[#lines + 1] = prefix .. label
          prefix, label = string.rep(' ', width + 2), word
        else label = next_label end
      end
      lines[#lines + 1] = prefix .. label
    end
  end
  vim.list_extend(lines, { '',
    'Inside title / description, normal editing keys apply.',
    'Other metadata and diffs are read-only review snapshots.',
    'File / outdated threads are available on file headers or gc.',
  })
  return require('git.features.help').show_text('PR status', lines, { headings = headings })
end
local function display_menu()
  local choices = {}
  for _, style in ipairs({ 'delta', 'github', 'diffs', 'treesitter' }) do
    choices[#choices + 1] = { key = style:sub(1, 1), label = style, run = function() syntax.set_word_diff_style(style) end }
  end
  choices[1].key = 'l'
  choices[#choices + 1] = { key = 'n', label = 'Toggle new-file diff colors', run = syntax.toggle_new_file_highlight }
  return require('git.features.transient_menu').show({ kind = 'pr-display', title = 'PR diff display',
    groups = { { title = 'Word diff', actions = choices } } })
end
local function refresh_prompt(s)
  if s.saving or s.viewed_pending then return end
  local discard = s.model and edited(s)
  if discard then
    if vim.fn.confirm('Discard PR draft and reload from GitHub?', '&Reload\n&Keep', 2) ~= 1 then return end
  end
  if s.model then
    local win = vim.api.nvim_get_current_win()
    local entry = M.entry_at(s.buf, vim.api.nvim_win_get_cursor(win)[1])
    local current = not discard and draft(s) or nil
    -- Cancel a pending expansion before clearing its saved file choices.
    -- An existing refresh can finish, but its result must keep them closed.
    if s.patch_task then s.patch_task.cancel() end
    s.patch_task, s.expanding, s.expanded = nil, false, {}
    render(s, current)
    if entry then focus(s, entry.path, win) end
  end
  M.refresh(s.buf, discard)
end
function M.action_groups(buf)
  local s = states[buf]
  local win = vim.api.nvim_get_current_win()
  local expected, cursor = s and s.model, vim.api.nvim_win_get_cursor(win)
  local entry = s and s.model and M.entry_at(buf, vim.fn.line('.'))
  local function action(key, label, fn, available)
    return { key = key, label = label, enabled = s and s.model ~= nil and available ~= false or false,
      run = function()
        if not live(s) or vim.api.nvim_get_current_win() ~= win or vim.api.nvim_win_get_buf(win) ~= buf then
          vim.notify('PR source window changed; reopen the action menu', vim.log.levels.WARN); return
        end
        if s.model ~= expected or not vim.deep_equal(vim.api.nvim_win_get_cursor(win), cursor) then
          vim.notify('PR context changed; reopen the action menu', vim.log.levels.WARN); return
        end
        fn()
      end }
  end
  return {
    { title = 'Comments / review', actions = {
      action('c', 'New comment…', function()
        local review = require('git.features.pr_review')
        local target, err = review.target(buf, vim.fn.line('.'), vim.fn.line('.'))
        if err then notify(err); return end
        review.new_comment(s.model, target)
      end),
      action('r', 'Review / resolve threads…', function() require('git.features.pr_review').menu(s.model) end),
      action('t', 'Read / reply to threads…', function() comments(s) end),
      action('p', 'Read PR conversation', function() M.show_conversation(buf) end),
      action('v', 'Preview conversation', function() preview_comments(s, true) end),
      action('A', 'Comment reactions / edit / delete / suggestion…', function() comment_actions(s) end),
    } },
    { title = 'Diff / files', actions = {
      action('f', 'Compare selected file', function() diff(s) end, entry ~= nil),
      action('D', 'Open PR in Diffview', function() M.diffview(buf) end),
      action('s', 'Diff display settings…', display_menu),
    } },
    { title = 'PR panel', actions = {
      action('E', 'Edit title / description', function()
        vim.api.nvim_win_set_cursor(0, { #s.prefix + 1, 0 }); vim.cmd('startinsert')
      end),
      action('M', 'Change labels / assignees / review requests…', function() require('git.features.pr_metadata').menu(s.ctx) end),
      action('o', 'Toggle header / CI / conversation / commits / changes / file diff', function() toggle(s, 'toggle') end),
      action('>', 'Expand section / file diffs', function() toggle(s, 'show') end),
      action('<', 'Collapse section / file diffs', function() toggle(s, 'hide') end),
      action('R', 'Collapse all diffs and refresh', function() refresh_prompt(s) end),
      action('?', 'PR status key guide', show_help),
    } },
  }
end
local function attach(s)
  local b = s.buf
  local function native_key(key)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), 'ni', false)
  end
  s.edit_guard = require('git.features.pr_edit_guard').attach(s, function(message) render(s, message) end)
  -- Refresh title decoration and Markdown regions after text changes. Full panel rendering
  -- on each keystroke would interfere with undo and copy expanded diff text.
  local title_pending = false
  vim.api.nvim_buf_attach(b, false, { on_lines = function()
    if not s.model or s.rendering or title_pending then return end
    title_pending = true
    vim.schedule(function()
      title_pending = false
      if live(s) then
        paint_title(s)
        paint_markdown(s)
      end
    end)
  end })
  -- Native entry/operator keys only belong to the editable draft. The line
  -- guard also catches ranges, paste and Insert-mode edits crossing its edges.
  for _, key in ipairs({ 'a', 'I', 'gI', '<Insert>', 's', 'S', 'C', 'c', 'x', 'X', 'r', 'p', 'P', 'gP', '~', 'g~' }) do
    vim.keymap.set('n', key, function()
      return s.model and editable_row(s, vim.fn.line('.')) and key or ''
    end, { buffer = b, expr = true, silent = true, desc = 'Edit only PR title / description' })
  end
  for _, key in ipairs({ 'c', 's', 'S', 'C', 'd', 'x', 'X', 'p', 'P', 'r', '~' }) do
    vim.keymap.set('x', key, function()
      local first, last = math.min(vim.fn.line('v'), vim.fn.line('.')), math.max(vim.fn.line('v'), vim.fn.line('.'))
      return s.model and editable_row(s, first) and editable_row(s, last) and key or '<Esc>'
    end, { buffer = b, expr = true, silent = true, desc = 'Edit only selected PR title / description' })
  end
  local function map(keys, fn, description, native)
    for _, key in ipairs(type(keys) == 'table' and keys or { keys }) do
      vim.keymap.set('n', key, function()
        if not s.model then return end
        if native and editable_row(s, vim.fn.line('.')) then
          native_key(key); return
        end
        fn()
      end, { buffer = b, silent = true, nowait = not vim.tbl_contains({ 'd', 'g', '[', ']', 'gc', 'gr' }, key), desc = description })
    end
  end
  for key, section in pairs({ gu = 'changes', gp = 'commits', gh = 'header', gU = 'ci', gco = 'conversation' }) do
    local target = section
    map(key, function() focus_section(s, target) end, 'Go to PR ' .. target .. ' section')
  end
  map({ 'o', '=', '<Tab>' }, function() toggle(s, 'toggle') end, 'Toggle PR section / file diff', true)
  map('>', function() toggle(s, 'show') end, 'Expand PR section / file diffs', true)
  map('<', function() toggle(s, 'hide') end, 'Collapse PR section / file diffs', true)
  for _, key in ipairs({ 'o', '=', '>', '<' }) do
    local mode = ({ o = 'toggle', ['='] = 'toggle', ['>'] = 'show', ['<'] = 'hide' })[key]
    vim.keymap.set('x', key, function()
      local first, last = math.min(vim.fn.line('v'), vim.fn.line('.')), math.max(vim.fn.line('v'), vim.fn.line('.'))
      if editable_row(s, first) and editable_row(s, last) then native_key(key); return end
      if editable_row(s, first) then vim.cmd('normal! \27'); return end
      vim.cmd('normal! \27'); toggle(s, mode, first, last)
    end, { buffer = b, silent = true, desc = 'Toggle / expand / collapse selected PR files' })
  end
  map({ ']m', ']/' }, function() move(s, 1) end, 'Next PR file')
  map(']u', function() move_unviewed(s, 1) end, 'Next unviewed PR file')
  map('[u', function() move_unviewed(s, -1) end, 'Previous unviewed PR file')
  map('gF', function() toggle_viewed(s) end, 'Toggle file Viewed on GitHub')
  vim.keymap.set('n', 'i', function()
    if not s.model then return '' end
    if editable_row(s, vim.fn.line('.')) then return 'i' end
    local count, win = vim.v.count1, vim.api.nvim_get_current_win()
    -- Expression mappings cannot edit buffers; lazy expansion starts next tick.
    vim.schedule(function() next_diff_item(s, count, win) end)
    return ''
  end, { buffer = b, expr = true, silent = true, nowait = true, desc = 'Expand and jump to next PR diff item' })
  map({ '[m', '[/' }, function() move(s, -1) end, 'Previous PR file')
  map(']]', function() move(s, 1, false, true) end, 'Collapse current and expand next file')
  map('[[', function() move(s, -1, false, true) end, 'Collapse current and expand previous file')
  map({ 'J', ']c' }, function() move(s, 1, true) end, 'Next PR hunk', true)
  map({ 'K', '[c' }, function() move(s, -1, true) end, 'Previous PR hunk', true)
  map({ 'd', 'dd', 'dv' }, function() diff(s) end, 'Compare selected PR file', true)
  map({ 'dh', 'ds' }, function() diff(s, true) end, 'Compare PR file horizontally')
  map('D', function() M.diffview(b) end, 'Open entire PR in Diffview', true)
  map('gc', function() comments(s) end, 'Open review thread / reply')
  map('gA', function() comment_actions(s) end, 'Comment reactions / edit / delete / apply suggestion')
  map('gE', function()
    local field = s.metadata_rows and s.metadata_rows[vim.fn.line('.')]
    local metadata = require('git.features.pr_metadata')
    if field then metadata.choose(s.ctx, field) else metadata.menu(s.ctx) end
  end, 'Change labels / assignees / review requests')
  map('gR', function() resolve_comments(s) end, 'Resolve / reopen review thread')
  map('gk', function() preview_comments(s, true) end, 'Preview PR conversation', true)
  map({ ']t', ']C' }, function() move_comment(s, 1, vim.v.count1) end, 'Next PR comment and preview')
  map({ '[t', '[C' }, function() move_comment(s, -1, vim.v.count1) end, 'Previous PR comment and preview')
  local function new_comment(first, last, destination)
    local review = require('git.features.pr_review')
    local target, err = review.target(b, first, last)
    if err then notify(err); return end
    review.new_comment(s.model, target, { destination = destination })
  end
  map('gC', function() new_comment(vim.fn.line('.'), vim.fn.line('.')) end, 'Write PR / diff / review comment')
  for key, destination in pairs({ gcn = 'c', gcr = 'r', gcp = 'p' }) do
    map(key, function() new_comment(vim.fn.line('.'), vim.fn.line('.'), destination) end, 'Direct PR / diff / review draft comment')
  end
  map('gr', function() require('git.features.pr_review').menu(s.model) end, 'Start / resume / submit PR review')
  for key, event in pairs({ gra = 'APPROVE', grm = 'COMMENT', grr = 'REQUEST_CHANGES' }) do
    map(key, function() require('git.features.pr_review').menu(s.model, { submit = event }) end, 'Direct PR review submission composer')
  end
  for _, key in ipairs({ 'gC', 'gcn', 'gcr', 'gcp' }) do
    local destination = ({ gcn = 'c', gcr = 'r', gcp = 'p' })[key]
    vim.keymap.set('x', key, function()
      if not s.model then return end
      local first, last = math.min(vim.fn.line('v'), vim.fn.line('.')), math.max(vim.fn.line('v'), vim.fn.line('.'))
      if editable_row(s, first) then notify('Select diff lines outside the title / description'); return end
      vim.cmd('normal! \27'); new_comment(first, last, destination)
    end, { buffer = b, silent = true, desc = 'Comment on selected PR diff lines' })
  end
  local ci_detail_key = ((vim.g.git_ci or {}).keys or {}).details
  if ci_detail_key and ci_detail_key ~= '<CR>' then
    map(ci_detail_key, function()
      local check = M.check_at(b, vim.fn.line('.'))
      if check then require('git.features.ci.view').open(s.ctx, check) end
    end, 'Open selected CI check details', true)
  end
  map('<CR>', function()
    if vim.fn.line('.') - delta(s) == s.conversation_section.first then toggle(s, 'toggle'); return end
    if conversation_selected(s) then
      local item = M.conversation_at(b, vim.fn.line('.'))
      if require('git.features.pr_timeline').is_event(item) then vim.ui.open(item.url) else comments(s) end
      return
    end
    if s.ci_section and vim.fn.line('.') == s.ci_section.first then toggle(s, 'toggle'); return end
    local check = M.check_at(b, vim.fn.line('.'))
    if check and (ci_detail_key == nil or ci_detail_key == '<CR>') then require('git.features.ci.view').open(s.ctx, check); return end
    local link = link_at(s)
    if link then vim.ui.open(link); return end
    local commit = M.commit_at(b, vim.fn.line('.'))
    if commit then
      require('git.features.commit').open({ work_tree = s.model.root, revision = commit.hash, split = true })
      return
    end
    if vim.fn.line('.') - delta(s) == s.commit_section.first then toggle(s, 'toggle'); return end
    if vim.fn.line('.') - delta(s) == s.changes_section.first then toggle(s, 'toggle'); return end
    local entry, info = M.entry_at(b, vim.fn.line('.'))
    if info and #info.threads > 0 then comments(s)
    elseif entry then blob(s, entry, false, info.coordinate) end
  end, 'Toggle PR section / open link, commit, thread or head file', true)
  map('gf', function()
    local entry = M.entry_at(b, vim.fn.line('.'))
    if entry then
      local path = utils.worktree_relative_abs_path(s.model.root, entry.path)
      if path then vim.cmd('edit ' .. vim.fn.fnameescape(path)) end
    end
  end, 'Open worktree file')
  map({ 'cw', 'A' }, function() vim.api.nvim_win_set_cursor(0, { #s.prefix + 1, 0 }); vim.cmd('startinsert') end, 'Edit PR title / description', true)
  map('O', function() actions.octo(s.ctx, true) end, 'Review PR in Octo', true)
  map('gx', function()
    local _, info = M.entry_at(b, vim.fn.line('.'))
    local thread = info and info.threads[1]
    local commit = M.commit_at(b, vim.fn.line('.'))
    local commit_url = commit and ('https://%s/%s/commit/%s'):format(s.ctx.host, s.ctx.repo, commit.hash)
    vim.ui.open(link_at(s) or commit_url or (thread and thread.url) or s.ctx.url)
  end, 'Open PR / commit / CI check / comment on GitHub')
  map('gy', function() vim.fn.setreg('"', s.ctx.url); pcall(vim.fn.setreg, '+', s.ctx.url) end, 'Copy PR URL')
  map('gq', function()
    local items = {}
    for _, entry in ipairs(s.model.entries) do
      local path = utils.worktree_relative_abs_path(s.model.root, entry.path)
      if path then items[#items + 1] = { filename = path, lnum = 1 } end
    end
    vim.fn.setqflist({}, ' ', { title = 'PR #' .. s.ctx.number, items = items }); vim.cmd('copen')
  end, 'PR files in quickfix')
  map('gD', display_menu, 'PR diff display settings')
  -- Loading and failed requests still need an exit even without a model.
  vim.keymap.set('n', 'q', function()
    require('utilities').smart_close({ force = true, before = function()
      if s.model and edited(s) and vim.fn.confirm('Discard unsaved PR title/description?', '&Discard\n&Keep', 2) ~= 1 then return false end
    end })
  end, { buffer = b, silent = true, desc = 'Close PR status' })
  vim.keymap.set('n', 'R', function()
    if s.model and editable_row(s, vim.fn.line('.')) then native_key('R'); return end
    refresh_prompt(s)
  end, { buffer = b, silent = true, desc = 'Collapse all diffs and refresh PR status' })
  map('?', show_help, 'PR status key guide')
  actions.attach(b)
  vim.keymap.set('n', '<Space><Space>', function() actions.open(actions.context(b)) end,
    { buffer = b, silent = true, desc = 'PR action menu' })
  local group = vim.api.nvim_create_augroup('GitPr' .. b, { clear = true })
  vim.api.nvim_create_autocmd({ 'InsertEnter', 'CursorMovedI' }, { group = group, buffer = b, callback = function()
    if not s.model or not editable_row(s, vim.fn.line('.')) then vim.cmd('stopinsert') end
  end })
  vim.api.nvim_create_autocmd('BufWriteCmd', { group = group, buffer = b, callback = function(ev)
    if ev.match ~= vim.api.nvim_buf_get_name(b) then error('Use :w without a filename to save PR metadata') end
    M.write(b)
  end })
  vim.keymap.set({ 'n', 'i' }, '<C-s>', function() vim.cmd('write') end,
    { buffer = b, silent = true, desc = 'Save PR title and description' })
  vim.api.nvim_create_autocmd('User', { group = group, pattern = 'GitHubChanged', callback = function(ev)
    local ctx = ev.data or {}
    if s.model and ctx.resource_kind ~= 'issue' and ctx.host == s.ctx.host and ctx.repo == s.ctx.repo and (not ctx.number or ctx.number == s.ctx.number) then
      M.refresh(b, false, true)
    end
  end })
  vim.api.nvim_create_autocmd('User', { group = group, pattern = 'GitPrCommentsRead', callback = function(ev)
    local ctx = ev.data or {}
    local viewer = s.model and (s.model.review and s.model.review.viewer or s.model.viewed and s.model.viewed.viewer)
    if s.model and ctx.host == s.ctx.host and ctx.repo == s.ctx.repo and ctx.number == s.ctx.number
      and ctx.viewer == viewer then paint_comments(s) end
  end })
  vim.api.nvim_create_autocmd('User', { group = group, pattern = 'GitPrViewedChanged', callback = function(ev)
    local ctx = ev.data or {}
    if not s.model or ctx.host ~= s.ctx.host or ctx.repo ~= s.ctx.repo or ctx.number ~= s.ctx.number then return end
    local current = draft(s)
    if not current then return end
    local ok = pcall(viewed.apply, s.model, ctx.status)
    if ok then render(s, current) end
  end })
  vim.api.nvim_create_autocmd('BufWipeout', { group = group, buffer = b, once = true, callback = function()
    states[b] = nil
    if s.patch_task then s.patch_task.cancel() end
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end })
  syntax.attach(b, { diff_source = function(hunk)
    return s.model and changes.highlight_source(s.model, M.entry_at(b, hunk.start_line))
  end, prefetch = function()
    local specs = {}
    for _, entry in ipairs(s.model and s.model.entries or {}) do
      local spec = changes.highlight_source(s.model, entry)
      if spec then specs[#specs + 1] = { filename = entry.path, spec = spec } end
    end
    return specs
  end })
end
function M.open(opts)
  opts = vim.deepcopy(opts or {})
  opts.root = opts.root or utils.get_buf_work_tree(vim.api.nvim_get_current_buf()) or utils.get_work_tree({})
  if not opts.root then notify('Not in a Git repository'); return end
  opts.root = utils.normalize_path(opts.root)
  local identity = opts.url or (opts.root .. '/' .. tostring(opts.number or 'current'))
  local requested = github.url_context(opts.url) or (opts.host and opts.repo and opts.number and opts)
  if not opts.url and not opts.number then
    -- Resolved PRs remain pinned, while an implicit lookup belongs to the
    -- checked-out branch (and its optional worktree association).
    local ref = vim.system({ 'git', 'symbolic-ref', '--quiet', 'HEAD' }, { cwd = opts.root, text = true }):wait()
    if ref.code == 0 then
      local branch = vim.trim(ref.stdout):gsub('^refs/heads/', '')
      local saved = vim.system({ 'git', 'config', '--get', 'branch.' .. branch .. '.pullRequestUrl' },
        { cwd = opts.root, text = true }):wait()
      identity = identity .. '/' .. vim.trim(ref.stdout) .. '\0' .. (saved.code == 0 and vim.trim(saved.stdout) or '')
      if saved.code == 0 then requested = github.url_context(vim.trim(saved.stdout)) end
    else
      local head = vim.system({ 'git', 'rev-parse', '--verify', 'HEAD' }, { cwd = opts.root, text = true }):wait()
      if head.code ~= 0 then notify('Could not resolve the current Git HEAD'); return end
      identity = identity .. '/detached/' .. vim.trim(head.stdout)
    end
  end
  for b, s in pairs(states) do
    local same_pr = requested and s.ctx.host == requested.host and s.ctx.repo == requested.repo and s.ctx.number == requested.number
    local same_seed = s.identity == identity and (not opts.host or s.ctx.host == opts.host) and (not opts.repo or s.ctx.repo == opts.repo)
    if (same_seed or same_pr) and s.ctx.root == opts.root and vim.api.nvim_buf_is_loaded(b) then
    local win = vim.fn.bufwinid(b)
    if win ~= -1 then vim.api.nvim_set_current_win(win) else utils.open_panel_split(); vim.api.nvim_win_set_buf(0, b) end
    if not s.model then M.refresh(b) end
    return b
  end end
  local b = vim.api.nvim_create_buf(true, false)
  local s = { buf = b, ctx = opts, identity = identity, expanded = {} }
  states[b] = s
  local names = require('git.buffer_names')
  names.assign(b, names.uri('git-pr', opts.root, opts.url or ('pull/' .. tostring(opts.number or 'current'))))
  vim.bo[b].buftype, vim.bo[b].bufhidden, vim.bo[b].swapfile, vim.bo[b].undofile = 'acwrite', 'hide', false, false
  utils.set_buf_work_tree(b, opts.root)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { 'Loading PR metadata and revisions…' })
  vim.bo[b].modified, vim.bo[b].modifiable = false, false
  utils.open_panel_split(); vim.api.nvim_win_set_buf(0, b)
  markdown.prepare(b)
  vim.bo[b].filetype = 'gitpr'
  vim.bo[b].syntax = 'git'
  configure_window(vim.api.nvim_get_current_win())
  attach(s); M.refresh(b)
  return b
end
function M.setup()
  vim.api.nvim_create_user_command('GitPr', function(args)
    local opts = {}
    if args.args ~= '' then
      if github.url_context(args.args) then opts.url = args.args
      elseif tonumber(args.args) then opts.number = tonumber(args.args)
      else notify('Use :GitPr [PR number or URL]'); return end
    end
    M.open(opts)
  end, { nargs = '?', desc = 'Open editable PR status and diffs' })
end
return M

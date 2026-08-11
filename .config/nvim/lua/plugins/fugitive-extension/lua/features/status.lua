local M = {}
local utils = require("fugitive_utils")
local commands = require("features.commands")
local syntax_highlight = require("features.syntax_highlight")
local worktree = require("features.worktree")
local status_renderer = require("features.status_renderer")
local operation = require('features.operation')
local range_diff = require('features.range_diff')
local repository_health = require('features.repository_health')
local notes = require('features.notes')
local index_flags = require('features.index_flags')
local commit_highlight = require('features.commit_highlight')
local pull_requests_by_buf = {}
local pull_request_scope_by_buf = {}
local pull_request_branch_by_buf = {}
local commit_scope_by_buf = {}
local unpushed_commits_by_buf = {}
local status_cursor_anchor_by_buf = {}
local pending_status_cursor_anchors_by_buf = {}
local repository_health_by_buf = {}
local index_flags_by_buf = {}
local index_flags_expanded_by_buf = {}

local function is_status_buffer(bufnr)
  return utils.is_valid_buf(bufnr)
    and (vim.b[bufnr].custom_git_status == true or vim.bo[bufnr].filetype == 'fugitivestatus')
end

local function configure_status_window(winid)
  if not (winid and vim.api.nvim_win_is_valid(winid)) then return end
  vim.api.nvim_set_option_value('foldmethod', 'manual', { win = winid })
  vim.api.nvim_set_option_value('foldenable', false, { win = winid })
  vim.api.nvim_set_option_value('foldcolumn', '0', { win = winid })
end

local function stash_ref_from_line(line)
  return line and line:match('stash@%{%d+%}')
end

local function pull_request_number_from_line(line)
  return line and tonumber(line:match('^#(%d+)%s'))
end

local function recent_commit_lines(work_tree, limit)
  local result = vim.system({
    'git', 'log', '--pretty=format:%h%x09%s', '-n', tostring(limit), 'HEAD', '--',
  }, { cwd = work_tree, text = true }):wait()
  if result.code ~= 0 then return {} end

  local commits = {}
  for line in (result.stdout or ''):gmatch('[^\r\n]+') do
    table.insert(commits, (line:gsub('\t', ' ', 1)))
  end
  return commits
end

local function append_custom_status_lines(lines, custom_lines)
  local last_content = #lines
  while last_content > 0 and lines[last_content] == '' do last_content = last_content - 1 end
  local result = {}
  for i = 1, last_content do table.insert(result, lines[i]) end
  vim.list_extend(result, custom_lines)
  for i = last_content + 1, #lines do table.insert(result, lines[i]) end
  return result
end

local function status_header_kind(line)
  if not line then return nil end
  if line:match('^Unpushed %[only%] %(%d+%)$') or line:match('^Commits %[latest 15%+%] %(%d+%)$') then
    return 'commit'
  end
  if line:match('^Pull requests %(') then return 'pull_request' end
  if line:match('^Hidden changes: %d+ files? %(Index flags%)$') then return 'index_flags_warning' end
  if line:match('^Index flags %[local%] %(%d+%) %[.+%]$') then return 'index_flags' end
  return nil
end

local function status_cursor_key(lines, row, bufnr)
  local line = lines[row] or ''
  local rendered_entry = bufnr and status_renderer.entry_at(bufnr, row) or nil
  if rendered_entry and not rendered_entry.header then return 'status_entry', rendered_entry.path end
  local flagged_entry = bufnr and index_flags.entry_from_line(index_flags_by_buf[bufnr], line) or nil
  if flagged_entry then return 'index_flag', flagged_entry.path end
  local header = status_header_kind(line)
  if header then return 'header', header end

  local number = pull_request_number_from_line(line)
  if number then return 'pull_request', tostring(number) end

  local stash = stash_ref_from_line(line)
  if stash then return 'stash', stash end

  local hash = line:match('^(%x%x%x%x%x%x%x+)%s')
  if hash then return 'commit', hash end

  local submodule = repository_health.submodule_path(line)
  if submodule then return 'submodule', submodule end

  local status, path = line:match('^([MADRCUT?!][MADRCUT?!]?) (.+)$')
  if status then
    local _, renamed_path = path:match('^(.+) %-> (.+)$')
    return 'status_entry', renamed_path or path
  end

  local section
  for i = row, 1, -1 do
    if lines[i]:match('^Worktrees') then
      section = 'worktree'
      break
    end
    if lines[i] == '' or lines[i]:match('^[A-Z][^/]-%s*[%[(]') then break end
  end
  if section == 'worktree' then
    local worktree_path = line:match('^(%S+)')
    if worktree_path then return section, worktree_path end
  end

  return 'line', line
end

local function capture_status_cursor(bufnr, winid)
  if not (winid and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr) then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(winid)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local key_type, key = status_cursor_key(lines, cursor[1], bufnr)
  local view
  pcall(function()
    view = vim.api.nvim_win_call(winid, vim.fn.winsaveview)
  end)
  return {
    key_type = key_type,
    key = key,
    row = cursor[1],
    col = cursor[2],
    screen_offset = view and math.max(cursor[1] - (view.topline or cursor[1]), 0) or 0,
    view = view,
    winid = winid,
  }
end

local function capture_status_cursors(bufnr)
  local anchors = {}
  local current_win = vim.api.nvim_get_current_win()
  local current_anchor = capture_status_cursor(bufnr, current_win)
  if current_anchor then table.insert(anchors, current_anchor) end
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if winid ~= current_win then
      local anchor = capture_status_cursor(bufnr, winid)
      if anchor then table.insert(anchors, anchor) end
    end
  end
  if #anchors > 0 then status_cursor_anchor_by_buf[bufnr] = anchors[1] end
  return anchors
end

local function capture_status_cursors_before_reload(bufnr)
  local saved_anchor = status_cursor_anchor_by_buf[bufnr]
  local anchors = capture_status_cursors(bufnr)
  if not saved_anchor then return anchors end

  for i, anchor in ipairs(anchors) do
    if anchor.winid == saved_anchor.winid then
      anchors[i] = saved_anchor
      return anchors
    end
  end
  return anchors
end

local function find_status_cursor_row(lines, anchor, bufnr)
  local best_row, best_distance
  for row = 1, #lines do
    local key_type, key = status_cursor_key(lines, row, bufnr)
    if key_type == anchor.key_type and key == anchor.key then
      local distance = math.abs(row - (anchor.row or row))
      if not best_distance or distance < best_distance then
        best_row, best_distance = row, distance
      end
    end
  end
  return best_row or math.min(math.max(anchor.row or 1, 1), math.max(#lines, 1))
end

local function restore_status_cursor(bufnr, anchor, target_win)
  if not anchor then return end
  local winid = target_win or anchor.winid
  if not (winid and vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr) then return end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local row = find_status_cursor_row(lines, anchor, bufnr)
  local line = lines[row] or ''
  pcall(function()
    vim.api.nvim_win_call(winid, function()
      local view = vim.deepcopy(anchor.view or vim.fn.winsaveview())
      view.lnum = row
      view.col = math.min(anchor.col or 0, #line)
      view.topline = math.max(row - (anchor.screen_offset or 0), 1)
      vim.fn.winrestview(view)
    end)
  end)
end

local function restore_status_cursors(bufnr, anchors)
  for _, anchor in ipairs(anchors or {}) do
    restore_status_cursor(bufnr, anchor)
  end
end

local function status_line_identity(lines, row)
  local line = lines[row] or ''
  if line:match('^Worktrees %(') then return 'header\0worktree' end
  if line:match('^Stashes %(') then return 'header\0stash' end
  local key_type, key = status_cursor_key(lines, row)
  return key_type .. '\0' .. key
end

local function matching_status_lines(old_lines, new_lines)
  local old_keys, new_keys = {}, {}
  for row = 1, #old_lines do old_keys[row] = status_line_identity(old_lines, row) end
  for row = 1, #new_lines do new_keys[row] = status_line_identity(new_lines, row) end

  -- Keep semantically identical rows in place and edit only the gaps between them.
  local lengths = { [0] = {} }
  for j = 0, #new_lines do lengths[0][j] = 0 end
  for i = 1, #old_lines do
    lengths[i] = { [0] = 0 }
    for j = 1, #new_lines do
      if old_keys[i] == new_keys[j] then
        lengths[i][j] = lengths[i - 1][j - 1] + 1
      else
        lengths[i][j] = math.max(lengths[i - 1][j], lengths[i][j - 1])
      end
    end
  end

  local reversed = {}
  local i, j = #old_lines, #new_lines
  while i > 0 and j > 0 do
    if old_keys[i] == new_keys[j] then
      table.insert(reversed, { old = i, new = j })
      i, j = i - 1, j - 1
    elseif lengths[i - 1][j] >= lengths[i][j - 1] then
      i = i - 1
    else
      j = j - 1
    end
  end

  local matches = { { old = 0, new = 0 } }
  for index = #reversed, 1, -1 do table.insert(matches, reversed[index]) end
  table.insert(matches, { old = #old_lines + 1, new = #new_lines + 1 })
  return matches
end

local function reconcile_status_block(bufnr, start_row, end_row, new_lines)
  local start_idx = start_row - 1
  local old_lines = vim.api.nvim_buf_get_lines(bufnr, start_idx, end_row, false)
  local matches = matching_status_lines(old_lines, new_lines)

  for index = #matches, 2, -1 do
    local current = matches[index]
    local previous = matches[index - 1]

    if current.old <= #old_lines and old_lines[current.old] ~= new_lines[current.new] then
      vim.api.nvim_buf_set_lines(
        bufnr,
        start_idx + current.old - 1,
        start_idx + current.old,
        false,
        { new_lines[current.new] }
      )
    end

    local replacement = {}
    for new_row = previous.new + 1, current.new - 1 do
      table.insert(replacement, new_lines[new_row])
    end
    if current.old - previous.old > 1 or #replacement > 0 then
      vim.api.nvim_buf_set_lines(
        bufnr,
        start_idx + previous.old,
        start_idx + current.old - 1,
        false,
        replacement
      )
    end
  end
end

local function refresh_status_sections(bufnr, ns_worktree, ns_stash, ns_pr)
  if not utils.is_valid_buf(bufnr) then return end
  local work_tree = utils.get_buf_work_tree(bufnr)
  if not work_tree then return end
  local cursor_anchors = pending_status_cursor_anchors_by_buf[bufnr]
  pending_status_cursor_anchors_by_buf[bufnr] = nil
  if not cursor_anchors then cursor_anchors = capture_status_cursors(bufnr) end

  local native_lines, snapshot_err = status_renderer.snapshot(bufnr, work_tree)
  if not native_lines then
    vim.notify_once('Failed to render Git status: ' .. snapshot_err, vim.log.levels.ERROR)
    return
  end

  local worktree_summary = worktree.get_summary(work_tree)
  local stash_list = utils.get_stash_list(work_tree)

  local commit_scope = commit_scope_by_buf[bufnr] or 'unpushed'
  local pull_requests = pull_requests_by_buf[bufnr]
  local health = repository_health.inspect(work_tree)
  repository_health_by_buf[bufnr] = health
  local flag_state = index_flags.inspect(work_tree)
  index_flags_by_buf[bufnr] = flag_state
  local warning = index_flags.warning_line(flag_state)
  if warning then
    local warning_row = #native_lines + 1
    for row, line in ipairs(native_lines) do
      if line == 'Help: g?' then warning_row = row + 1; break end
    end
    table.insert(native_lines, warning_row, warning)
    status_renderer.shift_entries(bufnr, warning_row, 1)
  end

  local function build_final_lines(commit_lines)
    local final_lines = {}
    table.insert(final_lines, '')
    local commit_header = commit_scope == 'recent'
      and ('Commits [latest 15+] (%d)'):format(#commit_lines)
      or ('Unpushed [only] (%d)'):format(#commit_lines)
    table.insert(final_lines, commit_header)
    for _, l in ipairs(commit_lines) do table.insert(final_lines, l) end
    vim.list_extend(final_lines, repository_health.status_lines(health))

    if worktree_summary and #worktree_summary > 0 then
      table.insert(final_lines, '')
      for _, l in ipairs(worktree_summary) do table.insert(final_lines, l) end
    end
    if stash_list and #stash_list > 0 then
      table.insert(final_lines, '')
      table.insert(final_lines, 'Stashes (' .. #stash_list .. ')')
      for _, l in ipairs(stash_list) do table.insert(final_lines, l) end
    end
    if pull_requests then
      local scope = pull_request_scope_by_buf[bufnr] or 'branch'
      local scope_label = scope == 'all'
        and 'all'
        or ('branch: ' .. (pull_request_branch_by_buf[bufnr] or 'detached HEAD'))
      table.insert(final_lines, '')
      table.insert(final_lines, ('Pull requests (%d) [%s]'):format(#pull_requests, scope_label))
      for _, pr in ipairs(pull_requests) do
        local draft = pr.isDraft and ' [draft]' or ''
        local branch = pr.headRefName ~= '' and ('  ' .. pr.headRefName) or ''
        table.insert(final_lines, ('#%d%s %s%s'):format(pr.number, draft, pr.title, branch))
      end
    end
    vim.list_extend(final_lines, index_flags.status_lines(
      flag_state,
      index_flags_expanded_by_buf[bufnr] == true
    ))
    return final_lines
  end

  utils.with_buf_modifiable(bufnr, function()
    unpushed_commits_by_buf[bufnr] = status_renderer.unpushed_commits(bufnr)
    local commit_lines = unpushed_commits_by_buf[bufnr]
    if commit_scope == 'recent' and #commit_lines < 15 then
      commit_lines = recent_commit_lines(work_tree, 15)
    end
    local desired_lines = append_custom_status_lines(native_lines, build_final_lines(commit_lines))
    reconcile_status_block(bufnr, 1, vim.api.nvim_buf_line_count(bufnr), desired_lines)

    -- Update extmarks based on the new buffer contents
    vim.api.nvim_buf_clear_namespace(bufnr, ns_worktree, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, ns_stash, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, ns_pr, 0, -1)

    local lines_after = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local in_worktree, in_stash, in_pr = false, false, false
    local current_wt_abs = vim.fn.fnamemodify(work_tree, ':p'):gsub('/+$', '')

    for i, l in ipairs(lines_after) do
      if l:match('^Worktrees') then
        vim.api.nvim_buf_set_extmark(bufnr, ns_worktree, i - 1, 0, { end_col = #l, hl_group = 'RainbowDelimiterViolet' })
        in_worktree, in_stash, in_pr = true, false, false
      elseif l:match('^Stashes') then
        vim.api.nvim_buf_set_extmark(bufnr, ns_stash, i - 1, 0, { end_col = #l, hl_group = 'GitSignsChange' })
        in_worktree, in_stash, in_pr = false, true, false
      elseif l:match('^Pull requests') then
        vim.api.nvim_buf_set_extmark(bufnr, ns_pr, i - 1, 0, { end_col = #l, hl_group = 'GitSignsAdd' })
        in_worktree, in_stash, in_pr = false, false, true
      elseif in_worktree then
        -- 形式: [path]  [branch]  [head] [sync_icon]
        local p_part = l:match('^(%S+)')
        if p_part then
          local s_p, e_p = l:find(p_part, 1, true)
          local path_hl = (vim.fn.fnamemodify(p_part, ':p'):gsub('/+$', '') == current_wt_abs) and 'DiagnosticOk' or 'Directory'
          vim.api.nvim_buf_set_extmark(bufnr, ns_worktree, i - 1, s_p - 1, { end_col = e_p, hl_group = path_hl })

          -- ブランチ
          local br_part = l:sub(e_p + 1):match('%s+(%S+)')
          local s_b, e_b
          if br_part then
            s_b, e_b = l:find(br_part, e_p + 1, true)
            vim.api.nvim_buf_set_extmark(bufnr, ns_worktree, i - 1, s_b - 1, { end_col = e_b, hl_group = 'Type' })
          end

          -- ハッシュ
          local hd_part = l:sub((e_b or e_p) + 1):match('%s+(%S+)')
          local s_h, e_h
          if hd_part then
            s_h, e_h = l:find(hd_part, (e_b or e_p) + 1, true)
            vim.api.nvim_buf_set_extmark(bufnr, ns_worktree, i - 1, s_h - 1, { end_col = e_h, hl_group = 'Comment' })
          end

          -- 同期アイコン (一番右)
          local icon_str = '󰚰'
          local icon_pos, icon_end = l:find(icon_str, (e_h or e_b or e_p), true)
          if icon_pos then
            vim.api.nvim_buf_set_extmark(bufnr, ns_worktree, i - 1, icon_pos - 1, { end_col = icon_end, hl_group = 'DiagnosticOk' })
          end
        else
          if l ~= '' then in_worktree = false end
        end

      elseif in_stash then
        local ref = stash_ref_from_line(l)
        if ref then
          local s, e = l:find(ref, 1, true)
          -- stash@{n} の部分を強調
          if s and e then
            vim.api.nvim_buf_set_extmark(bufnr, ns_stash, i - 1, s - 1, { end_col = e, hl_group = 'GitSignsAdd' })
            -- それ以降（メッセージ部分）をコメント色に
            vim.api.nvim_buf_set_extmark(bufnr, ns_stash, i - 1, e, { end_col = #l, hl_group = 'Comment' })
          end
        else in_stash = false end
      elseif in_pr then
        local number = pull_request_number_from_line(l)
        if number then
          local number_end = #tostring(number) + 1
          vim.api.nvim_buf_set_extmark(bufnr, ns_pr, i - 1, 0, { end_col = number_end, hl_group = 'Identifier' })
          local draft_start, draft_end = l:find('%[draft%]')
          if draft_start then
            vim.api.nvim_buf_set_extmark(bufnr, ns_pr, i - 1, draft_start - 1, { end_col = draft_end, hl_group = 'Comment' })
          end
        else in_pr = false end
      end
    end
  end, 5)
  restore_status_cursors(bufnr, cursor_anchors)
end

local function get_stash_ref_at_cursor(bufnr)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
  return stash_ref_from_line(line)
end

local function is_cursor_in_stash_area()
  local line = vim.api.nvim_get_current_line()
  if line:match('^%s*stash@%{%d+%}') then return true end
  local s = line:find('Stashes')
  return s ~= nil and (vim.api.nvim_win_get_cursor(0)[2] + 1) >= s
end

local function is_cursor_in_worktree_area()
  local line = vim.api.nvim_get_current_line()
  return line:match('^Worktrees') or line:match('^[~/]')
end

local function is_cursor_in_pull_request_area()
  return pull_request_number_from_line(vim.api.nvim_get_current_line()) ~= nil
end

local function is_cursor_on_pull_request_header()
  return vim.api.nvim_get_current_line():match('^Pull requests %(') ~= nil
end

local function is_cursor_on_commit_header()
  local line = vim.api.nvim_get_current_line()
  return line:match('^Unpushed %[only%] %(%d+%)$') ~= nil
    or line:match('^Commits %[latest 15%+%] %(%d+%)$') ~= nil
end

local function submodule_path_at_cursor()
  return repository_health.submodule_path(vim.api.nvim_get_current_line())
end

local function get_worktree_path_at_cursor()
  local line = vim.api.nvim_get_current_line()
  return line:match('^(%S+)')
end

local function status_entry_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local entry = status_renderer.entry_at(bufnr, row)
  if entry and not entry.header then return entry.status, entry.path, entry end

  local line = vim.api.nvim_get_current_line()
  local status, path = line:match('^([MADRCUT?!][MADRCUT?!]?) (.+)$')
  if not status then return nil, nil, nil end
  local _, new_path = path:match('^(.+) %-> (.+)$')
  return status, new_path or path, nil
end

local function worktree_relative_abs_path(path)
  return utils.worktree_relative_abs_path(utils.get_buf_work_tree(vim.api.nvim_get_current_buf()), path)
end

local function delete_untracked_directory_at_cursor()
  local status, path = status_entry_at_cursor()
  if status ~= '?' and status ~= '??' then return false end

  local abs = worktree_relative_abs_path(path)
  if not abs or vim.fn.isdirectory(abs) ~= 1 then return false end

  if vim.fn.delete(abs, 'rf') ~= 0 then
    vim.notify('Failed to delete untracked directory: ' .. path, vim.log.levels.ERROR)
    return true
  end

  vim.notify('Deleted untracked directory: ' .. path, vim.log.levels.INFO)
  return true
end

local function preferred_target_window(status_win)
  local function is_regular_window(winid)
    if not (winid and winid ~= 0 and vim.api.nvim_win_is_valid(winid)) then return false end
    local config = vim.api.nvim_win_get_config(winid)
    return not config.external and (config.relative == nil or config.relative == '')
  end

  local alt = vim.fn.win_getid(vim.fn.winnr('#'))
  if alt ~= status_win and is_regular_window(alt) then
    local alt_buf = vim.api.nvim_win_get_buf(alt)
    if not is_status_buffer(alt_buf) and vim.bo[alt_buf].filetype ~= 'fugitive' then
      return alt
    end
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= status_win and is_regular_window(win) then
      local win_buf = vim.api.nvim_win_get_buf(win)
      if not is_status_buffer(win_buf) and vim.bo[win_buf].filetype ~= 'fugitive' then
        return win
      end
    end
  end
  return nil
end

local function status_file_line_at_cursor(bufnr, row)
  local entry = status_renderer.entry_at(bufnr, row)
  if not entry or entry.header then return nil end
  local direct_row = status_renderer.entry_row(bufnr, row)
  if not direct_row or row <= direct_row then return nil end

  local lines = vim.api.nvim_buf_get_lines(bufnr, direct_row, row, false)
  local hunk_index, target_line
  for index = #lines, 1, -1 do
    local new_start = lines[index]:match('^@@ %-%d+,?%d* %+(%d+)')
    if new_start then
      hunk_index, target_line = index, tonumber(new_start)
      break
    end
    if lines[index]:match('^@@ new file:') then
      hunk_index, target_line = index, 1
      break
    end
  end
  if not hunk_index then return nil end

  local offset = 0
  for index = hunk_index + 1, #lines do
    local line = lines[index]
    if not line:match('^%-') and not line:match('^\\ No newline') then offset = offset + 1 end
  end
  return math.max(target_line + offset - 1, 1)
end

local function status_edit_command_at_cursor(bufnr)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local entry = status_renderer.entry_at(bufnr, row)
  if entry and not entry.header then
    if entry.section == 'staged' then
      return 'Gedit :0:' .. vim.fn.fnameescape(entry.path), nil, status_file_line_at_cursor(bufnr, row)
    end
    local work_tree = utils.get_buf_work_tree(bufnr)
    if not work_tree then return nil, 'Git work tree not found' end
    local absolute = vim.fs.joinpath(work_tree, entry.path)
    return 'edit ' .. vim.fn.fnameescape(absolute), nil, status_file_line_at_cursor(bufnr, row)
  end

  local hash = vim.api.nvim_get_current_line():match('^(%x%x%x%x%x%x%x+)%s')
  if hash then return 'Gedit ' .. hash end
  return nil, 'No file or commit found at cursor'
end

local function target_window_or_split(status_win)
  local target_win = preferred_target_window(status_win)
  if target_win and vim.api.nvim_win_is_valid(target_win) and target_win ~= status_win then
    return target_win, false
  end

  vim.api.nvim_win_call(status_win, function()
    vim.cmd('belowright split')
    target_win = vim.api.nvim_get_current_win()
  end)
  return target_win, true
end

local function open_entry_from_status(bufnr, close_status)
  if not utils.is_valid_buf(bufnr) then return end

  local status_win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(status_win) ~= bufnr then
    status_win = vim.fn.bufwinid(bufnr)
  end
  if status_win == -1 or not vim.api.nvim_win_is_valid(status_win) then
    vim.notify('Status window not found', vim.log.levels.WARN)
    return
  end

  local cmd, command_err, target_line = vim.api.nvim_win_call(status_win, function()
    return status_edit_command_at_cursor(bufnr)
  end)
  if not cmd then
    vim.notify(command_err, vim.log.levels.WARN)
    return
  end

  local target_win, created_target = target_window_or_split(status_win)
  if not (target_win and vim.api.nvim_win_is_valid(target_win) and target_win ~= status_win) then
    vim.notify('Target window not found', vim.log.levels.WARN)
    return
  end

  local git_dir = vim.b[bufnr].git_dir
  local ok, exec_err = pcall(vim.api.nvim_win_call, target_win, function()
    local had_fugitive_event = vim.fn.exists('g:fugitive_event') == 1
    local previous_fugitive_event = vim.g.fugitive_event
    vim.g.fugitive_event = git_dir
    local executed, command_exec_err = pcall(vim.cmd, cmd)
    if had_fugitive_event then
      vim.g.fugitive_event = previous_fugitive_event
    else
      vim.g.fugitive_event = nil
    end
    if not executed then error(command_exec_err) end
    if target_line then
      local line_count = vim.api.nvim_buf_line_count(0)
      vim.api.nvim_win_set_cursor(0, { math.min(math.max(target_line, 1), line_count), 0 })
      vim.cmd('normal! zz')
    end
  end)
  if not ok then
    if created_target and vim.api.nvim_win_is_valid(target_win) then
      pcall(vim.api.nvim_win_close, target_win, false)
    end
    vim.notify(tostring(exec_err), vim.log.levels.WARN)
    return
  end

  if close_status then pcall(vim.api.nvim_win_close, status_win, false) end
  if vim.api.nvim_win_is_valid(target_win) then
    vim.api.nvim_set_current_win(target_win)
  end
end

local function open_index_flag_file(bufnr, path)
  local work_tree = utils.get_buf_work_tree(bufnr)
  if not work_tree then return false end
  local absolute = vim.fs.joinpath(work_tree, path)
  if vim.fn.filereadable(absolute) ~= 1 and vim.fn.isdirectory(absolute) ~= 1 then
    vim.notify('Flagged path is missing: ' .. path, vim.log.levels.WARN)
    return false
  end
  local status_win = vim.fn.bufwinid(bufnr)
  if status_win == -1 then return false end
  local target_win = target_window_or_split(status_win)
  if not target_win then return false end
  vim.api.nvim_win_call(target_win, function()
    vim.cmd('edit ' .. vim.fn.fnameescape(absolute))
  end)
  vim.api.nvim_set_current_win(target_win)
  return true
end

local function open_oil_in_target(bufnr, path)
  local status_win = vim.fn.bufwinid(bufnr)
  if status_win == -1 or not vim.api.nvim_win_is_valid(status_win) then return false end
  local target_win, created_target = target_window_or_split(status_win)
  if not (target_win and vim.api.nvim_win_is_valid(target_win)) then return false end

  local ok = pcall(function()
    vim.api.nvim_win_call(target_win, function()
      vim.cmd('Oil ' .. vim.fn.fnameescape(path))
    end)
  end)
  if not ok and created_target and vim.api.nvim_win_is_valid(target_win) then
    pcall(vim.api.nvim_win_close, target_win, false)
  end
  if ok and vim.api.nvim_win_is_valid(target_win) then vim.api.nvim_set_current_win(target_win) end
  return ok
end

local diff_buffer_serial = 0

local function show_diff_side(winid, side, path, label)
  local bufnr = vim.api.nvim_create_buf(false, true)
  diff_buffer_serial = diff_buffer_serial + 1
  vim.api.nvim_buf_set_name(bufnr, ('git-diff://%d/%s/%s'):format(diff_buffer_serial, label, path))
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, #side > 0 and side or { '' })
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
  local filetype = vim.filetype.match({ filename = path })
  if filetype then vim.bo[bufnr].filetype = filetype end
  vim.api.nvim_win_set_buf(winid, bufnr)
  vim.api.nvim_win_call(winid, function() vim.cmd('diffthis') end)
  return bufnr
end

local function open_status_diff(bufnr, target_line, layout)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local sides, err = status_renderer.diff_sides(bufnr, row)
  if not sides then vim.notify(err, vim.log.levels.WARN); return false end

  vim.cmd('tabnew')
  local placeholder = vim.api.nvim_get_current_buf()
  local left_win = vim.api.nvim_get_current_win()
  show_diff_side(left_win, sides.left, sides.path, sides.left_label)
  if vim.api.nvim_buf_is_valid(placeholder) and vim.api.nvim_buf_get_name(placeholder) == '' then
    pcall(vim.api.nvim_buf_delete, placeholder, { force = true })
  end
  vim.cmd(layout == 'horizontal' and 'rightbelow split' or 'rightbelow vsplit')
  local right_win = vim.api.nvim_get_current_win()
  local right_buf = show_diff_side(right_win, sides.right, sides.path, sides.right_label)
  if target_line then
    local line_count = vim.api.nvim_buf_line_count(right_buf)
    pcall(vim.api.nvim_win_set_cursor, right_win, { math.min(math.max(target_line, 1), line_count), 0 })
    vim.api.nvim_win_call(right_win, function() vim.cmd('normal! zz') end)
  end
  return true
end

local function open_index_flag_diff(bufnr, entry, layout)
  local work_tree = utils.get_buf_work_tree(bufnr)
  if not work_tree then return false end
  local sides, err = index_flags.diff_sides(work_tree, entry)
  if not sides then vim.notify(err, vim.log.levels.WARN); return false end

  vim.cmd('tabnew')
  local placeholder = vim.api.nvim_get_current_buf()
  local left_win = vim.api.nvim_get_current_win()
  show_diff_side(left_win, sides.left, sides.path, sides.left_label)
  if vim.api.nvim_buf_is_valid(placeholder) and vim.api.nvim_buf_get_name(placeholder) == '' then
    pcall(vim.api.nvim_buf_delete, placeholder, { force = true })
  end
  vim.cmd(layout == 'horizontal' and 'rightbelow split' or 'rightbelow vsplit')
  show_diff_side(vim.api.nvim_get_current_win(), sides.right, sides.path, sides.right_label)
  return true
end

local function open_conflict_diff(bufnr)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local sides, err = status_renderer.conflict_sides(bufnr, row)
  if not sides then vim.notify(err, vim.log.levels.WARN); return false end

  vim.cmd('tabnew')
  local placeholder = vim.api.nvim_get_current_buf()
  local first_win = vim.api.nvim_get_current_win()
  show_diff_side(first_win, sides[1].lines, sides.path, sides[1].label)
  if vim.api.nvim_buf_is_valid(placeholder) and vim.api.nvim_buf_get_name(placeholder) == '' then
    pcall(vim.api.nvim_buf_delete, placeholder, { force = true })
  end
  for index = 2, #sides do
    vim.cmd('rightbelow vsplit')
    show_diff_side(vim.api.nvim_get_current_win(), sides[index].lines, sides.path, sides[index].label)
  end
  vim.cmd('wincmd =')
  return true
end

function M.setup(group)
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'fugitivestatus',
    callback = function(ev)
      local b = ev.buf
      if not utils.get_buf_work_tree(b) then return end
      vim.opt_local.number, vim.opt_local.relativenumber = false, false
      configure_status_window(vim.api.nvim_get_current_win())
      local ns_stash = vim.api.nvim_create_namespace('fugitive_status_stash')
      local ns_worktree = vim.api.nvim_create_namespace('fugitive_status_worktree')
      local ns_pr = vim.api.nvim_create_namespace('fugitive_status_pull_requests')
      local ns_id = vim.api.nvim_create_namespace('fugitive_status_icons')
      local pr_fetching, pr_fetch_pending = false, false
      local apply_icons
      pull_request_scope_by_buf[b] = pull_request_scope_by_buf[b] or 'branch'
      commit_scope_by_buf[b] = commit_scope_by_buf[b] or 'unpushed'

      local function refresh()
        refresh_status_sections(b, ns_worktree, ns_stash, ns_pr)
        if apply_icons then apply_icons() end
      end

      local fetch_pull_requests
      fetch_pull_requests = function()
        if not utils.is_valid_buf(b) then return end
        if pr_fetching then
          pr_fetch_pending = true
          return
        end

        local work_tree = utils.get_buf_work_tree(b)
        if not work_tree or vim.fn.executable('gh') ~= 1 then return end

        pr_fetching = true
        local requested_scope = pull_request_scope_by_buf[b] or 'branch'
        local branch = nil
        if requested_scope == 'branch' then
          local branch_result = vim.system(
            { 'git', 'branch', '--show-current' },
            { cwd = work_tree, text = true }
          ):wait()
          if branch_result.code == 0 then
            branch = vim.trim(branch_result.stdout or '')
          end
          if not branch or branch == '' then
            pull_requests_by_buf[b] = {}
            pull_request_branch_by_buf[b] = nil
            pr_fetching = false
            refresh()
            return
          end
        end

        local args = {
          'gh', 'pr', 'list', '--state', 'open',
          '--limit', '100',
          '--json', 'number,title,headRefName,isDraft,url',
        }
        if branch then
          vim.list_extend(args, { '--head', branch })
        end

        vim.system(args, { cwd = work_tree, text = true }, function(result)
          vim.schedule(function()
            pr_fetching = false
            if not utils.is_valid_buf(b) then return end

            if result.code == 0 and pull_request_scope_by_buf[b] == requested_scope then
              local ok, decoded = pcall(vim.json.decode, result.stdout or '')
              local pull_requests = {}
              if ok and type(decoded) == 'table' then
                for _, pr in ipairs(decoded) do
                  local number = tonumber(pr.number)
                  if number then
                    local url = type(pr.url) == 'string' and pr.url or ''
                    table.insert(pull_requests, {
                      number = number,
                      title = tostring(pr.title or ''):gsub('[\r\n]', ' '),
                      headRefName = tostring(pr.headRefName or ''):gsub('[\r\n]', ' '),
                      isDraft = pr.isDraft == true,
                      repository = url:match('^https?://[^/]+/([^/]+/[^/]+)/pull/%d+'),
                    })
                  end
                end
              end
              pull_requests_by_buf[b] = pull_requests
              pull_request_branch_by_buf[b] = branch
              refresh()
            end

            if pr_fetch_pending then
              pr_fetch_pending = false
              fetch_pull_requests()
            end
          end)
        end)
      end

      local function reload_status()
        if not utils.is_valid_buf(b) then return end
        local anchors = capture_status_cursors_before_reload(b)
        if #anchors > 0 then pending_status_cursor_anchors_by_buf[b] = anchors end
        vim.schedule(refresh)
        fetch_pull_requests()
      end

      local function notify_repo_changed()
        utils.fire_fugitive_changed({ bufnr = b })
      end

      status_renderer.take_ownership(b)
      pending_status_cursor_anchors_by_buf[b] = nil
      refresh()
      fetch_pull_requests()

      vim.api.nvim_create_autocmd('BufWipeout', {
        group = group,
        buffer = b,
        once = true,
        callback = function()
          pull_requests_by_buf[b] = nil
          pull_request_scope_by_buf[b] = nil
          pull_request_branch_by_buf[b] = nil
          commit_scope_by_buf[b] = nil
          unpushed_commits_by_buf[b] = nil
          status_cursor_anchor_by_buf[b] = nil
          pending_status_cursor_anchors_by_buf[b] = nil
          repository_health_by_buf[b] = nil
          index_flags_by_buf[b] = nil
          index_flags_expanded_by_buf[b] = nil
          status_renderer.cleanup(b)
        end,
      })

      vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'BufWinLeave', 'WinLeave' }, {
        group = group,
        buffer = b,
        callback = function()
          local anchor = capture_status_cursor(b, vim.api.nvim_get_current_win())
          if anchor then status_cursor_anchor_by_buf[b] = anchor end
        end,
      })

      vim.api.nvim_create_autocmd({ 'BufWinEnter', 'WinEnter' }, {
        group = group,
        buffer = b,
        callback = function()
          if not status_renderer.is_owned(b) then return end
          local winid = vim.api.nvim_get_current_win()
          local anchor = status_cursor_anchor_by_buf[b]
          if anchor then
            vim.schedule(function()
              restore_status_cursor(b, anchor, winid)
            end)
          end
        end,
      })

      local function set_commit_scope(scope)
        if scope == commit_scope_by_buf[b] then return end
        commit_scope_by_buf[b] = scope
        refresh()
      end

      local function toggle_commit_scope()
        set_commit_scope(commit_scope_by_buf[b] == 'recent' and 'unpushed' or 'recent')
      end

      local function select_commit_scope()
        local choices = {
          { scope = 'unpushed', label = 'Unpushed only' },
          { scope = 'recent', label = 'Latest 15 (keep all unpushed)' },
        }
        vim.ui.select(choices, {
          prompt = 'Commit scope:',
          format_item = function(item)
            local selected = item.scope == commit_scope_by_buf[b] and ' (current)' or ''
            return item.label .. selected
          end,
        }, function(choice)
          if choice then set_commit_scope(choice.scope) end
        end)
      end

      local function set_pull_request_scope(scope)
        if scope == pull_request_scope_by_buf[b] then return end
        pull_request_scope_by_buf[b] = scope
        pull_request_branch_by_buf[b] = nil
        refresh()
        fetch_pull_requests()
      end

      local function toggle_pull_request_scope()
        set_pull_request_scope(pull_request_scope_by_buf[b] == 'all' and 'branch' or 'all')
      end

      local function select_pull_request_scope()
        local choices = {
          { scope = 'branch', label = 'Current branch' },
          { scope = 'all', label = 'All open pull requests' },
        }
        vim.ui.select(choices, {
          prompt = 'Pull request scope:',
          format_item = function(item)
            local selected = item.scope == pull_request_scope_by_buf[b] and ' (current)' or ''
            return item.label .. selected
          end,
        }, function(choice)
          if choice then set_pull_request_scope(choice.scope) end
        end)
      end

      local bufgroupt = vim.api.nvim_create_augroup('FugitiveStatusRefresh' .. b, { clear = true })
      utils.setup_repo_refresh(bufgroupt, b, function()
        reload_status()
      end, { visible_only = true })

      apply_icons = function()
        if not utils.is_valid_buf(b) then return end
        vim.api.nvim_buf_clear_namespace(b, ns_id, 0, -1)
        local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
        local unpushed_hashes = commit_highlight.hash_set(unpushed_commits_by_buf[b])
        local in_unpulled = false
        for idx, line in ipairs(lines) do
          if line:match('^Unpulled ') then
            in_unpulled = true
          elseif in_unpulled and not line:match('^%x%x%x%x%x%x%x+%s') then
            in_unpulled = false
          end

          if line:match('^Staged') then
            vim.api.nvim_buf_set_extmark(b, ns_id, idx - 1, 0, { end_col = 6, hl_group = 'GitSignsAdd' })
          elseif line:match('^Bisecting') then
            vim.api.nvim_buf_set_extmark(b, ns_id, idx - 1, 0, { end_col = #line, hl_group = 'DiagnosticWarn' })
          elseif line:match('^Good:') then
            vim.api.nvim_buf_set_extmark(b, ns_id, idx - 1, 0, { end_col = #line, hl_group = 'GitSignsAdd' })
          elseif line:match('^Bad:') then
            vim.api.nvim_buf_set_extmark(b, ns_id, idx - 1, 0, { end_col = #line, hl_group = 'GitSignsDelete' })
          elseif line:match('^Bisect keys:') or line:match('^Start:') then
            vim.api.nvim_buf_set_extmark(b, ns_id, idx - 1, 0, { end_col = #line, hl_group = 'Comment' })
          elseif line:match(' in progress') then
            vim.api.nvim_buf_set_extmark(b, ns_id, idx - 1, 0, { end_col = #line, hl_group = 'DiagnosticWarn' })
          elseif line:match('^Operation keys:') then
            vim.api.nvim_buf_set_extmark(b, ns_id, idx - 1, 0, { end_col = #line, hl_group = 'Comment' })
          elseif line == 'Repository health' or line:match('^Submodules %(') then
            vim.api.nvim_buf_set_extmark(b, ns_id, idx - 1, 0, { end_col = #line, hl_group = 'DiagnosticInfo' })
          elseif line:match('^Submodule ') then
            local health_group = line:find('gone', 1, true) and 'DiagnosticWarn'
              or (line:find('dirty', 1, true) and 'GitSignsChange' or 'Directory')
            vim.api.nvim_buf_set_extmark(b, ns_id, idx - 1, 0, { end_col = #line, hl_group = health_group })
          elseif line:match('^Upstream:.*%[gone%]') or line == 'HEAD: detached' then
            vim.api.nvim_buf_set_extmark(b, ns_id, idx - 1, 0, { end_col = #line, hl_group = 'DiagnosticWarn' })
          elseif line:match('^Hidden changes: %d+ files? %(Index flags%)$') then
            vim.api.nvim_buf_set_extmark(b, ns_id, idx - 1, 0, { end_col = #line, hl_group = 'DiagnosticWarn' })
          elseif line:match('^Index flags %[local%]') then
            vim.api.nvim_buf_set_extmark(b, ns_id, idx - 1, 0, { end_col = #line, hl_group = 'Comment' })
          elseif line:match('^  skip%s') or line:match('^  assume%s') then
            local flag_group = line:match('%[missing%]') and 'DiagnosticError'
              or (line:match('%[modified%]') and 'DiagnosticWarn' or 'Comment')
            vim.api.nvim_buf_set_extmark(b, ns_id, idx - 1, 0, { end_col = #line, hl_group = flag_group })
          elseif line:match('^Unpulled') then
            vim.api.nvim_buf_set_extmark(b, ns_id, idx - 1, 0, { end_col = 8, hl_group = 'GitSignsChange' })
          elseif line:match('^Untracked') then
            vim.api.nvim_buf_set_extmark(b, ns_id, idx - 1, 0, { end_col = 9, hl_group = 'GitSignsDelete' })
          end

          local commit_hash = line:match('^(%x%x%x%x%x%x%x+)%s')
          if commit_hash then
            local state = in_unpulled and 'unpulled'
              or (commit_scope_by_buf[b] == 'recent' and unpushed_hashes[commit_hash] and 'unpushed')
              or 'default'
            vim.api.nvim_buf_set_extmark(b, ns_id, idx - 1, 0, {
              end_col = #commit_hash,
              hl_group = commit_highlight.group(state),
            })
          end

          local filepath = line:match('^[MADRCUT?!][MADRCUT?!]? (.+)$')
          if filepath then
            local status = line:sub(1, 1)
            if status == 'A' then vim.api.nvim_buf_set_extmark(b, ns_id, idx - 1, 0, { end_col = 1, hl_group = 'GitSignsAdd' })
            elseif status == 'D' then vim.api.nvim_buf_set_extmark(b, ns_id, idx - 1, 0, { end_col = 1, hl_group = 'GitSignsDelete' }) end

            local icon, icon_hl = utils.get_devicon(filepath)
            local f_start = line:find(filepath, 1, true)
            if f_start then
              vim.api.nvim_buf_set_extmark(b, ns_id, idx - 1, f_start - 1, { end_col = f_start - 1 + #filepath, hl_group = icon_hl })
              vim.api.nvim_buf_set_extmark(b, ns_id, idx - 1, f_start - 1, { virt_text = { { icon .. ' ', icon_hl } }, virt_text_pos = 'inline' })
            end
          end
        end
        notes.apply_icons(b, utils.get_buf_work_tree(b), function(line)
          return line:match('^(%x%x%x%x%x%x%x+)%s')
        end)
      end
      apply_icons()

      local function perform_continue()
        local git_dir = vim.b[b].git_dir
        if not git_dir or git_dir == '' then return end
        if vim.fn.isdirectory(git_dir .. "/rebase-merge") == 1 or vim.fn.isdirectory(git_dir .. "/rebase-apply") == 1 then vim.cmd("Git rebase --continue")
        elseif vim.fn.filereadable(git_dir .. "/CHERRY_PICK_HEAD") == 1 then vim.cmd("Git cherry-pick --continue")
        elseif vim.fn.filereadable(git_dir .. "/MERGE_HEAD") == 1 then vim.cmd("Git merge --continue")
        elseif vim.fn.filereadable(git_dir .. "/REVERT_HEAD") == 1 then vim.cmd("Git revert --continue")
        else vim.notify("No operation in progress.", vim.log.levels.WARN) end
      end

      local function perform_skip()
        local git_dir = vim.b[b].git_dir
        if not git_dir or git_dir == '' then return end
        if vim.fn.isdirectory(git_dir .. "/rebase-merge") == 1 or vim.fn.isdirectory(git_dir .. "/rebase-apply") == 1 then vim.cmd("Git rebase --skip")
        elseif vim.fn.filereadable(git_dir .. "/CHERRY_PICK_HEAD") == 1 then vim.cmd("Git cherry-pick --skip")
        elseif vim.fn.filereadable(git_dir .. "/REVERT_HEAD") == 1 then vim.cmd("Git revert --skip")
        else vim.notify("Skip not applicable.", vim.log.levels.WARN) end
      end

      local function perform_abort()
        local git_dir = vim.b[b].git_dir
        if not git_dir or git_dir == '' then return end
        if vim.fn.isdirectory(git_dir .. "/rebase-merge") == 1 or vim.fn.isdirectory(git_dir .. "/rebase-apply") == 1 then vim.cmd("Git rebase --abort")
        elseif vim.fn.filereadable(git_dir .. "/CHERRY_PICK_HEAD") == 1 then vim.cmd("Git cherry-pick --abort")
        elseif vim.fn.filereadable(git_dir .. "/MERGE_HEAD") == 1 then vim.cmd("Git merge --abort")
        elseif vim.fn.filereadable(git_dir .. "/REVERT_HEAD") == 1 then vim.cmd("Git revert --abort")
        else vim.notify("No operation to abort.", vim.log.levels.WARN) end
      end

      local function status_git_prefix()
        local work_tree = utils.get_buf_work_tree(b)
        return work_tree and ('git -C ' .. vim.fn.shellescape(work_tree) .. ' ') or nil
      end

      local function rename_stash_at_cursor(r)
        local line = vim.api.nvim_get_current_line()
        local current_msg = line:match('^%s*stash@%{%d+%}:%s*(.*)') or ""
        vim.ui.input({ prompt = 'New name for ' .. r .. ': ', default = current_msg }, function(input)
          if not input or input == '' or input == current_msg then return end
          local git = status_git_prefix()
          if not git then
            vim.notify('Not in a git repository', vim.log.levels.WARN)
            return
          end
          local hash = vim.fn.trim(vim.fn.system(git .. 'rev-parse ' .. vim.fn.shellescape(r)))
          if vim.v.shell_error ~= 0 then return end
          vim.fn.system(git .. 'stash drop ' .. vim.fn.shellescape(r))
          vim.fn.system(git .. 'stash store -m ' .. vim.fn.shellescape(input) .. ' ' .. vim.fn.shellescape(hash))
          notify_repo_changed()
        end)
      end

      vim.keymap.set('n', 'rr', perform_continue, { buffer = b, silent = true, desc = "Continue" })
      vim.keymap.set('n', 'rs', perform_skip, { buffer = b, silent = true, desc = "Skip" })
      vim.keymap.set('n', 'ra', perform_abort, { buffer = b, silent = true, desc = "Abort" })

      local function bisect(action, args)
        local work_tree = utils.get_buf_work_tree(b)
        if not work_tree then
          vim.notify('Not in a Git repository', vim.log.levels.WARN)
          return
        end
        operation.bisect(work_tree, action, args, function(ok, message)
          if not utils.is_valid_buf(b) then return end
          if not ok then
            vim.notify(message, vim.log.levels.ERROR)
            return
          end
          local output_lines = vim.split(message, '\n', { plain = true, trimempty = true })
          local summary = output_lines[#output_lines] or message
          for _, line in ipairs(output_lines) do
            if line:match('is the first bad commit') then summary = line; break end
          end
          vim.notify(action == 'run' and message or summary, vim.log.levels.INFO)
          reload_status()
          notify_repo_changed()
        end)
      end

      vim.keymap.set('n', 'bs', function()
        local work_tree = utils.get_buf_work_tree(b)
        local current = work_tree and operation.inspect(work_tree) or nil
        if current and current.kind == 'bisect' then
          vim.notify('A bisect operation is already in progress', vim.log.levels.WARN)
          return
        end
        vim.ui.input({ prompt = 'Known bad revision: ', default = 'HEAD' }, function(bad)
          if not bad or vim.trim(bad) == '' then return end
          vim.ui.input({ prompt = 'Known good revision: ' }, function(good)
            if not good or vim.trim(good) == '' then return end
            bisect('start', { vim.trim(bad), vim.trim(good) })
          end)
        end)
      end, { buffer = b, nowait = true, silent = true, desc = 'Start Git bisect' })
      vim.keymap.set('n', 'bg', function() bisect('good') end,
        { buffer = b, nowait = true, silent = true, desc = 'Mark bisect commit good' })
      vim.keymap.set('n', 'bb', function() bisect('bad') end,
        { buffer = b, nowait = true, silent = true, desc = 'Mark bisect commit bad' })
      vim.keymap.set('n', 'bk', function() bisect('skip') end,
        { buffer = b, nowait = true, silent = true, desc = 'Skip bisect commit' })
      vim.keymap.set('n', 'br', function() bisect('reset') end,
        { buffer = b, nowait = true, silent = true, desc = 'Reset Git bisect' })
      vim.keymap.set('n', 'bx', function()
        vim.ui.input({ prompt = 'Bisect run command: ' }, function(command)
          if not command or vim.trim(command) == '' then return end
          bisect('run', { 'sh', '-c', command })
        end)
      end, { buffer = b, nowait = true, silent = true, desc = 'Run command through Git bisect' })
      vim.keymap.set('n', 'bv', function()
        local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
        local in_bisect = false
        for row, line in ipairs(lines) do
          if line:match('^Bisecting') then
            in_bisect = true
          elseif in_bisect and line:match('^%x%x%x%x%x%x%x+%s') then
            local winid = vim.fn.bufwinid(b)
            if winid ~= -1 then
              vim.api.nvim_win_set_cursor(winid, { row, 0 })
              open_entry_from_status(b, false)
            end
            return
          elseif in_bisect and line == '' then
            break
          end
        end
        vim.notify('No active bisect candidate', vim.log.levels.WARN)
      end, { buffer = b, nowait = true, silent = true, desc = 'View current bisect candidate' })

      local function health_command(args)
        local work_tree = utils.get_buf_work_tree(b)
        if not work_tree then return end
        repository_health.run(work_tree, args, function(ok, message)
          if not ok then vim.notify(message, vim.log.levels.ERROR); return end
          vim.notify(message, vim.log.levels.INFO)
          reload_status()
          notify_repo_changed()
        end)
      end

      local function current_submodule_args(args)
        local path = submodule_path_at_cursor()
        if path then vim.list_extend(args, { '--', path }) end
        return args
      end

      vim.keymap.set('n', 'mi', function()
        health_command(current_submodule_args({ 'submodule', 'update', '--init', '--recursive' }))
      end, { buffer = b, nowait = true, silent = true, desc = 'Initialize/update submodule' })
      vim.keymap.set('n', 'mu', function()
        health_command(current_submodule_args({ 'submodule', 'update', '--recursive' }))
      end, { buffer = b, nowait = true, silent = true, desc = 'Update submodule to recorded commit' })
      vim.keymap.set('n', 'ms', function()
        health_command(current_submodule_args({ 'submodule', 'sync', '--recursive' }))
      end, { buffer = b, nowait = true, silent = true, desc = 'Synchronize submodule URLs' })
      vim.keymap.set('n', 'mU', function()
        local state = repository_health_by_buf[b]
        local default = state and state.upstream and state.upstream.display or ''
        vim.ui.input({ prompt = 'Set upstream to: ', default = default }, function(target)
          if not target or vim.trim(target) == '' then return end
          health_command({ 'branch', '--set-upstream-to=' .. vim.trim(target) })
        end)
      end, { buffer = b, nowait = true, silent = true, desc = 'Set current branch upstream' })
      vim.keymap.set('n', 'cc', '<cmd>Git commit<CR>',
        { buffer = b, nowait = true, silent = true, desc = 'Commit' })
      vim.keymap.set('n', 'c<CR>', '<cmd>Git commit<CR>',
        { buffer = b, nowait = true, silent = true, desc = 'Commit' })
      vim.keymap.set('n', 'ca', '<cmd>Git commit --amend<CR>',
        { buffer = b, nowait = true, silent = true, desc = 'Amend commit' })
      vim.keymap.set('n', 'ce', '<cmd>Git commit --amend --no-edit<CR>',
        { buffer = b, nowait = true, silent = true, desc = 'Amend without editing message' })

      local function change_index(action, first_row, last_row)
        local row = vim.api.nvim_win_get_cursor(0)[1]
        local changed, err
        if first_row and last_row then
          changed, err = status_renderer.change_index_range(b, first_row, last_row, action)
        else
          changed, err = status_renderer.change_index(b, row, action)
        end
        if not changed then
          vim.notify(err, vim.log.levels.WARN)
          return
        end
        reload_status()
        notify_repo_changed()
      end

      vim.keymap.set('n', '-', function() change_index('toggle') end,
        { buffer = b, nowait = true, silent = true, desc = 'Stage/unstage entry' })
      vim.keymap.set('n', 's', function() change_index('toggle') end,
        { buffer = b, nowait = true, silent = true, desc = 'Stage/unstage entry' })
      vim.keymap.set('n', 'u', function() change_index('unstage') end,
        { buffer = b, nowait = true, silent = true, desc = 'Unstage entry' })
      for key, action in pairs({ ['-'] = 'toggle', s = 'toggle', u = 'unstage' }) do
        local selected_action = action
        vim.keymap.set('x', key, function()
          local first_row = math.min(vim.fn.line('v'), vim.fn.line('.'))
          local last_row = math.max(vim.fn.line('v'), vim.fn.line('.'))
          change_index(selected_action, first_row, last_row)
        end, { buffer = b, nowait = true, silent = true, desc = 'Update selected status entries' })
      end

      vim.keymap.set('n', 'U', function()
        local changed, err = status_renderer.reset_index(b)
        if not changed then vim.notify(err, vim.log.levels.WARN); return end
        reload_status()
        notify_repo_changed()
      end, { buffer = b, nowait = true, silent = true, desc = 'Unstage all changes' })

      vim.keymap.set('n', 'S', function()
        local changed, err = status_renderer.stage_all(b)
        if not changed then vim.notify(err, vim.log.levels.WARN); return end
        reload_status()
        notify_repo_changed()
      end, { buffer = b, nowait = true, silent = true, desc = 'Stage all changes' })

      local function set_entry_diff(value)
        local row = vim.api.nvim_win_get_cursor(0)[1]
        local entry_row = status_renderer.entry_row(b, row)
        local mode = value == nil and 'toggle' or (value and 'show' or 'hide')
        if status_renderer.update_diff(b, row, mode) and entry_row then
          local line_count = vim.api.nvim_buf_line_count(b)
          pcall(vim.api.nvim_win_set_cursor, 0, { math.min(entry_row, line_count), 0 })
        end
      end

      vim.keymap.set('n', '=', function() set_entry_diff(nil) end,
        { buffer = b, nowait = true, silent = true, desc = 'Toggle inline diff' })
      vim.keymap.set('n', 'o', function() set_entry_diff(nil) end,
        { buffer = b, nowait = true, silent = true, desc = 'Toggle inline diff' })
      vim.keymap.set('n', '>', function() set_entry_diff(true) end,
        { buffer = b, nowait = true, silent = true, desc = 'Expand inline diff' })
      vim.keymap.set('n', '<', function() set_entry_diff(false) end,
        { buffer = b, nowait = true, silent = true, desc = 'Collapse inline diff' })

      local function is_status_file_line(line)
        return line:match('^[MADRCUT?!][MADRCUT?!]? ') ~= nil
      end

      local function is_status_item_line(line)
        return is_status_file_line(line) or line:match('^@@') ~= nil or line:match('^%x%x%x%x%x%x%x+%s') ~= nil
      end

      local function move_to_match(direction, predicate, count)
        count = count or 1
        local row = vim.api.nvim_win_get_cursor(0)[1]
        local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
        for _ = 1, count do
          local candidate = row + direction
          while candidate >= 1 and candidate <= #lines and not predicate(lines[candidate], candidate) do
            candidate = candidate + direction
          end
          if candidate < 1 or candidate > #lines then break end
          row = candidate
        end
        vim.api.nvim_win_set_cursor(0, { row, 0 })
        return row
      end

      local function conflict_action(action)
        local row = vim.api.nvim_win_get_cursor(0)[1]
        local changed, err
        if action == 'resolved' then
          changed, err = status_renderer.mark_resolved(b, row)
        else
          changed, err = status_renderer.resolve_conflict(b, row, action)
        end
        if not changed then vim.notify(err, vim.log.levels.WARN); return end
        reload_status()
        notify_repo_changed()
        if action == 'resolved' then
          vim.schedule(function()
            if utils.is_valid_buf(b) then M.focus_section(b, 'conflicted') end
          end)
        end
      end

      vim.keymap.set('n', 'co', function() conflict_action('ours') end,
        { buffer = b, nowait = true, silent = true, desc = 'Choose ours for conflicted file' })
      vim.keymap.set('n', 'ct', function() conflict_action('theirs') end,
        { buffer = b, nowait = true, silent = true, desc = 'Choose theirs for conflicted file' })
      vim.keymap.set('n', 'cr', function() conflict_action('resolved') end,
        { buffer = b, nowait = true, silent = true, desc = 'Mark conflicted file resolved' })
      vim.keymap.set('n', 'c3', function() open_conflict_diff(b) end,
        { buffer = b, nowait = true, silent = true, desc = 'Open base/ours/theirs conflict diff' })
      vim.keymap.set('n', ']x', function()
        move_to_match(1, function(_, candidate)
          local entry = status_renderer.entry_at(b, candidate)
          return entry and not entry.header and entry.section == 'conflicted'
        end, vim.v.count1)
      end, { buffer = b, nowait = true, silent = true, desc = 'Next conflicted file' })
      vim.keymap.set('n', '[x', function()
        move_to_match(-1, function(_, candidate)
          local entry = status_renderer.entry_at(b, candidate)
          return entry and not entry.header and entry.section == 'conflicted'
        end, vim.v.count1)
      end, { buffer = b, nowait = true, silent = true, desc = 'Previous conflicted file' })

      local function expand_at_cursor()
        local row = vim.api.nvim_win_get_cursor(0)[1]
        return status_renderer.update_diff(b, row, 'show')
      end

      local function next_expanded_item(count)
        for _ = 1, count do
          expand_at_cursor()
          move_to_match(1, function(line) return is_status_file_line(line) or line:match('^@@') end, 1)
        end
      end

      local function next_hunk(count)
        for _ = 1, count do
          expand_at_cursor()
          local row = move_to_match(1, function(line) return is_status_file_line(line) or line:match('^@@') end, 1)
          local line = vim.api.nvim_buf_get_lines(b, row - 1, row, false)[1] or ''
          if is_status_file_line(line) then
            expand_at_cursor()
            local next_line = vim.api.nvim_buf_get_lines(b, row, row + 1, false)[1] or ''
            if next_line:match('^@@') then vim.api.nvim_win_set_cursor(0, { row + 1, 0 }) end
          end
        end
      end

      local function previous_hunk(count)
        for _ = 1, count do
          local original_row = vim.api.nvim_win_get_cursor(0)[1]
          local before = vim.api.nvim_buf_get_lines(b, 0, -1, false)
          if (before[original_row] or ''):match('^@@') and is_status_file_line(before[original_row - 1] or '') then
            original_row = original_row - 1
            vim.api.nvim_win_set_cursor(0, { original_row, 0 })
          end
          local row = move_to_match(-1, function(line) return is_status_file_line(line) or line:match('^@@') end, 1)
          local line = vim.api.nvim_buf_get_lines(b, row - 1, row, false)[1] or ''
          if is_status_file_line(line) then
            expand_at_cursor()
            local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
            local last_hunk = nil
            for candidate = row + 1, #lines do
              if is_status_file_line(lines[candidate]) or lines[candidate] == '' then break end
              if lines[candidate]:match('^@@') then last_hunk = candidate end
            end
            if last_hunk then vim.api.nvim_win_set_cursor(0, { last_hunk, 0 }) end
          end
        end
      end

      local function move_file(direction, count)
        for _ = 1, count do
          local row = vim.api.nvim_win_get_cursor(0)[1]
          status_renderer.update_diff(b, row, 'hide')
          move_to_match(direction, is_status_file_line, 1)
        end
        local row = vim.api.nvim_win_get_cursor(0)[1]
        status_renderer.update_diff(b, row, 'hide')
      end

      vim.keymap.set('n', 'i', function()
        next_expanded_item(vim.v.count1)
        vim.cmd('normal! zt')
      end,
        { buffer = b, nowait = true, silent = true, desc = 'Expand and jump to next diff item' })
      for _, key in ipairs({ 'J', ']c' }) do
        vim.keymap.set('n', key, function() next_hunk(vim.v.count1) end,
          { buffer = b, nowait = true, silent = true, desc = 'Next diff hunk' })
      end
      for _, key in ipairs({ 'K', '[c' }) do
        vim.keymap.set('n', key, function() previous_hunk(vim.v.count1) end,
          { buffer = b, nowait = true, silent = true, desc = 'Previous diff hunk' })
      end
      for _, key in ipairs({ ']m', ']/' }) do
        vim.keymap.set('n', key, function() move_file(1, vim.v.count1) end,
          { buffer = b, nowait = true, silent = true, desc = 'Next changed file' })
      end
      for _, key in ipairs({ '[m', '[/' }) do
        vim.keymap.set('n', key, function() move_file(-1, vim.v.count1) end,
          { buffer = b, nowait = true, silent = true, desc = 'Previous changed file' })
      end
      vim.keymap.set('n', ')', function() move_to_match(1, is_status_item_line, vim.v.count1) end,
        { buffer = b, nowait = true, silent = true, desc = 'Next status item' })
      vim.keymap.set('n', '(', function() move_to_match(-1, is_status_item_line, vim.v.count1) end,
        { buffer = b, nowait = true, silent = true, desc = 'Previous status item' })

      local function move_file_expanded(direction, count)
        move_file(direction, count)
        expand_at_cursor()
        vim.cmd('normal! zt')
      end

      vim.keymap.set('n', ']]', function()
        move_file_expanded(1, vim.v.count1)
      end, { buffer = b, nowait = true, silent = true, desc = 'Collapse current and expand next file' })
      vim.keymap.set('n', '[[', function()
        move_file_expanded(-1, vim.v.count1)
      end, { buffer = b, nowait = true, silent = true, desc = 'Collapse current and expand previous file' })

      local function set_selected_diffs(mode)
        local first_row = math.min(vim.fn.line('v'), vim.fn.line('.'))
        local last_row = math.max(vim.fn.line('v'), vim.fn.line('.'))
        local seen = {}
        local changed = false
        for row = first_row, last_row do
          local entry = status_renderer.entry_at(b, row)
          local key = entry and (entry.section .. '\0' .. tostring(entry.path or 'header')) or nil
          if key and not seen[key] then
            seen[key] = true
            if mode == 'toggle' then
              changed = status_renderer.toggle_diff(b, row) or changed
            else
              changed = status_renderer.set_diff(b, row, mode == 'show') or changed
            end
          end
        end
        if changed then refresh() end
      end

      vim.keymap.set('x', '=', function() set_selected_diffs('toggle') end,
        { buffer = b, nowait = true, silent = true, desc = 'Toggle selected inline diffs' })
      vim.keymap.set('x', '>', function() set_selected_diffs('show') end,
        { buffer = b, nowait = true, silent = true, desc = 'Expand selected inline diffs' })
      vim.keymap.set('x', '<', function() set_selected_diffs('hide') end,
        { buffer = b, nowait = true, silent = true, desc = 'Collapse selected inline diffs' })

      for key, section in pairs({
        gu = 'untracked',
        gs = 'staged',
        gp = 'unpushed',
        gP = 'unpulled',
      }) do
        local target_section = section
        vim.keymap.set('n', key, function() M.focus_section(b, target_section) end,
          { buffer = b, nowait = true, silent = true, desc = 'Go to ' .. section .. ' section' })
      end

      vim.keymap.set('n', 'cw', function()
        local line = vim.api.nvim_get_current_line()
        local r = stash_ref_from_line(line)
        if r then
          rename_stash_at_cursor(r)
          return
        end

        local h = line:match('^%s*(%x%x%x%x%x%x%x+)')
        if h then
          -- Verify it is a commit hash
          local git = status_git_prefix()
          if not git then
            vim.notify('Not in a git repository', vim.log.levels.WARN)
            return
          end
          vim.fn.system(git .. 'rev-parse --verify ' .. vim.fn.shellescape(h .. '^{commit}') .. ' 2>/dev/null')
          if vim.v.shell_error == 0 then
            local head = vim.fn.trim(vim.fn.system(git .. 'rev-parse HEAD'))
            if head:sub(1, #h) == h then
              -- Use git commit --amend with a blocking editor that opens the message in Neovim
              local wt_head = utils.get_buf_work_tree(b)
              if not wt_head then
                vim.notify('Not in a git repository', vim.log.levels.WARN)
                return
              end
              local tmpb = vim.fn.tempname()
              local editor_file_head = tmpb .. '.editor.sh'
              local marker_file_head = tmpb .. '.marker'
              local done_file_head = tmpb .. '.done'
              vim.fn.writefile({"#!/bin/sh",
                "commit_msg_file=\"$1\"",
                "printf '%s\\n' \"$commit_msg_file\" > " .. vim.fn.shellescape(marker_file_head),
                "while [ ! -f " .. vim.fn.shellescape(done_file_head) .. " ]; do sleep 0.1; done",
                "exit 0"}, editor_file_head)
              vim.fn.system('chmod +x ' .. vim.fn.shellescape(editor_file_head))
              local commit_msg_bufnr_head = nil
              local uvh = vim.uv or vim.loop
              local timerh = uvh and uvh.new_timer and uvh.new_timer() or nil
              if not timerh then
                vim.notify('Failed to start amend watcher', vim.log.levels.ERROR)
                return
              end
              timerh:start(50, 50, vim.schedule_wrap(function()
                if vim.fn.filereadable(marker_file_head) == 1 then
                  timerh:stop()
                  timerh:close()
                  local linesh = vim.fn.readfile(marker_file_head)
                  local commit_msg_pathh = type(linesh) == 'table' and linesh[1] or ''
                  if commit_msg_pathh ~= '' then
                    vim.schedule(function()
                      local fname = vim.fn.fnameescape(commit_msg_pathh)
                      local winid = vim.fn.bufwinid(b)
                      if type(winid) == 'number' and winid > 0 then
                        pcall(vim.api.nvim_set_current_win, winid)
                      end
                      vim.cmd('belowright split ' .. fname)
                      -- Ensure new split gets focus and filetype is set
                      pcall(function() vim.bo.filetype = 'gitcommit' end)
                      commit_msg_bufnr_head = vim.api.nvim_get_current_buf()
                      -- Ensure git continues when buffer is written OR closed
                      vim.api.nvim_create_autocmd({'BufWritePost','BufWipeout','BufUnload'}, {
                        buffer = commit_msg_bufnr_head,
                        once = true,
                        callback = function()
                          pcall(vim.fn.writefile, {}, done_file_head)
                          if vim.fn.filereadable(marker_file_head) == 1 then pcall(vim.fn.delete, marker_file_head) end
                        end,
                      })
                    end)
                  end
                end
              end))
              local cmd_head = 'cd ' .. vim.fn.shellescape(wt_head) .. ' && GIT_EDITOR=' .. vim.fn.shellescape('sh ' .. editor_file_head) .. ' git commit --amend'
              vim.fn.jobstart({'sh','-c', cmd_head}, {
                stdout_buffered = true,
                stderr_buffered = true,
                on_exit = function(_, code)
                  pcall(vim.fn.delete, editor_file_head)
                  pcall(vim.fn.delete, marker_file_head)
                  pcall(vim.fn.delete, done_file_head)
                    if code == 0 then
                      vim.schedule(function()
                        vim.notify('Amend completed', vim.log.levels.INFO)
                        notify_repo_changed()
                        -- Close the commit message buffer if still open
                        if commit_msg_bufnr_head and pcall(vim.api.nvim_buf_is_valid, commit_msg_bufnr_head) and vim.api.nvim_buf_is_valid(commit_msg_bufnr_head) then
                          local winid = vim.fn.bufwinid(commit_msg_bufnr_head)
                        if type(winid) == 'number' and winid > 0 then pcall(vim.api.nvim_win_close, winid, true) end
                        if pcall(vim.api.nvim_buf_is_valid, commit_msg_bufnr_head) and vim.api.nvim_buf_is_valid(commit_msg_bufnr_head) then pcall(vim.api.nvim_buf_delete, commit_msg_bufnr_head, { force = true }) end
                      end
                    end)
                  else
                    vim.schedule(function()
                      vim.notify('Amend exited with code ' .. tostring(code), vim.log.levels.ERROR)
                    end)
                  end
                end,
              })
            else
              local base = h .. '^'
              vim.fn.system(git .. 'rev-parse ' .. vim.fn.shellescape(base) .. ' 2>/dev/null')
              if vim.v.shell_error ~= 0 then base = '--root' end

              -- Perform an interactive rebase that stops at the target commit and
              -- open the commit message file in this Neovim instance. We create a
              -- temporary sequence-editor to mark the todo as 'reword' and a small
              -- blocking editor script that writes the commit message path to a
              -- marker file; a timer watches that marker and opens the file for
              -- editing. When the user writes the buffer we touch the done file to
              -- let git continue.
              local wt = utils.get_buf_work_tree(b)
              if not wt then
                vim.notify('Not in a git repository', vim.log.levels.WARN)
                return
              end
              local short = h:sub(1, 7)
              local tmpbase = vim.fn.tempname()
              local seq_file = tmpbase .. '.seq.sh'
              local editor_file = tmpbase .. '.editor.sh'
              local marker_file = tmpbase .. '.marker'
              local done_file = tmpbase .. '.done'

              vim.fn.writefile({
                "#!/bin/sh",
                "tmp=$(mktemp)",
                "awk -v s=\"" .. short .. "\" '{ if ($0 ~ \"^pick .*\" s) { sub(/^pick/, \"reword\", $0); } print }' \"$1\" > \"$tmp\"",
                "mv \"$tmp\" \"$1\"",
              }, seq_file)
              vim.fn.writefile({"#!/bin/sh",
                "commit_msg_file=\"$1\"",
                "printf '%s\\n' \"$commit_msg_file\" > " .. vim.fn.shellescape(marker_file),
                "while [ ! -f " .. vim.fn.shellescape(done_file) .. " ]; do sleep 0.1; done",
                "exit 0"}, editor_file)

              -- Make scripts executable
              vim.fn.system('chmod +x ' .. vim.fn.shellescape(seq_file) .. ' ' .. vim.fn.shellescape(editor_file))

              -- Poll for marker file created by the editor script and open the file
              local commit_msg_bufnr_rebase = nil
              local uv = vim.uv or vim.loop
              local timer = uv and uv.new_timer and uv.new_timer() or nil
              if not timer then
                vim.notify('Failed to start rebase watcher', vim.log.levels.ERROR)
                return
              end
              timer:start(50, 50, vim.schedule_wrap(function()
                if vim.fn.filereadable(marker_file) == 1 then
                  timer:stop()
                  timer:close()
                  local lines = vim.fn.readfile(marker_file)
                  local commit_msg_path = type(lines) == 'table' and lines[1] or ''
                  if commit_msg_path ~= '' then
                    vim.schedule(function()
                      local fname = vim.fn.fnameescape(commit_msg_path)
                      local winid = vim.fn.bufwinid(b)
                      if type(winid) == 'number' and winid > 0 then
                        pcall(vim.api.nvim_set_current_win, winid)
                      end
                      vim.cmd('belowright split ' .. fname)
                      pcall(function() vim.bo.filetype = 'gitcommit' end)
                      commit_msg_bufnr_rebase = vim.api.nvim_get_current_buf()
                      -- Ensure git continues when buffer written OR closed
                      vim.api.nvim_create_autocmd({'BufWritePost','BufWipeout','BufUnload'}, {
                        buffer = commit_msg_bufnr_rebase,
                        once = true,
                        callback = function()
                          pcall(vim.fn.writefile, {}, done_file)
                          if vim.fn.filereadable(marker_file) == 1 then pcall(vim.fn.delete, marker_file) end
                        end,
                      })
                    end)
                  end
                end
              end))

              -- Start the rebase asynchronously with our custom editors
              local cmd = 'cd ' .. vim.fn.shellescape(wt)
                .. ' && GIT_SEQUENCE_EDITOR=' .. vim.fn.shellescape('sh ' .. seq_file)
                .. ' GIT_EDITOR=' .. vim.fn.shellescape('sh ' .. editor_file)
                .. ' git rebase -i ' .. vim.fn.shellescape(base)
              vim.fn.jobstart({'sh', '-c', cmd}, {
                stdout_buffered = true,
                stderr_buffered = true,
                on_exit = function(_, code)
                  -- Cleanup
                  pcall(vim.fn.delete, seq_file)
                  pcall(vim.fn.delete, editor_file)
                  pcall(vim.fn.delete, marker_file)
                  pcall(vim.fn.delete, done_file)
                    if code == 0 then
                      vim.schedule(function()
                        vim.notify('Rebase completed', vim.log.levels.INFO)
                        notify_repo_changed()
                        -- Close the commit message buffer if still open
                        if commit_msg_bufnr_rebase and pcall(vim.api.nvim_buf_is_valid, commit_msg_bufnr_rebase) and vim.api.nvim_buf_is_valid(commit_msg_bufnr_rebase) then
                          local winid = vim.fn.bufwinid(commit_msg_bufnr_rebase)
                        if type(winid) == 'number' and winid > 0 then pcall(vim.api.nvim_win_close, winid, true) end
                        if pcall(vim.api.nvim_buf_is_valid, commit_msg_bufnr_rebase) and vim.api.nvim_buf_is_valid(commit_msg_bufnr_rebase) then pcall(vim.api.nvim_buf_delete, commit_msg_bufnr_rebase, { force = true }) end
                      end
                    end)
                  else
                    vim.schedule(function()
                      vim.notify('Rebase exited with code ' .. tostring(code), vim.log.levels.ERROR)
                    end)
                  end
                end,
              })
            end
            return
          end
        end
        vim.notify('No commit or stash found at cursor', vim.log.levels.WARN)
      end, { buffer = b, nowait = true, silent = true, desc = "Reword commit or rename stash" })

      vim.keymap.set('n', 'A', function()
        if is_cursor_in_stash_area() then
          local r = get_stash_ref_at_cursor(b)
          if r then vim.cmd('Git stash apply ' .. r); notify_repo_changed() end
          return
        end
        vim.cmd('Git commit --amend --no-edit')
        notify_repo_changed()
      end, { buffer = b, nowait = true, silent = true })

      vim.keymap.set('n', 'cl', function()
        vim.cmd('Gstash')
      end, { buffer = b, nowait = true, silent = true, desc = 'Stash changes' })

      vim.keymap.set('n', 'P', function()
        if is_cursor_in_stash_area() then
          local r = get_stash_ref_at_cursor(b)
          if r then vim.cmd('Git stash pop ' .. r); notify_repo_changed() end
          return
        end
        local cmd, err = status_renderer.patch_command(b, vim.api.nvim_win_get_cursor(0)[1])
        if not cmd then vim.notify(err, vim.log.levels.WARN); return end
        vim.cmd(cmd)
      end, { buffer = b, nowait = true, silent = true })

      vim.keymap.set('n', 'I', function()
        local cmd, err = status_renderer.patch_command(b, vim.api.nvim_win_get_cursor(0)[1])
        if not cmd then vim.notify(err, vim.log.levels.WARN); return end
        vim.cmd(cmd)
      end, { buffer = b, nowait = true, silent = true, desc = 'Stage/reset patch' })

      local function drop_status_commits(first_row, last_row)
        local commits, seen = {}, {}
        for row = first_row, last_row do
          local line = vim.api.nvim_buf_get_lines(b, row - 1, row, false)[1] or ''
          local commit = line:match('^(%x%x%x%x%x%x%x+)%s')
          if commit and not seen[commit] then
            seen[commit] = true
            table.insert(commits, commit)
          end
        end
        if #commits == 0 then return false end

        local summary = #commits == 1
          and commits[1]:sub(1, 7)
          or ('%s ... %s (%d commits)'):format(commits[1]:sub(1, 7), commits[#commits]:sub(1, 7), #commits)
        if vim.fn.confirm(('Drop %d commit(s)?\n%s'):format(#commits, summary), '&Yes\n&No', 2) ~= 1 then
          return true
        end
        commands.drop_commits(commits, function()
          reload_status()
          notify_repo_changed()
        end)
        return true
      end

      local function index_flag_entry_at_cursor()
        return index_flags.entry_from_line(index_flags_by_buf[b], vim.api.nvim_get_current_line())
      end

      local function index_flag_path_at_cursor()
        local flagged = index_flag_entry_at_cursor()
        if flagged then return flagged.path end
        local entry = status_renderer.entry_at(b, vim.api.nvim_win_get_cursor(0)[1])
        if entry and not entry.header and entry.section ~= 'untracked' then return entry.path end
        return nil
      end

      local function move_to_index_flags(expand)
        if expand ~= nil then index_flags_expanded_by_buf[b] = expand end
        refresh()
        vim.schedule(function()
          if not utils.is_valid_buf(b) then return end
          local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
          for row, line in ipairs(lines) do
            if line:match('^Index flags %[local%]') then
              local target = index_flags_expanded_by_buf[b] and math.min(row + 1, #lines) or row
              pcall(vim.api.nvim_win_set_cursor, 0, { target, 0 })
              vim.cmd('normal! zz')
              return
            end
          end
        end)
      end

      local function update_index_flag(path, flag)
        local work_tree = utils.get_buf_work_tree(b)
        if not work_tree then return end
        local ok, err = index_flags.update(work_tree, path, flag)
        if not ok then vim.notify(err, vim.log.levels.ERROR); return end
        local action = flag and ('set to ' .. flag) or 'cleared'
        vim.notify(('Index flag %s: %s'):format(action, path), vim.log.levels.INFO)
        reload_status()
        notify_repo_changed()
      end

      local function choose_index_flag_action(path)
        local current = index_flags.flag_for_path(index_flags_by_buf[b], path)
        local choices = {}
        if current then
          table.insert(choices, { flag = nil, label = 'Clear ' .. current })
        end
        if current ~= 'skip' then
          table.insert(choices, { flag = 'skip', label = 'Set skip-worktree' })
        end
        if current ~= 'assume' then
          table.insert(choices, { flag = 'assume', label = 'Set assume-unchanged (performance hint)' })
        end
        vim.ui.select(choices, { prompt = 'Index flag for ' .. path .. ':' }, function(choice)
          if choice then update_index_flag(path, choice.flag) end
        end)
      end

      local function show_index_flag_actions()
        local path = index_flag_path_at_cursor()
        if path then choose_index_flag_action(path); return end
        local work_tree = utils.get_buf_work_tree(b)
        if not work_tree then return end
        local paths, err = index_flags.tracked_paths(work_tree)
        if #paths == 0 then
          vim.notify(err or 'No tracked files', vim.log.levels.WARN)
          return
        end
        vim.ui.select(paths, { prompt = 'Select tracked file for index flag:' }, function(selected)
          if selected then choose_index_flag_action(selected) end
        end)
      end

      vim.keymap.set('n', 'gU', show_index_flag_actions,
        { buffer = b, nowait = true, silent = true, desc = 'Manage update-index flags' })

      vim.keymap.set('n', 'X', function()
        local flagged = index_flag_entry_at_cursor()
        if flagged then update_index_flag(flagged.path, nil); return end
        if is_cursor_in_worktree_area() then
          local p = get_worktree_path_at_cursor()
          if p then worktree.remove_worktree_path(p) end
          return
        end
        if is_cursor_in_stash_area() then
          local r = get_stash_ref_at_cursor(b)
          if r then vim.cmd('Git stash drop ' .. r); notify_repo_changed() end
          return
        end
        local row = vim.api.nvim_win_get_cursor(0)[1]
        if drop_status_commits(row, row) then return end
        local _, _, entry = status_entry_at_cursor()
        if entry then
          local discarded, err = status_renderer.discard(b, vim.api.nvim_win_get_cursor(0)[1])
          if not discarded then vim.notify(err, vim.log.levels.WARN); return end
          reload_status()
          notify_repo_changed()
          return
        end
        vim.notify('No discardable item at cursor', vim.log.levels.WARN)
      end, { buffer = b, nowait = true, silent = true })

      vim.keymap.set('x', 'X', function()
        local first_row = math.min(vim.fn.line('v'), vim.fn.line('.'))
        local last_row = math.max(vim.fn.line('v'), vim.fn.line('.'))
        vim.cmd('normal! \27')
        if not drop_status_commits(first_row, last_row) then
          vim.notify('No commits found', vim.log.levels.WARN)
        end
      end, { buffer = b, nowait = true, silent = true, desc = 'Drop selected commits' })

      local function show_status_actions()
        local row = vim.api.nvim_win_get_cursor(0)[1]
        local on_commit = vim.api.nvim_get_current_line():match('^(%x%x%x%x%x%x%x+)%s') ~= nil
        local flagged_entry = index_flag_entry_at_cursor()
        local entry = status_renderer.entry_at(b, row)
        local conflicted = entry and not entry.header and entry.section == 'conflicted'
        local work_tree = utils.get_buf_work_tree(b)
        local current_operation = work_tree and operation.inspect(work_tree) or nil
        local health = repository_health_by_buf[b]
        local has_submodules = health ~= nil and #health.submodules > 0
        local on_submodule = submodule_path_at_cursor() ~= nil
        local branch = health and health.branch or 'unknown'
        local context = 'Branch: ' .. tostring(branch)
        if current_operation then context = context .. '  Operation: ' .. current_operation.kind end
        if entry and not entry.header and entry.path then context = context .. '  Path: ' .. entry.path end

        require('features.action_menu').show('Git status actions', {
          { title = 'Changes', actions = {
            { key = 'o', label = 'Toggle inline diff', enabled = entry ~= nil },
            { key = 's', label = 'Stage / unstage', enabled = entry ~= nil },
            { key = 'P', label = 'Patch mode', enabled = entry ~= nil },
            { key = 'X', label = 'Discard change / drop commit' },
            { key = 'c3', label = 'Open base / ours / theirs', enabled = conflicted },
            { key = 'co', label = 'Choose ours', enabled = conflicted },
            { key = 'ct', label = 'Choose theirs', enabled = conflicted },
            { key = 'cr', label = 'Mark resolved', enabled = conflicted },
          } },
          { title = 'Commit', actions = {
            { key = 'gn', label = 'Show Git note', enabled = on_commit },
            { key = 'gN', label = 'Add / edit Git note', enabled = on_commit },
            { key = 'cc', label = 'Commit staged changes' },
            { key = 'ca', label = 'Amend commit' },
            { key = 'ce', label = 'Amend without editing message' },
            { key = 'cf', label = 'Fixup / reword with index' },
            { key = 'cF', label = 'Fixup unchanged message' },
            { key = 'cw', label = 'Reword commit / rename stash' },
            { key = 'rD', label = 'Review rewritten stack', enabled = health ~= nil and health.upstream ~= nil and not health.upstream.gone },
          } },
          { title = 'Operation', actions = {
            { key = 'rr', label = 'Continue', enabled = current_operation ~= nil and current_operation.kind ~= 'bisect' },
            { key = 'rs', label = 'Skip', enabled = current_operation ~= nil and current_operation.kind ~= 'merge' and current_operation.kind ~= 'bisect' },
            { key = 'ra', label = 'Abort', enabled = current_operation ~= nil and current_operation.kind ~= 'bisect' },
            { key = 'bs', label = 'Start bisect', enabled = current_operation == nil },
            { key = 'bg', label = 'Mark good', enabled = current_operation ~= nil and current_operation.kind == 'bisect' },
            { key = 'bb', label = 'Mark bad', enabled = current_operation ~= nil and current_operation.kind == 'bisect' },
            { key = 'bk', label = 'Skip candidate', enabled = current_operation ~= nil and current_operation.kind == 'bisect' },
            { key = 'bx', label = 'Run test command', enabled = current_operation ~= nil and current_operation.kind == 'bisect' },
            { key = 'br', label = 'Reset bisect', enabled = current_operation ~= nil and current_operation.kind == 'bisect' },
          } },
          { title = 'Repository', actions = {
            { key = 'gU', label = 'Manage update-index flags' },
            { key = 'X', label = 'Clear selected index flag', enabled = flagged_entry ~= nil },
            { key = 'd', label = 'Diff flagged worktree file against index', enabled = flagged_entry ~= nil },
            { key = 'mi', label = on_submodule and 'Initialize selected submodule' or 'Initialize all submodules', enabled = has_submodules },
            { key = 'mu', label = on_submodule and 'Update selected submodule' or 'Update all submodules', enabled = has_submodules },
            { key = 'ms', label = 'Synchronize submodule URLs', enabled = has_submodules },
            { key = 'mU', label = 'Set branch upstream', enabled = health ~= nil and not health.detached },
            { key = 'L', label = 'Open log' },
            { key = 'B', label = 'Open branches' },
            { key = 'W', label = 'Open worktrees' },
            { key = 'R', label = 'Collapse and refresh' },
          } },
        }, { context = context })
      end
      vim.keymap.set('n', 'g?', show_status_actions,
        { buffer = b, nowait = true, silent = true, desc = 'Show Git status actions' })
      vim.keymap.set('n', '?', show_status_actions,
        { buffer = b, nowait = true, silent = true, desc = 'Show Git status actions' })

      local function note_target()
        local commit = vim.api.nvim_get_current_line():match('^(%x%x%x%x%x%x%x+)%s')
        if not commit then vim.notify('No commit found at cursor', vim.log.levels.WARN) end
        return commit
      end

      vim.keymap.set('n', 'gn', function()
        local commit = note_target()
        if commit then notes.show(utils.get_buf_work_tree(b), commit, apply_icons) end
      end, { buffer = b, nowait = true, silent = true, desc = 'Show Git note' })

      vim.keymap.set('n', 'gN', function()
        local commit = note_target()
        if commit then notes.edit(utils.get_buf_work_tree(b), commit, apply_icons) end
      end, { buffer = b, nowait = true, silent = true, desc = 'Edit Git note' })

      local function open_status_item()
        local current_line = vim.api.nvim_get_current_line()
        if current_line:match('^Hidden changes: %d+ files? %(Index flags%)$') then
          move_to_index_flags(true)
          return
        end
        if current_line:match('^Index flags %[local%]') then
          index_flags_expanded_by_buf[b] = not index_flags_expanded_by_buf[b]
          refresh()
          return
        end
        local flagged = index_flag_entry_at_cursor()
        if flagged then
          open_index_flag_file(b, flagged.path)
          return
        end
        if is_cursor_on_commit_header() then
          toggle_commit_scope()
          return
        end
        if is_cursor_on_pull_request_header() then
          toggle_pull_request_scope()
          return
        end
        local submodule_path = submodule_path_at_cursor()
        if submodule_path then
          local root = utils.get_buf_work_tree(b)
          local child = root and vim.fs.joinpath(root, submodule_path) or nil
          if child and utils.get_git_dir(child) then
            vim.cmd('tabnew')
            M.open({ work_tree = child })
          else
            vim.notify('Submodule is not initialized: ' .. submodule_path, vim.log.levels.WARN)
          end
          return
        end
        if is_cursor_in_worktree_area() then
          local p = get_worktree_path_at_cursor()
          if p then worktree.open_worktree_path(p); return end
        end
        if is_cursor_in_pull_request_area() then
          local number = pull_request_number_from_line(vim.api.nvim_get_current_line())
          local repository = nil
          for _, pr in ipairs(pull_requests_by_buf[b] or {}) do
            if pr.number == number then
              repository = pr.repository
              break
            end
          end
          if number and repository then
            vim.cmd('tabnew')
            vim.cmd(('Octo pr edit %d %s'):format(number, repository))
          elseif number then
            vim.notify('Could not determine repository for PR #' .. number, vim.log.levels.WARN)
          end
          return
        end
        if is_cursor_in_stash_area() then
          local r = get_stash_ref_at_cursor(b)
          if r then vim.cmd('Gvsplit ' .. r); return end
        end
        local f = utils.get_filepath_at_cursor(b)
        if f then
          local wt = utils.get_buf_work_tree(b)
          local abs = wt and vim.fn.fnamemodify(wt .. '/' .. f, ':p') or nil
          -- Only open Oil when cursor is directly on the status line for that path
          local cur_line = vim.api.nvim_get_current_line()
          local cur_match = cur_line:match('^[MADRCUT?!][MADRCUT?!]? (.+)$')
          if cur_match then
            local _, new = cur_match:match('^(.+) %-> (.+)$')
            cur_match = new or cur_match
          end
          if abs and cur_match == f and vim.fn.isdirectory(abs) == 1 then
            open_oil_in_target(b, abs)
            return
          end
        end
        open_entry_from_status(b, false)
      end

      vim.keymap.set('n', '<CR>', open_status_item, { buffer = b, nowait = true, silent = true })
      vim.keymap.set('n', '<2-LeftMouse>', open_status_item, { buffer = b, nowait = true, silent = true })

      vim.keymap.set('n', 'gS', function()
        if is_cursor_on_commit_header() then
          select_commit_scope()
        elseif is_cursor_on_pull_request_header() then
          select_pull_request_scope()
        else
          vim.notify('No selectable scope at cursor', vim.log.levels.WARN)
        end
      end, { buffer = b, nowait = true, silent = true, desc = 'Select status section scope' })

      local function add_ignore_patterns(first_row, last_row, repository_ignore)
        local paths = status_renderer.paths_in_range(b, first_row, last_row)
        if #paths == 0 then
          vim.notify('No file found at cursor', vim.log.levels.WARN)
          return
        end
        for index, path in ipairs(paths) do paths[index] = '/' .. path end

        local work_tree = utils.get_buf_work_tree(b)
        local git_dir = vim.b[b].git_dir
        local target = repository_ignore
          and work_tree and vim.fs.joinpath(work_tree, '.gitignore')
          or git_dir and vim.fs.joinpath(git_dir, 'info', 'exclude')
        if not target then
          vim.notify('Git ignore file could not be resolved', vim.log.levels.WARN)
          return
        end
        if not repository_ignore then vim.fn.mkdir(vim.fs.dirname(target), 'p') end

        vim.cmd('belowright split ' .. vim.fn.fnameescape(target))
        local target_buf = vim.api.nvim_get_current_buf()
        local existing = vim.api.nvim_buf_get_lines(target_buf, 0, -1, false)
        local first_inserted
        if #existing == 1 and existing[1] == '' then
          vim.api.nvim_buf_set_lines(target_buf, 0, -1, false, paths)
          first_inserted = 1
        else
          first_inserted = #existing + 1
          vim.api.nvim_buf_set_lines(target_buf, #existing, #existing, false, paths)
        end
        vim.api.nvim_win_set_cursor(0, { first_inserted, 0 })
      end

      vim.keymap.set('n', 'gE', function()
        local row = vim.api.nvim_win_get_cursor(0)[1]
        add_ignore_patterns(row, row, false)
      end, { buffer = b, nowait = true, silent = true, desc = 'Add path to .git/info/exclude' })
      vim.keymap.set('x', 'gE', function()
        add_ignore_patterns(math.min(vim.fn.line('v'), vim.fn.line('.')), math.max(vim.fn.line('v'), vim.fn.line('.')), false)
      end, { buffer = b, nowait = true, silent = true, desc = 'Add paths to .git/info/exclude' })
      vim.keymap.set('n', 'gI', function()
        local row = vim.api.nvim_win_get_cursor(0)[1]
        add_ignore_patterns(row, row, true)
      end, { buffer = b, nowait = true, silent = true, desc = 'Add path to .gitignore' })
      vim.keymap.set('x', 'gI', function()
        add_ignore_patterns(math.min(vim.fn.line('v'), vim.fn.line('.')), math.max(vim.fn.line('v'), vim.fn.line('.')), true)
      end, { buffer = b, nowait = true, silent = true, desc = 'Add paths to .gitignore' })

      vim.keymap.set('n', 'gf', function()
        open_entry_from_status(b, true)
      end, { buffer = b, nowait = true, silent = true, desc = 'Open file and close status' })

      -- Toggle Flog
      vim.keymap.set('n', '<C-Space>', function()
        if vim.g.flog_win and vim.api.nvim_win_is_valid(vim.g.flog_win) then
          vim.api.nvim_win_close(vim.g.flog_win, false); vim.g.flog_win, vim.g.flog_bufnr = nil, nil
        else
          local cw = vim.api.nvim_get_current_win()
          vim.cmd("Flogsplit -open-cmd=vertical\\ rightbelow\\ 60vsplit")
          vim.g.flog_bufnr, vim.g.flog_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
          utils.setup_flog_window(vim.g.flog_win, vim.g.flog_bufnr)
          vim.api.nvim_set_current_win(cw)
        end
      end, { buffer = b, nowait = true, silent = true })

      -- Smart Close
      vim.keymap.set('n', 'q', function()
        if vim.g.flog_win and vim.api.nvim_win_is_valid(vim.g.flog_win) then vim.api.nvim_win_close(vim.g.flog_win, true) end
        require"utilities".smart_close()
      end, { buffer = b, nowait = true, silent = true })

      vim.keymap.set('n', '<C-c>', '<C-w>c',
        { buffer = b, nowait = true, silent = true, desc = 'Close status window' })

      vim.keymap.set('n', 'L', '<Cmd>FugitiveLog<CR>',
        { buffer = b, nowait = true, silent = true, desc = 'Open git log' })
      vim.keymap.set('n', 'B', '<Cmd>Gbranch<CR>',
        { buffer = b, nowait = true, silent = true, desc = 'Open git branch list' })
      vim.keymap.set('n', 'W', '<Cmd>Gworktree<CR>',
        { buffer = b, nowait = true, silent = true, desc = 'Open git worktree list' })
      vim.keymap.set('n', 'gs', function()
        worktree.sync_current_worktree_to_primary()
      end, { buffer = b, nowait = true, silent = true, desc = 'Sync current worktree to primary' })

      vim.keymap.set('n', 'R', function()
        status_renderer.collapse_all(b)
        index_flags_expanded_by_buf[b] = false
        reload_status()
        vim.schedule(function()
          if utils.is_valid_buf(b) then M.focus_section(b, 'unstaged') end
        end)
      end, { buffer = b, silent = true, desc = 'Collapse all and refresh status' })

      vim.keymap.set('n', 'rD', function()
        local work_tree = utils.get_buf_work_tree(b)
        if work_tree then range_diff.open(work_tree) end
      end, { buffer = b, nowait = true, silent = true, desc = 'Review outgoing stack with range-diff' })

      local function commit_hash_at_cursor()
        local l = vim.api.nvim_get_current_line()
        local h = l:match('^(%x+)')
        if not h then vim.notify('No commit found at cursor', vim.log.levels.WARN); return nil end
        return h
      end

      -- cf: Extension action: fixup/reword with the index, then autosquash.
      vim.keymap.set('n', 'cf', function()
        local h = commit_hash_at_cursor()
        if not h then return end
        commands.mix_index_with_input(h)
      end, { buffer = b, nowait = true, silent = true, desc = 'Fixup/Reword commit under cursor with index' })

      -- cF: Fugitive-compatible action: fixup with the index, then autosquash.
      vim.keymap.set('n', 'cF', function()
        local h = commit_hash_at_cursor()
        if not h then return end
        commands.mix_index(h)
      end, { buffer = b, nowait = true, silent = true, desc = 'Fixup commit under cursor with index and autosquash' })

      vim.keymap.set('n', 'cW', function()
        local h = commit_hash_at_cursor()
        if h then vim.cmd('Git commit --fixup=reword:' .. h) end
      end, { buffer = b, nowait = true, silent = true, desc = 'Create reword fixup for commit under cursor' })

      vim.keymap.set('n', 'cs', function()
        local h = commit_hash_at_cursor()
        if h then vim.cmd('Git commit --no-edit --squash=' .. h) end
      end, { buffer = b, nowait = true, silent = true, desc = 'Create squash commit for commit under cursor' })

      vim.keymap.set('n', 'cn', function()
        local h = commit_hash_at_cursor()
        if h then vim.cmd('Git commit --edit --squash=' .. h) end
      end, { buffer = b, nowait = true, silent = true, desc = 'Create edited squash commit for commit under cursor' })

      vim.keymap.set('n', 'cS', function()
        local h = commit_hash_at_cursor()
        if not h then return end
        local committed, err = pcall(vim.cmd, 'Git commit --no-edit --squash=' .. h)
        if not committed then vim.notify(tostring(err), vim.log.levels.ERROR); return end
        vim.cmd('Git -c sequence.editor=true rebase --interactive --autosquash ' .. h .. '^')
      end, { buffer = b, nowait = true, silent = true, desc = 'Squash commit under cursor and autosquash' })

      -- <Leader>cf: Squash commit under cursor into its parent (Fixup)
      vim.keymap.set('n', '<Leader>cf', function()
        local h = commit_hash_at_cursor()
        if not h then return end
        commands.fixup_commit(h)
      end, { buffer = b, nowait = true, silent = true, desc = 'Fixup/Reword commit under cursor into its parent' })

      -- gr: Revert commit under cursor
      vim.keymap.set('n', 'gr', function()
        local l = vim.api.nvim_get_current_line()
        local h = l:match('^(%x+)')
        if not h then vim.notify('No commit found at cursor', vim.log.levels.WARN) return end
        local confirm = vim.fn.confirm('Revert ' .. h:sub(1, 7) .. '?', '&Yes\n&No', 2)
        if confirm ~= 1 then return end
        commands.revert_commits({ h })
      end, { buffer = b, nowait = true, silent = true, desc = 'Revert commit under cursor' })

      local function open_diff_at_cursor(layout)
        local flagged = index_flag_entry_at_cursor()
        if flagged then
          open_index_flag_diff(b, flagged, layout)
          return
        end
        local target_line = nil
        local current_line_idx = vim.api.nvim_win_get_cursor(0)[1]
        local hunk_line = nil

        for lnum = current_line_idx, 1, -1 do
          local line = vim.api.nvim_buf_get_lines(b, lnum - 1, lnum, false)[1]
          if line then
            local line_num = line:match('^@@ %-%d+,?%d* %+(%d+)')
            if line_num then
              hunk_line = lnum
              target_line = tonumber(line_num)
              break
            end
            if line:match('^[MADRCUT?!][MADRCUT?!]? (.+)$') then break end
          end
        end

        if target_line and hunk_line then
          local offset = 0
          for lnum = hunk_line + 1, current_line_idx do
            local line = vim.api.nvim_buf_get_lines(b, lnum - 1, lnum, false)[1]
            if line and not line:match('^%-') then offset = offset + 1 end
          end
          target_line = target_line + offset - 1
        end

        open_status_diff(b, target_line, layout)
      end

      vim.keymap.set('n', 'd', function() open_diff_at_cursor('vertical') end,
        { buffer = b, silent = true, desc = 'Open file diff in new tab' })
      for _, key in ipairs({ 'dd', 'dv' }) do
        vim.keymap.set('n', key, function() open_diff_at_cursor('vertical') end,
          { buffer = b, nowait = true, silent = true, desc = 'Open vertical file diff' })
      end
      for _, key in ipairs({ 'dh', 'ds' }) do
        vim.keymap.set('n', key, function() open_diff_at_cursor('horizontal') end,
          { buffer = b, nowait = true, silent = true, desc = 'Open horizontal file diff' })
      end

      -- Load syntax
      syntax_highlight.attach(b)

      -- <Leader>wd: Toggle word diff style
      vim.keymap.set('n', '<Leader>wd', function()
        local new_style = syntax_highlight.cycle_word_diff_style()
        vim.notify('Word diff style: ' .. new_style, vim.log.levels.INFO)
      end, { buffer = b, silent = true, desc = 'Toggle word diff style (diffs/lazygit/github)' })
    end,
  })

  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    pattern = 'git-status://*',
    callback = function() configure_status_window(vim.api.nvim_get_current_win()) end,
  })

  vim.api.nvim_create_user_command('GitStatus', function()
    M.open({ focus = 'unstaged', split = true })
  end, { desc = 'Open custom Git status' })
end

function M.refresh_buffer(bufnr)
  if not utils.is_valid_buf(bufnr) then return end
  local ns_worktree = vim.api.nvim_create_namespace('fugitive_status_worktree')
  local ns_stash = vim.api.nvim_create_namespace('fugitive_status_stash')
  local ns_pr = vim.api.nvim_create_namespace('fugitive_status_pull_requests')
  pcall(function()
    refresh_status_sections(bufnr, ns_worktree, ns_stash, ns_pr)
  end)
  notes.apply_icons(bufnr, utils.get_buf_work_tree(bufnr), function(line)
    return line:match('^(%x%x%x%x%x%x%x+)%s')
  end)
end

function M.focus_section(bufnr, section)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local patterns = {
    conflicted = '^Unmerged',
    untracked = '^Untracked',
    unstaged = '^Unstaged',
    staged = '^Staged',
    unpulled = '^Unpulled ',
    unpushed = '^Unpushed %[only%]',
  }
  local pattern = patterns[section]
  if not pattern then return false end

  local function focus()
    if not utils.is_valid_buf(bufnr) then return end
    local winid = vim.fn.bufwinid(bufnr)
    if winid == -1 then return false end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for row, line in ipairs(lines) do
      if line:match(pattern) then
        local target = row < #lines and lines[row + 1] ~= '' and row + 1 or row
        pcall(vim.api.nvim_win_set_cursor, winid, { target, 0 })
        return true
      end
    end
    return false
  end
  if not focus() then
    M.refresh_buffer(bufnr)
    if not focus() then vim.schedule(focus) end
  end
  return true
end

local function resolve_status_work_tree(opts)
  if opts and opts.work_tree then return utils.normalize_path(opts.work_tree) end
  local current_buf = vim.api.nvim_get_current_buf()
  if vim.b[current_buf].fugitive_work_tree then
    local known = utils.get_buf_work_tree(current_buf)
    if known and utils.get_git_dir(known) then return known end
  end

  local base = vim.fn.getcwd()
  local name = vim.api.nvim_buf_get_name(current_buf)
  if name ~= '' and vim.bo[current_buf].buftype == '' then
    base = vim.fn.isdirectory(name) == 1 and name or vim.fs.dirname(name)
  end
  local result = vim.system({ 'git', '-C', base, 'rev-parse', '--show-toplevel' }, { text = true }):wait()
  if result.code ~= 0 then return nil end
  return utils.normalize_path(vim.trim(result.stdout or ''))
end

function M.open(opts)
  opts = opts or {}
  local work_tree = resolve_status_work_tree(opts)
  if not work_tree then
    vim.notify('Not in a Git repository', vim.log.levels.WARN)
    return nil
  end

  local bufnr
  for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
    if is_status_buffer(candidate) and utils.get_buf_work_tree(candidate) == work_tree then
      bufnr = candidate
      break
    end
  end

  local winid = bufnr and vim.fn.bufwinid(bufnr) or -1
  if winid ~= -1 then
    vim.api.nvim_set_current_win(winid)
  else
    if not bufnr then
      bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(bufnr, 'git-status://' .. work_tree)
      vim.bo[bufnr].buftype = 'nofile'
      vim.bo[bufnr].bufhidden = 'hide'
      vim.bo[bufnr].swapfile = false
      vim.bo[bufnr].undofile = false
      vim.bo[bufnr].modifiable = false
      vim.bo[bufnr].readonly = true
      utils.set_buf_work_tree(bufnr, work_tree)
    end
    if opts.split then
      local current_win = vim.api.nvim_get_current_win()
      local config = vim.api.nvim_win_get_config(current_win)
      if config.external or (config.relative and config.relative ~= '') then
        for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          local candidate_config = vim.api.nvim_win_get_config(candidate)
          if not candidate_config.external
            and (candidate_config.relative == nil or candidate_config.relative == '')
          then
            vim.api.nvim_set_current_win(candidate)
            break
          end
        end
      end
      vim.cmd('keepalt split')
    end
    vim.api.nvim_win_set_buf(0, bufnr)
    if vim.bo[bufnr].filetype ~= 'fugitivestatus' then
      vim.bo[bufnr].filetype = 'fugitivestatus'
    else
      M.refresh_buffer(bufnr)
    end
  end

  if opts.focus then M.focus_section(bufnr, opts.focus) end
  configure_status_window(vim.fn.bufwinid(bufnr))
  return bufnr
end

function M.reload_buffer(bufnr)
  if not utils.is_valid_buf(bufnr) then return end
  local anchors = capture_status_cursors_before_reload(bufnr)
  if #anchors > 0 then pending_status_cursor_anchors_by_buf[bufnr] = anchors end
  vim.schedule(function()
    M.refresh_buffer(bufnr)
  end)
end

function M.refresh_all()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if is_status_buffer(bufnr) then
      M.refresh_buffer(bufnr)
    end
  end
end

return M

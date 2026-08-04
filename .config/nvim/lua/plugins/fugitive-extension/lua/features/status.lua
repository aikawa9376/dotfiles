local M = {}
local utils = require("fugitive_utils")
local commands = require("features.commands")
local syntax_highlight = require("features.syntax_highlight")
local worktree = require("features.worktree")
local pull_requests_by_buf = {}
local pull_request_scope_by_buf = {}
local pull_request_branch_by_buf = {}
local commit_scope_by_buf = {}
local unpushed_commits_by_buf = {}

local function stash_ref_from_line(line)
  return line and line:match('stash@%{%d+%}')
end

local function pull_request_number_from_line(line)
  return line and tonumber(line:match('^#(%d+)%s'))
end

local function remove_custom_sections(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local ranges = {}
  local i = 1
  while i <= #lines do
    local line = lines[i]
    -- カスタムセクションのヘッダーを検知
    if line:match('^Unpushed %[only%]') or line:match('^Commits %[') or line:match('^Worktrees %(') or
       line:match('^Stashes %(') or line:match('^Pull requests %(') then
      local start_idx = i
      -- 直前の空行も含める
      if start_idx > 1 and lines[start_idx - 1] == '' then start_idx = start_idx - 1 end

      -- セクションの終わり（次のヘッダーまたは空行の連続後、またはバッファ末尾）までを削除範囲とする
      local end_idx = i
      while end_idx < #lines do
        local next_line = lines[end_idx + 1]
        -- セクションに含まれる可能性のある行のパターン
        if next_line == '' or
           next_line:match('^[~/]') or next_line:match('^stash@') or next_line:match('^#%d+%s') or
           next_line:match('^%x+%s') or next_line:match('^Unpushed %[only%]') or
           next_line:match('^Commits %[') or next_line:match('^Worktrees %(') or next_line:match('^Stashes %(') or
           next_line:match('^Pull requests %(') then
          end_idx = end_idx + 1
        else break end
      end
      table.insert(ranges, { start_idx, end_idx })
      i = end_idx + 1
    else i = i + 1 end
  end
  -- 後ろから順に削除
  for r = #ranges, 1, -1 do
    vim.api.nvim_buf_set_lines(bufnr, ranges[r][1] - 1, ranges[r][2], false, {})
  end
end

local function extract_unpushed_commits(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local commits, seen, ranges = {}, {}, {}
  local found = false
  local i = 1

  while i <= #lines do
    if lines[i]:match('^Unpushed .+ %(%d+%+?%)$') then
      found = true
      local start_idx = i
      if start_idx > 1 and lines[start_idx - 1] == '' then start_idx = start_idx - 1 end

      local end_idx = i
      while end_idx < #lines and lines[end_idx + 1]:match('^%x+%s') do
        end_idx = end_idx + 1
        local line = lines[end_idx]
        local hash = line:match('^(%x+)%s')
        if hash and not seen[hash] then
          seen[hash] = true
          table.insert(commits, line)
        end
      end
      table.insert(ranges, { start_idx, end_idx })
      i = end_idx + 1
    else
      i = i + 1
    end
  end

  for r = #ranges, 1, -1 do
    vim.api.nvim_buf_set_lines(bufnr, ranges[r][1] - 1, ranges[r][2], false, {})
  end
  return commits, found
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

local function find_insert_point(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i = #lines, 1, -1 do
    if lines[i] ~= '' then return i + 1 end
  end
  return #lines + 1
end

local function refresh_status_sections(bufnr, ns_worktree, ns_stash, ns_pr)
  if not utils.is_valid_buf(bufnr) then return end
  local work_tree = utils.get_buf_work_tree(bufnr)
  if not work_tree then return end

  local worktree_summary = worktree.get_summary(work_tree)
  local stash_list = utils.get_stash_list(work_tree)

  local commit_scope = commit_scope_by_buf[bufnr] or 'unpushed'
  local pull_requests = pull_requests_by_buf[bufnr]

  local function build_final_lines(commit_lines)
    local final_lines = {}
    table.insert(final_lines, '')
    local commit_header = commit_scope == 'recent'
      and ('Commits [latest 15+] (%d)'):format(#commit_lines)
      or ('Unpushed [only] (%d)'):format(#commit_lines)
    table.insert(final_lines, commit_header)
    for _, l in ipairs(commit_lines) do table.insert(final_lines, l) end

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
    return final_lines
  end

  utils.with_buf_modifiable(bufnr, function()
    -- Update buffer contents
    local had_custom_commit_section = false
    for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
      if line:match('^Unpushed %[only%]') or line:match('^Commits %[') then
        had_custom_commit_section = true
        break
      end
    end
    local unpushed_commits, found_unpushed = extract_unpushed_commits(bufnr)
    if found_unpushed or not had_custom_commit_section then
      unpushed_commits_by_buf[bufnr] = unpushed_commits
    end
    remove_custom_sections(bufnr)

    local commit_lines = unpushed_commits_by_buf[bufnr] or {}
    if commit_scope == 'recent' and #commit_lines < 15 then
      commit_lines = recent_commit_lines(work_tree, 15)
    end
    local final_lines = build_final_lines(commit_lines)
    if #final_lines > 0 then
      local insert_idx = find_insert_point(bufnr)
      vim.api.nvim_buf_set_lines(bufnr, insert_idx - 1, insert_idx - 1, false, final_lines)
    end

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

local function get_worktree_path_at_cursor()
  local line = vim.api.nvim_get_current_line()
  return line:match('^(%S+)')
end

local function status_entry_at_cursor()
  local line = vim.api.nvim_get_current_line()
  local status, path = line:match('^([MADRCU?!][MADRCU?!]?) (.+)$')
  if not status then return nil, nil end
  local _, new_path = path:match('^(.+) %-> (.+)$')
  return status, new_path or path
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
  local alt = vim.fn.win_getid(vim.fn.winnr('#'))
  if alt and alt ~= 0 and alt ~= status_win and vim.api.nvim_win_is_valid(alt) then
    local alt_buf = vim.api.nvim_win_get_buf(alt)
    if vim.bo[alt_buf].filetype ~= 'fugitive' then
      return alt
    end
  end

  local fallback = nil
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= status_win and vim.api.nvim_win_is_valid(win) then
      local win_buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[win_buf].filetype ~= 'fugitive' then
        return win
      end
      fallback = fallback or win
    end
  end
  return fallback
end

local function fugitive_edit_command_at_cursor()
  local mapping = vim.fn.maparg('<Plug>fugitive:<cr>', 'n', false, true)
  local sid = tonumber(mapping.sid)
  if not sid or sid == 0 then
    return nil, 'Fugitive <CR> mapping not found'
  end

  local gf = vim.fn['<SNR>' .. sid .. '_GF']
  local ok, cmd = pcall(gf, 'edit')
  if not ok then
    return nil, tostring(cmd)
  end
  if type(cmd) ~= 'string' or cmd == '' then
    return nil, 'No file found at cursor'
  end
  return cmd
end

local function open_entry_and_close_status(bufnr)
  if not utils.is_valid_buf(bufnr) then return end

  local status_win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(status_win) ~= bufnr then
    status_win = vim.fn.bufwinid(bufnr)
  end
  if status_win == -1 or not vim.api.nvim_win_is_valid(status_win) then
    vim.notify('Status window not found', vim.log.levels.WARN)
    return
  end

  local target_win = preferred_target_window(status_win)
  local opened_in_other_window = target_win and vim.api.nvim_win_is_valid(target_win) and target_win ~= status_win

  local result = vim.api.nvim_win_call(status_win, function()
    local cmd, err = fugitive_edit_command_at_cursor()
    if not cmd then
      return { ok = false, err = err }
    end

    local ok, exec_err = pcall(function()
      vim.cmd(cmd)
    end)
    if not ok then
      return { ok = false, err = tostring(exec_err) }
    end

    return {
      ok = true,
      bufnr = vim.api.nvim_get_current_buf(),
      view = vim.fn.winsaveview(),
    }
  end)

  if not result.ok then
    vim.notify(result.err, vim.log.levels.WARN)
    return
  end

  local resolved_target_win = type(target_win) == 'number' and target_win or nil
  if opened_in_other_window
    and vim.api.nvim_win_is_valid(status_win)
    and resolved_target_win
    and vim.api.nvim_win_is_valid(resolved_target_win)
    and type(result.bufnr) == 'number'
    and result.view
  then
    vim.api.nvim_win_set_buf(resolved_target_win, result.bufnr)
    pcall(function()
      vim.api.nvim_win_call(resolved_target_win, function()
        vim.fn.winrestview(result.view)
      end)
    end)
    pcall(vim.api.nvim_win_close, status_win, false)
    if vim.api.nvim_win_is_valid(resolved_target_win) then
      vim.api.nvim_set_current_win(resolved_target_win)
    end
  end
end

function M.setup(group)
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'fugitive',
    callback = function(ev)
      local b = ev.buf
      utils.set_buf_work_tree(b, utils.get_work_tree({ bufnr = b }))
      vim.opt_local.number, vim.opt_local.relativenumber = false, false
      local ns_stash = vim.api.nvim_create_namespace('fugitive_status_stash')
      local ns_worktree = vim.api.nvim_create_namespace('fugitive_status_worktree')
      local ns_pr = vim.api.nvim_create_namespace('fugitive_status_pull_requests')
      local ns_id = vim.api.nvim_create_namespace('fugitive_status_icons')
      local pr_fetching, pr_fetch_pending = false, false
      pull_request_scope_by_buf[b] = pull_request_scope_by_buf[b] or 'branch'
      commit_scope_by_buf[b] = commit_scope_by_buf[b] or 'unpushed'

      local function refresh()
        refresh_status_sections(b, ns_worktree, ns_stash, ns_pr)
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
        if vim.b[b].fugitive_status_reloading then
          vim.schedule(refresh)
          fetch_pull_requests()
          return
        end
        vim.b[b].fugitive_status_reloading = true
        if vim.fn.exists('*fugitive#ReloadStatus') == 1 then
          pcall(vim.api.nvim_buf_call, b, function()
            vim.fn['fugitive#ReloadStatus']()
          end)
        end
        vim.b[b].fugitive_status_reloading = false
        vim.schedule(refresh)
        fetch_pull_requests()
      end

      local function notify_repo_changed()
        utils.fire_fugitive_changed({ bufnr = b })
      end

      vim.schedule(function()
        refresh()
        fetch_pull_requests()
      end)

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
        pull_requests_by_buf[b] = nil
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

      local function apply_icons()
        if not utils.is_valid_buf(b) then return end
        vim.api.nvim_buf_clear_namespace(b, ns_id, 0, -1)
        local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
        for idx, line in ipairs(lines) do
          if line:match('^Staged') then
            vim.api.nvim_buf_set_extmark(b, ns_id, idx - 1, 0, { end_col = 6, hl_group = 'GitSignsAdd' })
          elseif line:match('^Unpulled') then
            vim.api.nvim_buf_set_extmark(b, ns_id, idx - 1, 0, { end_col = 8, hl_group = 'GitSignsChange' })
          elseif line:match('^Untracked') then
            vim.api.nvim_buf_set_extmark(b, ns_id, idx - 1, 0, { end_col = 9, hl_group = 'GitSignsDelete' })
          end

          local filepath = line:match('^[MADRCU?!][MADRCU?!]? (.+)$')
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
      end
      apply_icons()

      local function perform_continue()
        local git_dir = vim.fn.FugitiveGitDir()
        if not git_dir or git_dir == '' then return end
        if vim.fn.isdirectory(git_dir .. "/rebase-merge") == 1 or vim.fn.isdirectory(git_dir .. "/rebase-apply") == 1 then vim.cmd("Git rebase --continue")
        elseif vim.fn.filereadable(git_dir .. "/CHERRY_PICK_HEAD") == 1 then vim.cmd("Git cherry-pick --continue")
        elseif vim.fn.filereadable(git_dir .. "/MERGE_HEAD") == 1 then vim.cmd("Git merge --continue")
        elseif vim.fn.filereadable(git_dir .. "/REVERT_HEAD") == 1 then vim.cmd("Git revert --continue")
        else vim.notify("No operation in progress.", vim.log.levels.WARN) end
      end

      local function perform_skip()
        local git_dir = vim.fn.FugitiveGitDir()
        if not git_dir or git_dir == '' then return end
        if vim.fn.isdirectory(git_dir .. "/rebase-merge") == 1 or vim.fn.isdirectory(git_dir .. "/rebase-apply") == 1 then vim.cmd("Git rebase --skip")
        elseif vim.fn.filereadable(git_dir .. "/CHERRY_PICK_HEAD") == 1 then vim.cmd("Git cherry-pick --skip")
        elseif vim.fn.filereadable(git_dir .. "/REVERT_HEAD") == 1 then vim.cmd("Git revert --skip")
        else vim.notify("Skip not applicable.", vim.log.levels.WARN) end
      end

      local function perform_abort()
        local git_dir = vim.fn.FugitiveGitDir()
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
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Plug>fugitive:cw", true, false, true), 'm', true)
      end, { buffer = b, nowait = true, silent = true, desc = "Reword commit or rename stash" })

      vim.keymap.set('n', 'A', function()
        if is_cursor_in_stash_area() then
          local r = get_stash_ref_at_cursor(b)
          if r then vim.cmd('Git stash apply ' .. r); notify_repo_changed() end
          return
        end
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Plug>fugitive:ce", true, false, true), 'm', true)
      end, { buffer = b, nowait = true, silent = true })

      vim.keymap.set('n', 'P', function()
        if is_cursor_in_stash_area() then
          local r = get_stash_ref_at_cursor(b)
          if r then vim.cmd('Git stash pop ' .. r); notify_repo_changed() end
          return
        end
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Plug>fugitive:P", true, false, true), 'm', true)
      end, { buffer = b, nowait = true, silent = true })

      vim.keymap.set('n', 'X', function()
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
        if delete_untracked_directory_at_cursor() then
          notify_repo_changed()
          return
        end
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Plug>fugitive:X", true, false, true), 'm', true)
      end, { buffer = b, nowait = true, silent = true })

      vim.keymap.set('n', '<CR>', function()
        if is_cursor_on_commit_header() then
          toggle_commit_scope()
          return
        end
        if is_cursor_on_pull_request_header() then
          toggle_pull_request_scope()
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
          local cur_match = cur_line:match('^[MADRCU?!][MADRCU?!]? (.+)$')
          if cur_match then
            local _, new = cur_match:match('^(.+) %-> (.+)$')
            cur_match = new or cur_match
          end
          if abs and cur_match == f and vim.fn.isdirectory(abs) == 1 then
            pcall(function()
              vim.cmd('Oil ' .. vim.fn.fnameescape(abs))
            end)
            return
          end
        end
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Plug>fugitive:<cr>", true, false, true), 'm', true)
      end, { buffer = b, nowait = true, silent = true })

      vim.keymap.set('n', 'gS', function()
        if is_cursor_on_commit_header() then
          select_commit_scope()
        elseif is_cursor_on_pull_request_header() then
          select_pull_request_scope()
        else
          vim.notify('No selectable scope at cursor', vim.log.levels.WARN)
        end
      end, { buffer = b, nowait = true, silent = true, desc = 'Select status section scope' })

      vim.keymap.set('n', 'gf', function()
        open_entry_and_close_status(b)
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

      vim.keymap.set('n', 'R', function() vim.cmd('e!'); vim.cmd('normal gU') end, { buffer = b, silent = true })

      -- cf: Fixup/Reword commit under cursor with index
      vim.keymap.set('n', 'cf', function()
        local l = vim.api.nvim_get_current_line()
        local h = l:match('^(%x+)')
        if not h then vim.notify('No commit found at cursor', vim.log.levels.WARN) return end
        commands.mix_index_with_input(h)
      end, { buffer = b, nowait = true, silent = true, desc = 'Fixup/Reword commit under cursor with index' })

      -- <Leader>cf: Squash commit under cursor into its parent (Fixup)
      vim.keymap.set('n', '<Leader>cf', function()
        local l = vim.api.nvim_get_current_line()
        local h = l:match('^(%x+)')
        if not h then vim.notify('No commit found at cursor', vim.log.levels.WARN) return end
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

      -- d: Open file diff in new tab
      vim.keymap.set('n', 'd', function()
        local file_path = utils.get_filepath_at_cursor(b)
        if not file_path then vim.notify('No file found at cursor', vim.log.levels.WARN) return end

        local target_line = nil
        local current_line_idx = vim.api.nvim_win_get_cursor(0)[1]
        local hunk_line = nil

        for lnum = current_line_idx, 1, -1 do
          local line = vim.api.nvim_buf_get_lines(b, lnum - 1, lnum, false)[1]
          if line then
            local line_num = line:match('^@@ %-(%d+)')
            if line_num then
              hunk_line = lnum
              target_line = tonumber(line_num)
              break
            end
            if line:match('^[MADRCU?!][MADRCU?!]? (.+)$') then break end
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

        local fugitive_path = vim.fn.FugitiveFind(':' .. file_path)
        vim.cmd('tabedit ' .. vim.fn.fnameescape(fugitive_path))

        vim.schedule(function()
          vim.cmd('Gvdiffsplit')
          if target_line then
            vim.schedule(function()
              local buf_line_count = vim.api.nvim_buf_line_count(0)
              target_line = math.min(target_line, buf_line_count)
              vim.api.nvim_win_set_cursor(0, { target_line, 0 })
              vim.cmd('normal! zz')
            end)
          end
        end)
      end, { buffer = b, nowait = true, silent = true, desc = 'Open file diff in new tab' })

      -- Load syntax
      syntax_highlight.attach(b)

      -- <Leader>wd: Toggle word diff style
      vim.keymap.set('n', '<Leader>wd', function()
        local new_style = syntax_highlight.cycle_word_diff_style()
        vim.notify('Word diff style: ' .. new_style, vim.log.levels.INFO)
      end, { buffer = b, silent = true, desc = 'Toggle word diff style (diffs/lazygit/github)' })
    end,
  })
end

function M.refresh_buffer(bufnr)
  if not utils.is_valid_buf(bufnr) then return end
  local ns_worktree = vim.api.nvim_create_namespace('fugitive_status_worktree')
  local ns_stash = vim.api.nvim_create_namespace('fugitive_status_stash')
  local ns_pr = vim.api.nvim_create_namespace('fugitive_status_pull_requests')
  pcall(function()
    refresh_status_sections(bufnr, ns_worktree, ns_stash, ns_pr)
  end)
end

function M.reload_buffer(bufnr)
  if not utils.is_valid_buf(bufnr) then return end
  if vim.b[bufnr].fugitive_status_reloading then
    vim.schedule(function()
      M.refresh_buffer(bufnr)
    end)
    return
  end
  vim.b[bufnr].fugitive_status_reloading = true
  if vim.fn.exists('*fugitive#ReloadStatus') == 1 then
    pcall(vim.api.nvim_buf_call, bufnr, function()
      vim.fn['fugitive#ReloadStatus']()
    end)
  end
  vim.b[bufnr].fugitive_status_reloading = false
  vim.schedule(function()
    M.refresh_buffer(bufnr)
  end)
end

function M.refresh_all()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if utils.is_valid_buf(bufnr) and vim.bo[bufnr].filetype == 'fugitive' then
      M.refresh_buffer(bufnr)
    end
  end
end

return M

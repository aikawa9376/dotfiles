---@diagnostic disable: undefined-global

local M = {}
local utils = require("git.utils")
local commands = require("git.features.commands")
local help = require("git.features.help")
local branch_spin = require('git.features.branch_spin')
local github_open = require('git.features.github_open')

local branch_name_ns = vim.api.nvim_create_namespace("fugitive_branch_names")
local branch_fade_ns = vim.api.nvim_create_namespace("fugitive_branch_fade")
local branch_filter_ns = vim.api.nvim_create_namespace('fugitive_branch_filter')
local filters = { all = 'All', local_ = 'Local', remote = 'Remote', tags = 'Tags' }

local function notify_branch_changed(bufnr, work_tree)
  utils.fire_fugitive_changed({
    bufnr = bufnr,
    work_tree = work_tree,
  })
end

local function get_buffer_work_tree(bufnr, notify)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local work_tree = utils.get_buf_work_tree(bufnr)
  if work_tree then
    return work_tree
  end
  return utils.get_work_tree({ bufnr = bufnr, notify = notify })
end

local function get_git_prefix(bufnr, notify)
  local work_tree = get_buffer_work_tree(bufnr, notify)
  if not work_tree then
    return nil, nil
  end
  return 'git -C ' .. vim.fn.shellescape(work_tree) .. ' ', work_tree
end

---@diagnostic disable-next-line: unused-vararg
_G.fugitive_branch_completion = function(arg_lead, ...)
  local git = get_git_prefix(vim.api.nvim_get_current_buf())
  if not git then return {} end
  local branches = vim.fn.systemlist(git .. "branch -a --format='%(refname:short)'")
  if vim.v.shell_error ~= 0 then return {} end
  local matches = {}
  for _, b in ipairs(branches) do
    if b:match(arg_lead) then
      table.insert(matches, b)
    end
  end
  return matches
end

local function get_branch_list(bufnr, filter)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local cmd_prefix = get_git_prefix(bufnr)
  if not cmd_prefix then
    return {}, {}, {}, false, {}
  end

  filter = filter or vim.b[bufnr].branch_filter or 'all'
  local local_branches, remote_branches, tags = {}, {}, {}
  if filter == 'all' or filter == 'local_' then
    local_branches = vim.fn.systemlist(cmd_prefix .. "for-each-ref --sort=-committerdate --format='%(HEAD)|%(refname:lstrip=2)|%(upstream:short)|%(upstream:track)|%(committerdate:relative)|%(authorname)|%(contents:subject)' refs/heads/")
    if vim.v.shell_error ~= 0 then return {}, {}, {}, false, {} end
  end
  if filter == 'all' or filter == 'remote' then
    remote_branches = vim.fn.systemlist(cmd_prefix .. "for-each-ref --sort=-committerdate --format='%(symref)|%(HEAD)|%(refname:lstrip=2)|%(upstream:short)|%(upstream:track)|%(committerdate:relative)|%(authorname)|%(contents:subject)' refs/remotes/")
    if vim.v.shell_error ~= 0 then return {}, {}, {}, false, {} end
  end
  if filter == 'all' or filter == 'tags' then
    tags = vim.fn.systemlist(cmd_prefix .. "for-each-ref --sort=-creatordate --format=' |%(refname:lstrip=2)|||%(creatordate:relative)|%(authorname)|%(contents:subject)' refs/tags/")
    if vim.v.shell_error ~= 0 then return {}, {}, {}, false, {} end
  end

  local raw_branches = {}
  if filter == 'all' or filter == 'local_' then
    for _, line in ipairs(local_branches) do
      raw_branches[#raw_branches + 1] = { line = line, kind = 'local_' }
    end
  end
  if filter == 'all' or filter == 'remote' then
    for _, line in ipairs(remote_branches) do
      local symref, fields = line:match('^([^|]*)|(.*)$')
      if symref == '' then
        raw_branches[#raw_branches + 1] = { line = fields, kind = 'remote' }
      end
    end
  end
  if filter == 'all' or filter == 'tags' then
    for _, line in ipairs(tags) do
      raw_branches[#raw_branches + 1] = { line = line, kind = 'tags' }
    end
  end

  -- First pass: collect all data
  local branches = {}
  local max_branch_len = 0
  local max_subject_len = 0
  local max_date_len = 0
  local max_author_len = 0

  for _, ref in ipairs(raw_branches) do
    local head, branch, upstream, track, date, author, subject = ref.line:match('^([* ]?)|(.-)|(.-)|(.-)|(.-)|(.-)|(.*)')
    if branch then
      local ahead, behind = 0, 0
      if ref.kind == 'local_' then
        ahead = tonumber(track:match('ahead%s+(%d+)')) or 0
        behind = tonumber(track:match('behind%s+(%d+)')) or 0
      end

      local push_info = ''
      if behind > 0 then
        push_info = push_info .. string.format('↓%d', behind)
      end
      if ahead > 0 then
        push_info = push_info .. string.format('↑%d', ahead)
      end

      local upstream_str = upstream ~= '' and string.format('[%s]', upstream) or ''

      -- Shorten relative date
      date = date:gsub(',.*', '') -- Keep only the first part
      date = date:gsub(' ago', '')
      date = date:gsub(' years?', 'y')
      date = date:gsub(' months?', 'mo')
      date = date:gsub(' weeks?', 'w')
      date = date:gsub(' days?', 'd')
      date = date:gsub(' hours?', 'h')
      date = date:gsub(' minutes?', 'm')
      date = date:gsub(' seconds?', 's')

      table.insert(branches, {
        kind = ref.kind,
        head = head == '*' and '* ' or '  ',
        branch = branch,
        push_info = push_info,
        subject = subject,
        upstream_str = upstream_str,
        date = date,
        author = author,
      })

      max_branch_len = math.max(max_branch_len, vim.fn.strdisplaywidth(branch))
      max_subject_len = math.max(max_subject_len, vim.fn.strdisplaywidth(subject))
      max_date_len = math.max(max_date_len, vim.fn.strdisplaywidth(date))
      max_author_len = math.max(max_author_len, vim.fn.strdisplaywidth(author))
    end
  end

  -- Second pass: format with calculated widths
  -- Cap widths to avoid string.format limits (max 99)
  max_branch_len = math.min(max_branch_len, 40)
  max_subject_len = 40  -- Fixed width for subject
  max_date_len = math.min(max_date_len, 6)
  max_author_len = math.min(max_author_len, 15)

  -- Helper function to pad string based on display width and truncate if necessary
  local function pad_right(str, width, truncate_mode)
    local display_width = vim.fn.strdisplaywidth(str)

    if display_width > width then
      -- Truncate string to fit width
      local truncated = ''
      local current_width = 0

      -- If width is very small, we might just return empty or partial
      if width <= 3 then
         local chars = vim.fn.split(str, '\\zs')
         for _, char in ipairs(chars) do
            local w = vim.fn.strdisplaywidth(char)
            if current_width + w > width then break end
            truncated = truncated .. char
            current_width = current_width + w
         end
         return truncated .. string.rep(' ', width - current_width), truncate_mode or 'right', #truncated
      end

      local chars = vim.fn.split(str, '\\zs')

      if truncate_mode == 'left' then
        -- Truncate from left: "ong-branch-name" (no ellipsis)
        local collected = {}
        for i = #chars, 1, -1 do
          local char = chars[i]
          local char_width = vim.fn.strdisplaywidth(char)
          if current_width + char_width > width then
            break
          end
          table.insert(collected, 1, char)
          current_width = current_width + char_width
        end
        return table.concat(collected) .. string.rep(' ', width - current_width), 'left', #table.concat(collected)
      elseif truncate_mode == 'right' then
        -- Truncate from right: "long-branch-na" (no ellipsis)
        for _, char in ipairs(chars) do
          local char_width = vim.fn.strdisplaywidth(char)
          if current_width + char_width > width then
            break
          end
          truncated = truncated .. char
          current_width = current_width + char_width
        end
        return truncated .. string.rep(' ', width - current_width), 'right', #truncated
      else
        -- Truncate from right (legacy/default): "long-branch..." (with ellipsis)
        local target_width = width - 3
        for _, char in ipairs(chars) do
          local char_width = vim.fn.strdisplaywidth(char)
          if current_width + char_width > target_width then
            break
          end
          truncated = truncated .. char
          current_width = current_width + char_width
        end
        return truncated .. '...' .. string.rep(' ', width - (current_width + 3)), nil, #truncated + 3
      end
    elseif display_width == width then
      return str, nil, #str
    else
      return str .. string.rep(' ', width - display_width), nil, #str
    end
  end

  local formatted = {}
  local truncated_info = {}
  for _, b in ipairs(branches) do
    -- Combine branch name with push info
    local branch_block = b.branch
    if b.push_info ~= '' then
      branch_block = branch_block .. ' ' .. b.push_info
    end

    local subject = b.subject
    local branch_str, truncated_branch_mode, branch_content_len = pad_right(branch_block, max_branch_len, 'left')
    local date_str, _ = pad_right(b.date, max_date_len)
    local author_str, truncated_author_mode, author_content_len = pad_right(b.author, max_author_len, 'right')
    local subject_str, truncated_subject_mode, subject_content_len = pad_right(subject, max_subject_len, 'right')

    local line = b.head .. branch_str .. '  ' .. date_str .. '  ' .. author_str .. '  ' .. subject_str

    -- Add upstream if exists, otherwise trim trailing spaces
    if b.upstream_str ~= '' then
      line = line .. '  ' .. b.upstream_str
    else
      line = line:gsub('%s+$', '')
    end
    table.insert(formatted, line)

    if truncated_branch_mode then
      table.insert(truncated_info, {
        line = #formatted - 1, -- 0-indexed
        col_start = #b.head,
        text_len = branch_content_len,
        mode = truncated_branch_mode
      })
    end

    if truncated_author_mode then
      -- head + branch + 2 spaces + date + 2 spaces
      local author_col = #b.head + #branch_str + 2 + #date_str + 2
      table.insert(truncated_info, {
        line = #formatted - 1,
        col_start = author_col,
        text_len = author_content_len,
        mode = truncated_author_mode
      })
    end

    if truncated_subject_mode then
      -- head + branch + 2 spaces + date + 2 spaces + author + 2 spaces
      local subject_col = #b.head + #branch_str + 2 + #date_str + 2 + #author_str + 2
      table.insert(truncated_info, {
        line = #formatted - 1,
        col_start = subject_col,
        text_len = subject_content_len,
        mode = truncated_subject_mode
      })
    end
  end

  local branch_names = {}
  local branch_kinds = {}
  for i, b in ipairs(branches) do
    branch_names[i] = b.branch
    branch_kinds[i] = b.kind
  end

  return formatted, branch_names, truncated_info, true, branch_kinds
end

local function apply_fade_highlight(bufnr, truncated_info)
  vim.api.nvim_buf_clear_namespace(bufnr, branch_fade_ns, 0, -1)

  for _, info in ipairs(truncated_info or {}) do
    local line = info.line
    local col = info.col_start
    local len = info.text_len
    local mode = info.mode

    if mode == 'left' then
      -- Apply fade effect to the first few characters (left side)
      -- 1st char: Very faint (NonText)
      vim.api.nvim_buf_set_extmark(bufnr, branch_fade_ns, line, col, {
        end_col = col + 1,
        hl_group = "NonText",
        priority = 110,
      })

      -- 2nd char: Faint (Comment)
      vim.api.nvim_buf_set_extmark(bufnr, branch_fade_ns, line, col + 1, {
        end_col = col + 2,
        hl_group = "Comment",
        priority = 110,
      })
    elseif mode == 'right' then
      -- Apply fade effect to the last few characters (right side)
      local line_content = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1]
      local line_len = line_content and #line_content or 0
      local end_col = math.min(col + len, line_len)

      -- Last char: Very faint (NonText)
      if end_col > 0 then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, branch_fade_ns, line, end_col - 1, {
          end_col = end_col,
          hl_group = "NonText",
          priority = 110,
        })
      end

      -- 2nd to last char: Faint (Comment)
      if end_col > 1 then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, branch_fade_ns, line, end_col - 2, {
          end_col = end_col - 1,
          hl_group = "Comment",
          priority = 110,
        })
      end
    end
  end
end

local function apply_branch_highlight(bufnr)
  if not utils.is_valid_buf(bufnr) then return end

  vim.api.nvim_set_hl(0, "FugitiveBranchName", { link = "Directory", default = true })
  vim.api.nvim_set_hl(0, "FugitiveBranchCurrent", { link = "String", default = true })
  vim.api.nvim_set_hl(0, "FugitiveBranchTag", { link = "Special", default = true })
  vim.api.nvim_buf_clear_namespace(bufnr, branch_name_ns, 0, -1)

  for lnum, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local _, prefix_end = line:find("^%s*%*?%s*")
    local branch = line:match("^%s*%*?%s*(%S+)")
    if prefix_end and branch then
      vim.api.nvim_buf_set_extmark(bufnr, branch_name_ns, lnum - 1, prefix_end, {
        end_col = prefix_end + #branch,
        hl_group = (vim.b[bufnr].branch_kinds or {})[lnum] == 'tags' and 'FugitiveBranchTag'
          or line:match("^%s*%*") and "FugitiveBranchCurrent" or "FugitiveBranchName",
        priority = 80,
      })
    end
  end
end

local function get_branch_name_from_line()
  local bufnr = vim.api.nvim_get_current_buf()
  local row = vim.fn.line('.')
  if (vim.b[bufnr].branch_kinds or {})[row] == 'tags' then return nil end
  return (vim.b[bufnr].branch_map or {})[row]
end

local function get_ref_at_cursor(bufnr)
  local row = vim.fn.line('.')
  local name = (vim.b[bufnr].branch_map or {})[row]
  if not name then return nil end
  if (vim.b[bufnr].branch_kinds or {})[row] == 'tags' then
    return 'refs/tags/' .. name
  end
  return name
end

_G.fugitive_upstream_completion = function(arg_lead)
  local work_tree = get_buffer_work_tree(vim.api.nvim_get_current_buf())
  if not work_tree then return {} end
  local result = vim.system({ 'git', 'for-each-ref', '--format=%(refname:short)',
    'refs/heads', 'refs/remotes' }, { cwd = work_tree, text = true }):wait()
  if result.code ~= 0 then return {} end
  local current = get_branch_name_from_line()
  local matches = {}
  for branch in (result.stdout or ''):gmatch('[^\n]+') do
    if branch ~= current and not branch:match('/HEAD$')
      and branch:sub(1, #arg_lead) == arg_lead then
      matches[#matches + 1] = branch
    end
  end
  table.sort(matches)
  return matches
end

local function refresh_branch_list(bufnr)
  if not utils.is_valid_buf(bufnr) then return end

  local branch_output, branch_names, truncated_info, _, branch_kinds = get_branch_list(bufnr)
  local old_row = vim.fn.line('.')
  local selected = (vim.b[bufnr].branch_map or {})[old_row]
  local selected_kind = (vim.b[bufnr].branch_kinds or {})[old_row]
  utils.with_buf_modifiable(bufnr, function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, branch_output)
    vim.b[bufnr].branch_map = branch_names
    vim.b[bufnr].branch_kinds = branch_kinds
    apply_fade_highlight(bufnr, truncated_info)
    apply_branch_highlight(bufnr)
  end)
  vim.bo[bufnr].modifiable = false
  if vim.api.nvim_get_current_buf() == bufnr then
    for row, name in ipairs(branch_names) do
      if name == selected and branch_kinds[row] == selected_kind then
        vim.api.nvim_win_set_cursor(0, { row, 0 })
        return
      end
    end
    vim.api.nvim_win_set_cursor(0, { math.min(old_row, math.max(#branch_names, 1)), 0 })
  end
end

local function upstream_branch_at_cursor(bufnr)
  local branch = get_branch_name_from_line()
  if not branch then
    vim.notify('No branch found on this line', vim.log.levels.WARN)
    return nil
  end
  if (vim.b[bufnr].branch_kinds or {})[vim.fn.line('.')] ~= 'local_' then
    vim.notify('Select a local branch to change its upstream', vim.log.levels.WARN)
    return nil
  end
  local work_tree = get_buffer_work_tree(bufnr, true)
  if not work_tree then return nil end
  local local_ref = vim.system({ 'git', 'show-ref', '--verify', '--quiet',
    'refs/heads/' .. branch }, { cwd = work_tree, text = true }):wait()
  if local_ref.code ~= 0 then
    vim.notify('Select a local branch to change its upstream', vim.log.levels.WARN)
    return nil
  end
  return branch, work_tree
end

local function change_upstream(bufnr, unset)
  local branch, work_tree = upstream_branch_at_cursor(bufnr)
  if not branch then return end
  local current_result = vim.system({ 'git', 'rev-parse', '--abbrev-ref', '--symbolic-full-name',
    branch .. '@{upstream}' }, { cwd = work_tree, text = true }):wait()
  local current = current_result.code == 0 and vim.trim(current_result.stdout or '') or ''
  local args, target
  if unset then
    local configured = vim.system({ 'git', 'config', '--get', 'branch.' .. branch .. '.merge' },
      { cwd = work_tree, text = true }):wait()
    if configured.code ~= 0 then
      vim.notify(branch .. ' has no upstream', vim.log.levels.INFO)
      return
    end
    args = { 'git', 'branch', '--unset-upstream', branch }
  else
    target = vim.fn.input('Upstream for ' .. branch .. ': ', current,
      'customlist,v:lua.fugitive_upstream_completion')
    vim.cmd('redraw')
    target = vim.trim(target or '')
    if target == '' or target == current then return end
    args = { 'git', 'branch', '--set-upstream-to=' .. target, branch }
  end
  local result = vim.system(args, { cwd = work_tree, text = true }):wait()
  if result.code ~= 0 then
    local message = vim.trim(result.stderr or '')
    vim.notify(message ~= '' and message or 'Could not update upstream', vim.log.levels.ERROR)
    return
  end
  refresh_branch_list(bufnr)
  notify_branch_changed(bufnr, work_tree)
  vim.notify(('Upstream for %s: %s'):format(branch, unset and 'none' or target),
    vim.log.levels.INFO)
end


local function delete_branches(bufnr, branches)
  if #branches == 0 then
    vim.notify("No branches to delete", vim.log.levels.WARN)
    return
  end

  local branch_list = table.concat(branches, ", ")
  local confirm = vim.fn.confirm(
    string.format("Delete %d branch(es)?\n%s", #branches, branch_list),
    "&Yes\n&No",
    2
  )

  if confirm ~= 1 then
    return
  end

  local git, work_tree = get_git_prefix(bufnr, true)
  if not git then return end

  local deleted = {}
  local failed = {}

  for _, branch in ipairs(branches) do
    -- Skip current branch (with *)
    if branch:match('^%*') then
      table.insert(failed, branch .. " (current branch)")
    else
      -- Try to delete branch
      local result = vim.fn.system(git .. 'branch -d ' .. vim.fn.shellescape(branch) .. ' 2>&1')
      if vim.v.shell_error ~= 0 then
        -- If normal delete fails, ask for force delete
        if result:match("not fully merged") then
          local force_confirm = vim.fn.confirm(
            string.format("Branch '%s' is not fully merged. Force delete?", branch),
            "&Yes\n&No",
            2
          )
          if force_confirm == 1 then
            result = vim.fn.system(git .. 'branch -D ' .. vim.fn.shellescape(branch) .. ' 2>&1')
            if vim.v.shell_error == 0 then
              table.insert(deleted, branch)
            else
              table.insert(failed, branch .. " (" .. result:gsub("\n", "") .. ")")
            end
          else
            table.insert(failed, branch .. " (cancelled)")
          end
        else
          table.insert(failed, branch .. " (" .. result:gsub("\n", "") .. ")")
        end
      else
        table.insert(deleted, branch)
      end
    end
  end

  -- Show results
  if #failed > 0 then
    vim.notify(string.format("Failed: %s", table.concat(failed, ", ")), vim.log.levels.WARN)
  end

  notify_branch_changed(bufnr, work_tree)
end

local function checkout_branch(bufnr)
  local branch = get_branch_name_from_line()
  if not branch then
    vim.notify("No branch found on this line", vim.log.levels.WARN)
    return
  end

  -- Remove remotes/ prefix if present
  local checkout_name = branch:gsub('^origin/', '')

  local work_tree = get_buffer_work_tree(bufnr, true)
  if not work_tree then return end

  local stashed = commands.apply_auto_stash(work_tree)
  if stashed == nil then return end

  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd('Git checkout ' .. vim.fn.fnameescape(checkout_name))
  end)

  if stashed then
    commands.pop_auto_stash(work_tree)
  end

  notify_branch_changed(bufnr)
end

local function rename_branch(bufnr)
  local old_name = get_branch_name_from_line()
  if not old_name then
    vim.notify("No branch found on this line", vim.log.levels.WARN)
    return
  end

  -- Can't rename remote branches directly.
  if (vim.b[bufnr].branch_kinds or {})[vim.fn.line('.')] ~= 'local_' then
    vim.notify("Cannot rename remote branches directly.", vim.log.levels.WARN)
    return
  end

  local new_name = vim.fn.input('Rename ' .. old_name .. ' to: ', old_name)
  vim.cmd('redraw') -- Clear the prompt.

  if new_name == nil or new_name == '' or new_name == old_name then
    -- vim.notify("Rename cancelled.", vim.log.levels.INFO)
    return
  end

  local git, work_tree = get_git_prefix(bufnr, true)
  if not git then return end
  local cmd = git .. 'branch -m ' .. vim.fn.shellescape(old_name) .. ' ' .. vim.fn.shellescape(new_name)
  local result = vim.fn.system(cmd)

  if vim.v.shell_error ~= 0 then
    vim.notify("Failed to rename branch: " .. vim.fn.trim(result), vim.log.levels.ERROR)
  else
    notify_branch_changed(bufnr, work_tree)
  end
end

local function duplicate_branch(bufnr)
  local old_name = get_branch_name_from_line()
  if not old_name then
    vim.notify("No branch found on this line", vim.log.levels.WARN)
    return
  end

  -- Default: remove origin/ from remote branches for the default new name
  local default_new_name = old_name:gsub('^origin/', '') .. '-copy'
  local new_name = vim.fn.input('Duplicate ' .. old_name .. ' to: ', default_new_name)
  vim.cmd('redraw') -- Clear the prompt.

  if new_name == nil or new_name == '' or new_name == old_name then
    -- vim.notify("Duplicate cancelled.", vim.log.levels.INFO)
    return
  end

  -- Do not allow creating a new branch name that begins with the remote prefix
  if new_name:match('^origin/') then
    vim.notify("Please specify a local branch name (no remote prefixes).", vim.log.levels.WARN)
    return
  end

  local git, work_tree = get_git_prefix(bufnr, true)
  if not git then return end

  -- If a local branch with the target name exists, ask to overwrite
  vim.fn.system(git .. 'rev-parse --verify --quiet '
    .. vim.fn.shellescape('refs/heads/' .. new_name) .. ' 2>/dev/null')
  if vim.v.shell_error == 0 then
    local overwrite = vim.fn.confirm(
      string.format("Local branch '%s' already exists. Overwrite?", new_name),
      "&Yes\n&No",
      2
    )
    if overwrite ~= 1 then
      -- vim.notify("Duplicate cancelled.", vim.log.levels.INFO)
      return
    end
    local del_result = vim.fn.system(git .. 'branch -D ' .. vim.fn.shellescape(new_name) .. ' 2>&1')
    if vim.v.shell_error ~= 0 then
      vim.notify("Failed to delete existing branch: " .. vim.fn.trim(del_result), vim.log.levels.ERROR)
      return
    end
  end

  -- Create a new local branch pointing to the same commit as `old_name`.
  -- `old_name` may be local (e.g., "main") or remote (e.g., "origin/main")
  local cmd = git .. 'branch ' .. vim.fn.shellescape(new_name) .. ' ' .. vim.fn.shellescape(old_name) .. ' 2>&1'
  local result = vim.fn.system(cmd)

  if vim.v.shell_error ~= 0 then
    vim.notify("Failed to duplicate branch: " .. vim.fn.trim(result), vim.log.levels.ERROR)
  else
    notify_branch_changed(bufnr, work_tree)
  end
end

local function spin_branch(bufnr, mode, from)
  local work_tree = get_buffer_work_tree(bufnr, true)
  if not work_tree then return end
  local plan, err = branch_spin.plan(work_tree, mode, from)
  if not plan then vim.notify(err, vim.log.levels.ERROR); return end

  local label = mode == 'spinoff' and 'Spin off' or 'Spin out'
  local name = vim.trim(vim.fn.input(label .. ' ' .. plan.branch .. ' as: '))
  vim.cmd('redraw')
  if name == '' then return end

  if plan.base then
    local moved = plan.from and ('commits from ' .. plan.from:sub(1, 12))
      or (plan.ahead .. ' outgoing commit(s)')
    local message = ('%s %s into %s?\n%s will reset to %s.'):format(
      label, moved, name, plan.branch, plan.base:sub(1, 12))
    if mode == 'spinout' and plan.dirty then
      message = message .. '\nUncommitted changes will follow the new branch.'
    end
    if vim.fn.confirm(message, '&Spin\n&Cancel', 2) ~= 1 then return end
  end

  local result, run_err = branch_spin.run(work_tree, name, mode, plan)
  if not result then vim.notify(run_err, vim.log.levels.ERROR); return end
  notify_branch_changed(bufnr, work_tree)
  local action = result.checkout and 'checked out' or 'created'
  vim.notify(('Branch %s %s from %s'):format(name, action, result.branch), vim.log.levels.INFO)
end

local function create_worktree(bufnr)
  local branch = get_branch_name_from_line()
  if not branch then
    vim.notify("No branch found on this line", vim.log.levels.WARN)
    return
  end

  local worktree_name = branch:gsub('^origin/', '')
  local worktree_path = vim.fn.input('Worktree path for ' .. branch .. ': ', '../' .. worktree_name)
  vim.cmd('redraw') -- Clear the prompt.

  if worktree_path == nil or worktree_path == '' then
    -- vim.notify("Worktree creation cancelled.", vim.log.levels.INFO)
    return
  end

  local git, work_tree = get_git_prefix(bufnr, true)
  if not git then return end
  local cmd = git .. 'worktree add ' .. vim.fn.shellescape(worktree_path) .. ' ' .. vim.fn.shellescape(branch)
  local result = vim.fn.system(cmd)

  if vim.v.shell_error ~= 0 then
    vim.notify("Failed to create worktree: " .. vim.fn.trim(result), vim.log.levels.ERROR)
  else
    notify_branch_changed(bufnr, work_tree)
  end
end

local function fetch_all(bufnr)
  -- vim.notify("Fetching...", vim.log.levels.INFO)
  local git, work_tree = get_git_prefix(bufnr, true)
  if not git then return end
  vim.fn.jobstart(git .. "fetch --all --prune", {
    on_exit = function(_, exit_code)
      if exit_code == 0 then
        notify_branch_changed(bufnr, work_tree)
      else
        vim.notify("Fetch failed", vim.log.levels.ERROR)
      end
    end
  })
end

local function handle_pull_error(work_tree, message, args, on_success)
  if message:match("Not possible to fast%-forward") or message:match("diverged") or message:match("Need to specify how to reconcile") then
    local choice = vim.fn.confirm("Pull failed: Diverged branches.\nHow do you want to proceed?", "&Rebase\n&Merge (Commit)\n&Abort", 3)
    if choice == 1 then -- Rebase
      local cmd = "git -C " .. vim.fn.shellescape(work_tree) .. " pull --rebase" .. args
      local out = vim.fn.system(cmd)
       if vim.v.shell_error == 0 then
         vim.notify("Pull --rebase successful.", vim.log.levels.INFO)
         if on_success then on_success() end
         return true
      else
        return false, "Pull --rebase failed:\n" .. out
      end
    elseif choice == 2 then -- Merge
      local cmd = "git -C " .. vim.fn.shellescape(work_tree) .. " pull --no-ff" .. args
      local out = vim.fn.system(cmd)
       if vim.v.shell_error == 0 then
         vim.notify("Pull --no-ff successful.", vim.log.levels.INFO)
         if on_success then on_success() end
         return true
      else
        return false, "Pull --no-ff failed:\n" .. out
      end
    end
    return true -- Handled (aborted or attempted)
  end
  return false -- Not handled
end

local function pull_branch(bufnr)
  local branch = get_branch_name_from_line()
  if not branch then
    vim.notify("No branch found on this line", vim.log.levels.WARN)
    return
  end

  local git, work_tree = get_git_prefix(bufnr, true)
  if not git then return end

  -- Check if branch is current
  local current_branch = vim.fn.trim(vim.fn.system(git .. "branch --show-current"))
  if branch ~= current_branch then
    vim.notify("Cannot pull: " .. branch .. " is not checked out.", vim.log.levels.WARN)
    return
  end

  -- Check upstream
  vim.fn.system(git .. "rev-parse --abbrev-ref " .. vim.fn.shellescape(branch .. "@{u}"))
  local has_upstream = (vim.v.shell_error == 0)

  local args = ""
  if not has_upstream then
    local upstream = vim.fn.input('Pull from (e.g. origin main): ')
    vim.cmd('redraw')
    if upstream and upstream ~= '' then
       args = " " .. upstream
    else
       return
    end
  end

  local stashed = commands.apply_auto_stash(work_tree)
  if stashed == nil then return end

  -- vim.notify("Pulling...", vim.log.levels.INFO)
  local output_lines = {}
  vim.fn.jobstart(git .. "pull" .. args, {
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line and line ~= "" then
            table.insert(output_lines, line)
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line and line ~= "" then
            table.insert(output_lines, line)
          end
        end
      end
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        if stashed then commands.pop_auto_stash(work_tree) end
        local message = table.concat(output_lines, "\n")
        if exit_code == 0 then
          notify_branch_changed(bufnr, work_tree)
        else
          local handled, err_msg = handle_pull_error(work_tree, message, args, function()
             notify_branch_changed(bufnr, work_tree)
          end)
          if handled then
             if err_msg then
                vim.notify(err_msg, vim.log.levels.ERROR)
             end
          else
             vim.notify("Pull failed\n" .. message, vim.log.levels.ERROR)
          end
        end
      end)
    end
  })
end

local function pull_branch_under_cursor(bufnr)
  local branch = get_branch_name_from_line()
  if not branch then
    vim.notify("No branch found on this line", vim.log.levels.WARN)
    return
  end

  local git, work_tree = get_git_prefix(bufnr, true)
  if not git then return end

  local current_branch = vim.fn.trim(vim.fn.system(git .. "branch --show-current"))

  if branch == current_branch then
    pull_branch(bufnr)
    return
  end

  -- Check upstream
  vim.fn.system(git .. "rev-parse --abbrev-ref " .. vim.fn.shellescape(branch .. "@{u}"))
  local has_upstream = (vim.v.shell_error == 0)

  local args = ""
  if not has_upstream then
    local upstream = vim.fn.input('Pull ' .. branch .. ' from (e.g. origin main): ')
    vim.cmd('redraw')
    if upstream and upstream ~= '' then
       args = " " .. upstream
    else
       return
    end
  end

  local stashed = commands.apply_auto_stash(work_tree)
  if stashed == nil then return end

  -- Checkout target branch
  local out = vim.fn.system(git .. "checkout " .. vim.fn.shellescape(branch) .. " 2>&1")
  if vim.v.shell_error ~= 0 then
    vim.notify("Failed to checkout " .. branch .. ": " .. out, vim.log.levels.ERROR)
    if stashed then commands.pop_auto_stash(work_tree) end
    return
  end

  -- vim.notify("Pulling " .. branch .. "...", vim.log.levels.INFO)
  local output_lines = {}
  vim.fn.jobstart(git .. "pull" .. args, {
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line and line ~= "" then
            table.insert(output_lines, line)
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line and line ~= "" then
            table.insert(output_lines, line)
          end
        end
      end
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        local message = table.concat(output_lines, "\n")
        local pull_success = (exit_code == 0)

        -- Checkout back to original branch
        local co_out = vim.fn.system(git .. "checkout " .. vim.fn.shellescape(current_branch) .. " 2>&1")
        if vim.v.shell_error ~= 0 then
           vim.notify("Pull " .. (pull_success and "succeeded" or "failed") .. " but could not switch back to " .. current_branch .. "\n" .. co_out .. "\n\nPull output:\n" .. message, vim.log.levels.ERROR)
           -- Do not pop stash if we are on the wrong branch
           return
        end

        if stashed then commands.pop_auto_stash(work_tree) end

        if pull_success then
          notify_branch_changed(bufnr, work_tree)
        else
          local handled, err_msg = handle_pull_error(work_tree, message, args, function()
             notify_branch_changed(bufnr, work_tree)
          end)
          if handled then
             if err_msg then
                vim.notify(err_msg, vim.log.levels.ERROR)
             end
          else
             vim.notify("Pull failed for " .. branch .. "\n" .. message, vim.log.levels.ERROR)
          end
        end
      end)
    end
  })
end

local function get_default_origin_head(bufnr)
  local default_branch = "origin/main"
  local git = get_git_prefix(bufnr)
  if not git then return default_branch end
  local result = vim.fn.system(git .. "symbolic-ref refs/remotes/origin/HEAD 2>/dev/null")
  if vim.v.shell_error == 0 and result ~= "" then
    default_branch = result:gsub("refs/remotes/", ""):gsub("\n", "")
  end
  return default_branch
end

local function diff_against_default(bufnr)
  local branch = get_branch_name_from_line()
  if not branch then
    vim.notify("No branch found on this line", vim.log.levels.WARN)
    return
  end

  local git, work_tree = get_git_prefix(bufnr, true)
  if not git then return end
  local default_branch = get_default_origin_head(bufnr)

  -- Notify and fetch
  vim.notify("Fetching origin...", vim.log.levels.INFO)

  -- Use jobstart for async fetch
  vim.fn.jobstart(git .. "fetch origin", {
    on_exit = function(_, exit_code)
      if exit_code ~= 0 then
        vim.notify("Fetch failed", vim.log.levels.ERROR)
        return
      end

      -- Open Diffview in a scheduled callback to ensure we are in the right context
      vim.schedule(function()
        -- Compare default_branch...branch (3 dots for merge base diff - GitHub PR style)
        -- The user said "origin and github equivalent diff", so origin/main...branch
        local diff_cmd = "DiffviewOpen -C" .. vim.fn.fnameescape(work_tree)
          .. " " .. default_branch .. "..." .. branch
        vim.cmd(diff_cmd)
        vim.notify("Opened diff: " .. default_branch .. "..." .. branch, vim.log.levels.INFO)
      end)
    end
  })
end

local function rebase_with_stash_fetch(bufnr, default_target)
  local git, work_tree = get_git_prefix(bufnr, true)
  if not git then return end

  local target_default = default_target or get_default_origin_head(bufnr)
  local target = vim.fn.input('Rebase on: ', target_default, 'customlist,v:lua.fugitive_branch_completion')
  vim.cmd('redraw')
  if target == '' then return end

  -- Auto stash
  local stashed = commands.apply_auto_stash(work_tree)
  if stashed == nil then return end

  local cmd = git .. "fetch && " .. git .. "rebase " .. vim.fn.shellescape(target)

  vim.notify("Running: " .. cmd, vim.log.levels.INFO)

  local output_lines = {}
  vim.fn.jobstart(cmd, {
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then table.insert(output_lines, line) end
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then table.insert(output_lines, line) end
        end
      end
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        local message = table.concat(output_lines, "\n")
        if exit_code == 0 then
          if stashed then
             local pop_ok = commands.pop_auto_stash(work_tree)
             if not pop_ok then
                vim.notify("Rebase successful, but stash pop failed.", vim.log.levels.WARN)
             else
                vim.notify("Rebase successful.", vim.log.levels.INFO)
             end
          else
             vim.notify("Rebase successful.", vim.log.levels.INFO)
           end
          notify_branch_changed(bufnr, work_tree)
        else
          vim.notify("Rebase failed.\n" .. message, vim.log.levels.ERROR)
          if stashed then
            vim.notify("Note: Changes were stashed. Resolve rebase conflicts, then run 'git stash pop'.", vim.log.levels.WARN)
          end
        end
      end)
    end
  })
end

local function merge_with_input(bufnr, default_target)
  local work_tree = get_buffer_work_tree(bufnr, true)
  if not work_tree then return end
  local target_default = default_target or get_default_origin_head(bufnr)
  local target = vim.fn.input('Merge: ', target_default, 'customlist,v:lua.fugitive_branch_completion')
  vim.cmd('redraw')
  if target == '' then return end

  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd('Git merge ' .. vim.fn.fnameescape(target))
  end)
  notify_branch_changed(bufnr, work_tree)
end

local function open_branch_list(opts)
  local source_bufnr = vim.api.nvim_get_current_buf()
  local work_tree = opts and opts.work_tree or get_buffer_work_tree(source_bufnr, true)
  if not work_tree then return end
  local git_dir = opts and opts.work_tree and utils.get_git_dir(work_tree)
    or utils.normalize_path(vim.b[source_bufnr].git_dir) or utils.get_git_dir(work_tree)
  if not git_dir then
    vim.notify("Could not determine git dir.", vim.log.levels.ERROR)
    return
  end

  local inventory_buf = source_bufnr
  if opts and opts.work_tree then
    inventory_buf = vim.api.nvim_create_buf(false, true)
    utils.set_buf_work_tree(inventory_buf, work_tree, git_dir)
  end
  local filter = opts and opts.filter or 'all'
  local branch_output, branch_names, truncated_info, ok, branch_kinds = get_branch_list(inventory_buf, filter)
  if inventory_buf ~= source_bufnr then vim.api.nvim_buf_delete(inventory_buf, { force = true }) end
  if not ok then
    vim.notify("Not a git repository or an error occurred.", vim.log.levels.ERROR)
    return
  end

  if #branch_output == 0 then
    vim.notify("No branches found.", vim.log.levels.INFO)
    return
  end

  utils.open_panel_split('fugitive-branch://' .. git_dir)
  local bufnr = vim.api.nvim_get_current_buf()
  utils.set_buf_work_tree(bufnr, work_tree, git_dir)
  vim.b[bufnr].branch_filter = filter

  utils.with_buf_modifiable(bufnr, function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, branch_output)
    vim.b[bufnr].branch_map = branch_names
    vim.b[bufnr].branch_kinds = branch_kinds
    apply_fade_highlight(bufnr, truncated_info)
    apply_branch_highlight(bufnr)
  end)

  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = bufnr })
  vim.api.nvim_set_option_value('bufhidden', 'hide', { buf = bufnr })
  vim.api.nvim_set_option_value('swapfile', false, { buf = bufnr })
  vim.wo[vim.api.nvim_get_current_win()].wrap = false
  vim.bo[bufnr].filetype = 'fugitivebranch'
  vim.bo[bufnr].modifiable = false
  return bufnr
end
M.open = open_branch_list

local function set_branch_filter(bufnr, filter)
  if vim.b[bufnr].branch_filter == filter then return end
  vim.b[bufnr].branch_filter = filter
  refresh_branch_list(bufnr)
end

local function show_branch_help()
  help.show('Branch buffer keys', {
    'ga/gl/gr/gt show all/local/remote/tag refs',
    '<CR>        Gedit selected ref',
    'gx          open pushed branch on GitHub',
    'L           log for selected ref',
    'coo         checkout branch',
    'R           refresh list',
    'cP          cherry-pick register (+)',
    '<Leader>gp  git push',
    'O           open PR (Octo)',
    'bw          rename branch',
    'bs          spin off current branch (check out new branch)',
    'bS          spin out current branch (stay if clean)',
    'bu          set upstream of selected local branch',
    'bU          unset upstream of selected local branch',
    'cod         duplicate branch',
    'cot         create worktree',
    'X (n/V)     delete branch(es)',
    'f           fetch --all --prune',
    'p           pull current branch',
    'P           pull branch under cursor',
    'd           diff against origin/default (PR view)',
    'm<Space>    merge branch (input)',
    'r<Space>    stash -> fetch -> rebase (input)',
    '<C-Space>   toggle Flog graph',
    'q           close panel',
  })
end

function M.setup(group)
  vim.api.nvim_set_decoration_provider(branch_filter_ns, {
    on_win = function(_, _, bufnr, toprow)
      if vim.bo[bufnr].filetype ~= 'fugitivebranch' then return false end
      vim.api.nvim_buf_set_extmark(bufnr, branch_filter_ns, toprow, 0, {
        virt_text = { { ' ' .. (filters[vim.b[bufnr].branch_filter or 'all'] or 'All') .. ' ', 'Comment' } },
        virt_text_pos = 'right_align',
        ephemeral = true,
        priority = 200,
      })
      return false
    end,
  })
  vim.api.nvim_create_user_command('Gbranch', open_branch_list, {
    bang = false,
    desc = "Open git branch list",
  })
  vim.api.nvim_create_user_command('GbranchSpinoff', function(opts)
    spin_branch(vim.api.nvim_get_current_buf(), 'spinoff', opts.args ~= '' and opts.args or nil)
  end, { nargs = '?', desc = 'Spin off outgoing commits from an optional commit' })
  vim.api.nvim_create_user_command('GbranchSpinout', function(opts)
    spin_branch(vim.api.nvim_get_current_buf(), 'spinout', opts.args ~= '' and opts.args or nil)
  end, { nargs = '?', desc = 'Spin out outgoing commits from an optional commit' })

  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'fugitive',
    callback = function(ev)
      vim.keymap.set('n', 'B', function()
        vim.cmd('Gbranch')
      end, { buffer = ev.buf, silent = true, desc = "Open git branch list" })
    end
  })

  -- fugitive://スキームと同様に、fugitive-branch://スキームもファイルとして扱わないように設定する
  -- これによりセッション復元時などのE212エラー（ディレクトリへの書き込み試行）を防ぐ
  vim.api.nvim_create_autocmd({ 'BufReadCmd', 'BufNewFile' }, {
    group = group,
    pattern = 'fugitive-branch://*',
    callback = function(ev)
      local bufnr = ev.buf
      local buf_name = vim.api.nvim_buf_get_name(bufnr)
      local git_dir = buf_name:sub(#'fugitive-branch://' + 1)
      local work_tree = utils.get_work_tree({ git_dir = git_dir })
      utils.set_buf_work_tree(bufnr, work_tree, git_dir)
      vim.api.nvim_set_option_value('buftype', 'nofile', { buf = bufnr })
      vim.api.nvim_set_option_value('bufhidden', 'hide', { buf = bufnr })
      vim.api.nvim_set_option_value('swapfile', false, { buf = bufnr })
      vim.bo[bufnr].filetype = 'fugitivebranch'
      refresh_branch_list(bufnr)
    end,
  })

  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'fugitivebranch',
    callback = function(ev)
      local bufnr = ev.buf
      local buf_group = vim.api.nvim_create_augroup('fugitive_branch_buf_' .. bufnr, { clear = true })
      require('git.features.magit_actions').attach(bufnr)

      vim.keymap.set('n', '?', function()
        show_branch_help()
      end, { buffer = bufnr, silent = true, desc = "Help" })
      vim.keymap.set('n', 'q', function()
        require('utilities').smart_close()
      end, { buffer = bufnr, nowait = true, silent = true, desc = 'Close branch list' })
      for key, filter in pairs({ ga = 'all', gl = 'local_', gr = 'remote', gt = 'tags' }) do
        vim.keymap.set('n', key, function()
          set_branch_filter(bufnr, filter)
        end, { buffer = bufnr, nowait = true, silent = true,
          desc = 'Show ' .. filters[filter] .. ' refs' })
      end

      -- Add checkout keymap
      vim.keymap.set('n', 'coo', function()
        checkout_branch(bufnr)
      end, { buffer = bufnr, silent = true, desc = "Checkout branch" })

      vim.keymap.set('n', '<CR>', function()
        local branch = get_ref_at_cursor(bufnr)
        if not branch then
          vim.notify("No branch found on this line", vim.log.levels.WARN)
          return
        end
        vim.cmd('Gedit ' .. branch)
      end, { buffer = bufnr, silent = true, desc = "Gedit branch" })

      vim.keymap.set('n', 'gx', function()
        local row = vim.fn.line('.')
        local branch = (vim.b[bufnr].branch_map or {})[row]
        local kind = (vim.b[bufnr].branch_kinds or {})[row]
        local root = get_buffer_work_tree(bufnr)
        github_open.open(github_open.branch_url(root, branch, kind),
          'Branch has no known GitHub remote ref')
      end, { buffer = bufnr, silent = true, desc = 'Open pushed branch on GitHub' })

      vim.keymap.set('n', 'R', function()
        refresh_branch_list(bufnr)
      end, { buffer = bufnr, silent = true, desc = "Refresh branch list" })

      -- Add cherrypick keymap
      vim.keymap.set('n', 'cP', function()
        -- flog copy register uses +
        commands.git_cherry_pick({
          reg = '+',
          on_complete = function()
            refresh_branch_list(bufnr)
          end
        })
      end, { buffer = bufnr, silent = true, desc = "cherrypick branch" })

      -- Add git push keymap
      vim.keymap.set('n', '<Leader>gp', function()
        commands.git_push({
          on_complete = function()
            refresh_branch_list(bufnr)
          end
        })
      end, { buffer = bufnr, silent = true, desc = "git push" })

      -- Add Octo pr show keymap
      vim.keymap.set('n', 'O', function()
        local branch = get_branch_name_from_line()
        if branch then
          branch = branch:gsub('^origin/', '')
        end
        if branch then
          vim.cmd('OctoPrFromBranch '.. branch)
        end
      end, { buffer = bufnr, silent = true, desc = "Open PR for branch" })

      -- bw: Rename branch
      vim.keymap.set('n', 'bw', function()
        rename_branch(bufnr)
      end, { buffer = bufnr, silent = true, desc = "Rename branch" })

      vim.keymap.set('n', 'bs', function()
        spin_branch(bufnr, 'spinoff')
      end, { buffer = bufnr, silent = true, desc = 'Spin off current branch' })
      vim.keymap.set('n', 'bS', function()
        spin_branch(bufnr, 'spinout')
      end, { buffer = bufnr, silent = true, desc = 'Spin out current branch' })
      vim.keymap.set('n', 'bu', function()
        change_upstream(bufnr, false)
      end, { buffer = bufnr, silent = true, desc = 'Set upstream of selected branch' })
      vim.keymap.set('n', 'bU', function()
        change_upstream(bufnr, true)
      end, { buffer = bufnr, silent = true, desc = 'Unset upstream of selected branch' })

      -- bd: Duplicate branch (prompt for a new name and create local branch from selected one)
      vim.keymap.set('n', 'cod', function()
        duplicate_branch(bufnr)
      end, { buffer = bufnr, silent = true, desc = "Duplicate branch" })

      -- cot: Create worktree from branch
      vim.keymap.set('n', 'cot', function()
        create_worktree(bufnr)
      end, { buffer = bufnr, silent = true, desc = "Create worktree from branch" })

      -- X: Delete branch(es)
      vim.keymap.set('n', 'X', function()
        local branch = get_branch_name_from_line()
        if branch then
          delete_branches(bufnr, {branch})
        end
      end, { buffer = bufnr, silent = true, desc = "Delete branch" })

      -- f: Fetch
      vim.keymap.set('n', 'f', function()
        fetch_all(bufnr)
      end, { buffer = bufnr, silent = true, desc = "Fetch all" })

      -- p: Pull
      vim.keymap.set('n', 'p', function()
        pull_branch(bufnr)
      end, { buffer = bufnr, silent = true, desc = "Pull branch" })

      -- P: Pull branch under cursor
      vim.keymap.set('n', 'P', function()
        pull_branch_under_cursor(bufnr)
      end, { buffer = bufnr, silent = true, desc = "Pull branch under cursor" })

      -- D: Diff against default branch
      vim.keymap.set('n', 'd', function()
        diff_against_default(bufnr)
      end, { buffer = bufnr, silent = true, desc = "Diff against default branch" })

      -- r<Space>: Stash, Fetch, Rebase
      vim.keymap.set('n', 'r<Space>', function()
        local branch = get_branch_name_from_line()
        if not branch then branch = nil end
        rebase_with_stash_fetch(bufnr, branch)
      end, { buffer = bufnr, silent = true, desc = "Stash, Fetch, Rebase" })

      -- m<Space>: Merge
      vim.keymap.set('n', 'm<Space>', function()
        local branch = get_branch_name_from_line()
        if not branch then branch = nil end
        merge_with_input(bufnr, branch)
      end, { buffer = bufnr, silent = true, desc = "Merge branch" })

      vim.keymap.set('v', 'X', function()
        local start_line = vim.fn.line('v')
        local end_line = vim.fn.line('.')
        if start_line > end_line then
          start_line, end_line = end_line, start_line
        end

        local branches = {}
        for i = start_line, end_line do
          local branch = (vim.b[bufnr].branch_kinds or {})[i] ~= 'tags'
            and (vim.b[bufnr].branch_map or {})[i] or nil
          if branch then
            table.insert(branches, branch)
          end
        end

        delete_branches(bufnr, branches)
      end, { buffer = bufnr, silent = true, desc = "Delete branches" })

      -- L: Open log for branch under cursor
      vim.keymap.set('n', 'L', function()
        local branch = get_ref_at_cursor(bufnr)
        if not branch then
          vim.notify("No branch found on this line", vim.log.levels.WARN)
          return
        end
        vim.cmd("FugitiveLog " .. vim.fn.fnameescape(branch))
      end, { buffer = bufnr, silent = true, desc = "Open log for branch" })

      -- <C-Space>: Flog window toggle for current branch
      vim.keymap.set('n', '<C-Space>', function()
        local branch = get_ref_at_cursor(bufnr)
        if not branch then
          vim.notify("No branch found on this line", vim.log.levels.WARN)
          return
        end

        if vim.g.flog_win and vim.api.nvim_win_is_valid(vim.g.flog_win) then
          vim.api.nvim_win_close(vim.g.flog_win, false)
          vim.g.flog_win = nil
          vim.g.flog_bufnr = nil
          vim.g.flog_branch_bufnr = nil
        else
          local current_win = vim.api.nvim_get_current_win()
          require('git.graph').open(branch)
          vim.g.flog_bufnr = vim.api.nvim_get_current_buf()
          vim.g.flog_win = vim.api.nvim_get_current_win()
          vim.g.flog_branch_bufnr = bufnr

          utils.setup_flog_window(vim.g.flog_win, vim.g.flog_bufnr)
          vim.api.nvim_set_current_win(current_win)
        end
      end, { buffer = bufnr, nowait = true, silent = true, desc = 'Toggle Flog graph for branch' })

      -- Update Flog on cursor move if Flog window is open
      vim.api.nvim_create_autocmd('CursorMoved', {
        buffer = bufnr,
        group = buf_group,
        callback = function()
          if vim.g.flog_win and vim.api.nvim_win_is_valid(vim.g.flog_win) and vim.g.flog_branch_bufnr == bufnr then
            local branch = get_ref_at_cursor(bufnr)
            if branch then
              local current_win = vim.api.nvim_get_current_win()

              -- Close old Flog window
              vim.api.nvim_win_close(vim.g.flog_win, false)

              -- Open new Flog with new branch
              require('git.graph').open(branch)
              vim.g.flog_bufnr = vim.api.nvim_get_current_buf()
              vim.g.flog_win = vim.api.nvim_get_current_win()

              utils.setup_flog_window(vim.g.flog_win, vim.g.flog_bufnr)
              vim.api.nvim_set_current_win(current_win)
            end
          end
        end,
      })

      vim.api.nvim_create_autocmd('BufUnload', {
        buffer = bufnr,
        group = buf_group,
        callback = function(args)
          if vim.g.flog_branch_bufnr and vim.g.flog_branch_bufnr == args.buf then
            if vim.g.flog_win and vim.api.nvim_win_is_valid(vim.g.flog_win) then
              vim.api.nvim_win_close(vim.g.flog_win, true)
              vim.g.flog_win = nil
              vim.g.flog_bufnr = nil
              vim.g.flog_branch_bufnr = nil
            end
          end
        end,
      })

      -- Set buffer options
      vim.opt_local.number = false
      vim.opt_local.relativenumber = false
      vim.opt_local.signcolumn = 'no'

      require('git.features.panel_keys').configure(bufnr)
      -- Setup highlighting for branch names
      apply_branch_highlight(bufnr)


      utils.setup_repo_refresh(buf_group, bufnr, function(target_bufnr)
        refresh_branch_list(target_bufnr)
      end, { visible_only = true })
    end,
  })
end

return M

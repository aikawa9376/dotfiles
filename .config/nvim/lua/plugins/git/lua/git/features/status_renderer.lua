local M = {}
local operation = require('git.features.operation')
local change_display = require('git.features.change_display')
local status_patch = require('git.features.status_patch')

local models = {}
local expanded = {}
local subjects_by_buf = {}
local operation_cache_by_buf = {}
local chosen_conflict_side_by_buf = {}
local conflict_diff_cache_by_buf = {}

local function subject_cache(bufnr, work_tree)
  local cache = subjects_by_buf[bufnr]
  if not cache or cache.work_tree ~= work_tree then
    cache = { work_tree = work_tree }
    subjects_by_buf[bufnr] = cache
  end
  return cache
end

local function run(work_tree, args)
  local command = { 'git' }
  vim.list_extend(command, args)
  return vim.system(command, { cwd = work_tree, text = true }):wait()
end

local function run_async(work_tree, args, callback)
  local command = { 'git' }
  vim.list_extend(command, args)
  vim.system(command, { cwd = work_tree, text = true }, function(result)
    vim.schedule(function() callback(result) end)
  end)
end

local function split_nul(value)
  return vim.split(value or '', '\0', { plain = true, trimempty = true })
end

local function parse_numstat(work_tree, cached)
  local args = { 'diff', '--numstat', '-z', '--no-ext-diff', '--no-renames' }
  if cached then table.insert(args, '--cached') end
  local result = run(work_tree, args)
  if result.code ~= 0 then return {} end

  local stats = {}
  for _, record in ipairs(split_nul(result.stdout)) do
    local added, deleted, path = record:match('^([^\t]+)\t([^\t]+)\t(.*)$')
    if path and path ~= '' then
      stats[path] = {
        additions = tonumber(added) or 0,
        deletions = tonumber(deleted) or 0,
        binary = added == '-' or deleted == '-',
      }
    end
  end
  return stats
end

local function attach_numstat(entries, stats)
  for _, entry in ipairs(entries) do
    local paths = { entry.path }
    if entry.old_path and entry.old_path ~= entry.path then table.insert(paths, entry.old_path) end

    local found = false
    local additions, deletions = 0, 0
    local binary = false
    for _, path in ipairs(paths) do
      local stat = stats[path]
      if stat then
        found = true
        additions = additions + stat.additions
        deletions = deletions + stat.deletions
        binary = binary or stat.binary
      end
    end
    if found then
      entry.additions = additions
      entry.deletions = deletions
      entry.binary = binary
    end
  end
end

local function untracked_numstat(path)
  local stat = vim.uv.fs_lstat(path)
  if not stat then return nil end
  if stat.type == 'link' then
    local target = vim.uv.fs_readlink(path)
    if not target then return nil end
    local _, count = target:gsub('\n', '')
    return count + (target ~= '' and target:sub(-1) ~= '\n' and 1 or 0), false
  end
  -- Do not follow symlinks or try to read directories and special files.
  if stat.type ~= 'file' then return nil end
  local file = io.open(path, 'rb')
  if not file then return nil end
  local count, last, first = 0, '', true
  while true do
    local chunk, err = file:read(65536)
    if err then file:close(); return nil end
    if not chunk then break end
    -- Match Git's default binary heuristic without loading the entire file.
    if first and chunk:sub(1, 8000):find('\0', 1, true) then
      file:close()
      return 0, true
    end
    first = false
    local _, newlines = chunk:gsub('\n', '')
    count = count + newlines
    last = chunk:sub(-1)
  end
  file:close()
  return count + (last ~= '' and last ~= '\n' and 1 or 0), false
end

local function parse_status_result(work_tree, result)
  if result.code ~= 0 then return nil, vim.trim(result.stderr or 'git status failed') end

  local model = {
    work_tree = work_tree,
    branch = nil,
    oid = nil,
    upstream = nil,
    push = nil,
    ahead = 0,
    behind = 0,
    staged = {},
    unstaged = {},
    untracked = {},
    conflicted = {},
  }
  local records = split_nul(result.stdout)
  local index = 1
  while index <= #records do
    local record = records[index]
    if record:sub(1, 2) == '# ' then
      local key, value = record:match('^# ([^ ]+) (.*)$')
      if key == 'branch.oid' then model.oid = value
      elseif key == 'branch.head' then model.branch = value
      elseif key == 'branch.upstream' then model.upstream = value
      elseif key == 'branch.ab' then
        model.ahead = tonumber(value:match('%+(%d+)')) or 0
        model.behind = tonumber(value:match('%-(%d+)')) or 0
      end
    elseif record:sub(1, 2) == '1 ' then
      local xy, path = record:match('^1 ([^ ]+) [^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ (.*)$')
      if xy and path then
        local x, y = xy:sub(1, 1), xy:sub(2, 2)
        if x ~= '.' then table.insert(model.staged, { section = 'staged', status = x, path = path }) end
        if y ~= '.' then table.insert(model.unstaged, { section = 'unstaged', status = y, path = path }) end
      end
    elseif record:sub(1, 2) == '2 ' then
      local xy, path = record:match('^2 ([^ ]+) [^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ (.*)$')
      local old_path = records[index + 1]
      if xy and path and old_path then
        index = index + 1
        local x, y = xy:sub(1, 1), xy:sub(2, 2)
        local display_path = old_path .. ' -> ' .. path
        if x ~= '.' then
          table.insert(model.staged, { section = 'staged', status = x, path = path, old_path = old_path, display_path = display_path })
        end
        if y ~= '.' then
          table.insert(model.unstaged, { section = 'unstaged', status = y, path = path, old_path = old_path, display_path = display_path })
        end
      end
    elseif record:sub(1, 2) == 'u ' then
      local xy, base, ours, theirs, path = record:match(
        '^u ([^ ]+) [^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ (%x+) (%x+) (%x+) (.*)$'
      )
      if xy and path then
        local function present(hash)
          return hash and hash:find('[^0]') and hash or nil
        end
        table.insert(model.conflicted, {
          section = 'conflicted', status = xy, path = path,
          conflict_stages = { [1] = present(base), [2] = present(ours), [3] = present(theirs) },
        })
      end
    elseif record:sub(1, 2) == '? ' then
      table.insert(model.untracked, { section = 'untracked', status = '?', path = record:sub(3) })
    end
    index = index + 1
  end
  return model
end

local function parse_status(bufnr, work_tree)
  local result = run(work_tree, {
    '--no-optional-locks', 'status', '--porcelain=v2', '-z', '--branch', '--untracked-files=all',
  })
  local model, err = parse_status_result(work_tree, result)
  if not model then return nil, err end

  local push_result = run(work_tree, { 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{push}' })
  if push_result.code == 0 then model.push = vim.trim(push_result.stdout or '') end
  if not model.push or model.push == '' then model.push = model.upstream end
  local subjects = subject_cache(bufnr, work_tree)
  local function subject(ref, known_oid)
    if not ref then return nil end
    local oid = known_oid
    if not oid then
      local resolved = run(work_tree, { 'rev-parse', '--verify', '--end-of-options', ref .. '^{commit}' })
      if resolved.code ~= 0 then return nil end
      oid = vim.trim(resolved.stdout or '')
    end
    if oid == '' then return nil end
    if ref == model.upstream then model.upstream_oid = oid end
    local cached = subjects[ref]
    if cached and cached.oid == oid then return cached.subject end
    local result = run(work_tree, { 'log', '-1', '--format=%s', '--end-of-options', oid })
    if result.code ~= 0 then return nil end
    local value = vim.trim(result.stdout or '')
    local current = value ~= '' and value or nil
    subjects[ref] = { oid = oid, subject = current }
    return current
  end
  if model.oid and model.oid ~= '(initial)' then model.head_subject = subject('HEAD', model.oid) end
  model.upstream_subject = subject(model.upstream)
  if model.push ~= model.upstream then model.push_subject = subject(model.push) end
  attach_numstat(model.unstaged, parse_numstat(work_tree, false))
  attach_numstat(model.staged, parse_numstat(work_tree, true))
  for _, entry in ipairs(model.untracked) do
    entry.additions, entry.binary = untracked_numstat(vim.fs.joinpath(work_tree, entry.path))
    if entry.additions ~= nil then entry.deletions = 0 end
  end
  return model
end

local function conflict_stages(model, entry)
  local result = run(model.work_tree, { 'ls-files', '-u', '-z', '--', entry.path })
  if result.code ~= 0 then return nil, vim.trim(result.stderr or 'Could not read conflict stages') end
  local stages = {}
  for _, record in ipairs(split_nul(result.stdout)) do
    local hash, stage = record:match('^%d+ (%x+) ([123])\t')
    if hash then stages[tonumber(stage)] = hash end
  end
  if not next(stages) then return nil, 'Conflict is no longer present; refresh status' end
  return stages
end

local function conflict_blocks(worktree)
  local blocks, block, phase, width = {}, nil, nil, nil
  for row, line in ipairs(vim.split(worktree, '\n', { plain = true })) do
    local marker_line = line:gsub('\r$', '')
    local opener = marker_line:match('^(<+) ')
    if not phase and opener and #opener >= 7 then
      width = #opener
      block = { ours = {}, theirs = {}, first = row }
      phase = 'ours'
    elseif phase == 'ours' and marker_line:sub(1, width + 1) == string.rep('|', width) .. ' ' then
      phase = 'base'
    elseif (phase == 'ours' or phase == 'base') and marker_line == string.rep('=', width) then
      block.theirs_first = row + 1
      phase = 'theirs'
    elseif phase == 'theirs' and marker_line:sub(1, width + 1) == string.rep('>', width) .. ' ' then
      block.last = row
      blocks[#blocks + 1] = block
      block, phase, width = nil, nil, nil
    elseif phase == 'ours' then
      block.ours[#block.ours + 1] = line
    elseif phase == 'theirs' then
      block.theirs[#block.theirs + 1] = line
    end
  end
  if phase then return nil end
  return blocks
end

local function read_worktree_content(work_tree, path)
  local absolute = vim.fs.joinpath(work_tree, path)
  local stat = vim.uv.fs_lstat(absolute)
  if stat and stat.type == 'link' then return vim.uv.fs_readlink(absolute) end
  if not stat or stat.type ~= 'file' then return nil end
  local file = io.open(absolute, 'rb')
  if not file then return nil end
  local content = file:read('*a')
  file:close()
  return content
end

local function resolve_conflict_blocks(worktree, blocks, side, selected)
  local source = vim.split(worktree, '\n', { plain = true })
  local result, next_row = {}, 1
  for number, block in ipairs(blocks) do
    for row = next_row, block.first - 1 do result[#result + 1] = source[row] end
    if not selected or selected == number then
      vim.list_extend(result, block[side])
    else
      for row = block.first, block.last do result[#result + 1] = source[row] end
    end
    next_row = block.last + 1
  end
  for row = next_row, #source do result[#result + 1] = source[row] end
  return table.concat(result, '\n')
end

local function block_text(lines)
  return #lines > 0 and table.concat(lines, '\n') .. '\n' or ''
end

local function base_changes_overlap(left, right)
  local a, ac, b, bc = left[1], left[2], right[1], right[2]
  if ac == 0 and bc == 0 then return a == b end
  if ac == 0 then return a >= b and a <= b + bc end
  if bc == 0 then return b >= a and b <= a + ac end
  return a <= b + bc - 1 and b <= a + ac - 1
end

local function conflict_diff_rows(base, ours, theirs, worktree, diff_lines)
  local ours_changes = vim.diff(base, ours, { result_type = 'indices', ctxlen = 0 })
  local theirs_changes = vim.diff(base, theirs, { result_type = 'indices', ctxlen = 0 })
  local ours_lines = vim.split(ours, '\n', { plain = true })
  local theirs_lines = vim.split(theirs, '\n', { plain = true })
  local function same_edit(left, right)
    if left[1] ~= right[1] or left[2] ~= right[2] or left[4] ~= right[4] then
      return false
    end
    for offset = 0, left[4] - 1 do
      if ours_lines[left[3] + offset] ~= theirs_lines[right[3] + offset] then
        return false
      end
    end
    return true
  end
  local conflicts = {}
  for _, left in ipairs(ours_changes) do
    for _, right in ipairs(theirs_changes) do
      if base_changes_overlap(left, right) and not same_edit(left, right) then
        conflicts[#conflicts + 1] = left
        break
      end
    end
  end
  if #conflicts == 0 then return {} end

  local old_rows, new_rows = {}, {}
  for _, change in ipairs(vim.diff(base, worktree, { result_type = 'indices', ctxlen = 0 })) do
    local overlaps = false
    for _, conflict in ipairs(conflicts) do
      if base_changes_overlap(change, conflict) then overlaps = true; break end
    end
    if overlaps then
      for row = change[1], change[1] + change[2] - 1 do old_rows[row] = true end
      for row = change[3], change[3] + change[4] - 1 do new_rows[row] = true end
    end
  end

  local highlighted, old_row, new_row = {}, 0, 0
  for index, line in ipairs(diff_lines) do
    local old_start, new_start = line:match('^@@ %-(%d+),?%d* %+(%d+),?%d* @@')
    if old_start then
      old_row, new_row = tonumber(old_start), tonumber(new_start)
    elseif line:sub(1, 1) == '-' then
      if old_rows[old_row] then highlighted[index] = true end
      old_row = old_row + 1
    elseif line:sub(1, 1) == '+' then
      if new_rows[new_row] then highlighted[index] = true end
      new_row = new_row + 1
    elseif line:sub(1, 1) == ' ' then
      old_row, new_row = old_row + 1, new_row + 1
    end
  end
  return highlighted
end

local function conflict_diff_lines(model, entry)
  local stages, err = entry.conflict_stages, nil
  if not stages then stages, err = conflict_stages(model, entry) end
  if not stages then return { '  ' .. err } end
  entry.conflict_stages = stages
  local function content(stage)
    if not stages[stage] then return '' end
    local result = run(model.work_tree, { 'cat-file', 'blob', stages[stage] })
    return result.code == 0 and result.stdout or nil
  end
  local ours, theirs
  local label = 'stage 2 (ours) -> stage 3 (theirs)'
  local chosen = chosen_conflict_side_by_buf[model.bufnr]
  chosen = chosen and chosen[entry.path]
  if chosen and not vim.deep_equal(chosen.stages, stages) then
    chosen_conflict_side_by_buf[model.bufnr][entry.path] = nil
    chosen = nil
  end
  local cache = conflict_diff_cache_by_buf[model.bufnr]
  local worktree
  local both_sides = stages[2] and stages[3]
  if both_sides or chosen then
    worktree = read_worktree_content(model.work_tree, entry.path)
  end
  local cache_key = not chosen and table.concat({ stages[2] or '', stages[3] or '',
    both_sides and worktree and vim.fn.sha256(worktree) or '' }, '\0') or nil
  local cached = cache and cache[entry.path]
  if cache_key and cached and cached.key == cache_key then
    entry.conflict_highlight_lines = cached.highlight_lines
    entry.conflict_worktree_lines = cached.worktree_lines
    return cached.lines
  end
  local blocks = both_sides and not chosen and worktree and conflict_blocks(worktree)
  if chosen then
    if worktree == nil then return { '  Could not read selected worktree content' } end
    ours, theirs = content(1), worktree
    label = ('stage 1 (base) -> worktree (chosen %s)'):format(chosen.side)
  elseif blocks and #blocks == 0 then
    ours, theirs = content(1), worktree
    label = 'stage 1 (base) -> worktree (manually resolved)'
  else
    ours, theirs = content(2), content(3)
  end
  if not ours or not theirs then return { '  Could not read conflict blobs' } end
  if ours:find('\0', 1, true) or theirs:find('\0', 1, true) then
    return { '  Binary conflict: ' .. label }
  end
  local lines = {}
  entry.conflict_worktree_lines = nil
  if blocks and #blocks > 0 then
    local worktree_lines = {}
    for number, block in ipairs(blocks) do
      local diff = vim.diff(block_text(block.ours), block_text(block.theirs),
        { result_type = 'unified', ctxlen = math.max(#block.ours, #block.theirs) })
      local old_row, new_row = 0, 0
      for _, line in ipairs(vim.split(diff, '\n', { plain = true, trimempty = true })) do
        lines[#lines + 1] = line:match('^@@') and
          (line .. ('  worktree ours -> theirs, conflict %d'):format(number)) or line
        local old_start, new_start = line:match('^@@ %-(%d+),?%d* %+(%d+),?%d* @@')
        if old_start then
          old_row, new_row = tonumber(old_start), tonumber(new_start)
          worktree_lines[#lines] = block.first + math.max(old_row, 1)
        elseif line:sub(1, 1) == '-' then
          worktree_lines[#lines] = block.first + old_row
          old_row = old_row + 1
        elseif line:sub(1, 1) == '+' then
          worktree_lines[#lines] = block.theirs_first + new_row - 1
          new_row = new_row + 1
        elseif line:sub(1, 1) == ' ' then
          worktree_lines[#lines] = block.first + old_row
          old_row, new_row = old_row + 1, new_row + 1
        end
      end
    end
    entry.conflict_worktree_lines = worktree_lines
  else
    if both_sides and not chosen and worktree and not blocks then
      lines = { '  Incomplete conflict markers in worktree; edit them and use cr' }
    else
      local diff = vim.diff(ours, theirs, { result_type = 'unified', ctxlen = 3 })
      if diff == '' then return { '  No content difference: ' .. label } end
      lines = vim.split(diff, '\n', { plain = true, trimempty = true })
      for index, line in ipairs(lines) do
        if line:match('^@@') then lines[index] = line .. '  ' .. label end
      end
    end
  end
  entry.conflict_highlight_lines = nil
  if (chosen or (blocks and #blocks == 0)) and both_sides and #lines > 0
    and lines[1]:match('^@@')
  then
    local base = ours
    local stage_ours, stage_theirs = content(2), content(3)
    if base and stage_ours and stage_theirs then
      entry.conflict_highlight_lines = conflict_diff_rows(base, stage_ours,
        stage_theirs, worktree, lines)
    end
  end
  if cache_key then
    conflict_diff_cache_by_buf[model.bufnr] = conflict_diff_cache_by_buf[model.bufnr] or {}
    conflict_diff_cache_by_buf[model.bufnr][entry.path] = {
      key = cache_key, lines = lines, highlight_lines = entry.conflict_highlight_lines,
      worktree_lines = entry.conflict_worktree_lines,
    }
  end
  return lines
end

local function diff_lines(model, entry)
  if entry.section == 'conflicted' then return conflict_diff_lines(model, entry) end
  if entry.section == 'untracked' then
    local paths = { entry.path }
    local absolute = vim.fs.joinpath(model.work_tree, entry.path)
    if vim.fn.isdirectory(absolute) == 1 then
      local result = run(model.work_tree, {
        'ls-files', '--others', '--exclude-standard', '--', entry.path,
      })
      paths = result.code == 0 and vim.split(vim.trim(result.stdout or ''), '\n', { plain = true, trimempty = true }) or {}
    end

    local lines = {}
    for _, path in ipairs(paths) do
      local filename = vim.fs.joinpath(model.work_tree, path)
      local ok, content = pcall(vim.fn.readfile, filename, 'b')
      if ok then
        table.insert(lines, ('@@ new file: %s (%d lines) @@'):format(path, #content))
        for _, line in ipairs(content) do table.insert(lines, '+' .. line) end
      end
    end
    return lines
  end

  local result = status_patch.diff(model.work_tree, entry.section, entry.path)
  if result.code ~= 0 then return {} end
  local all_lines, hunk_start = {}, nil
  for line in (result.stdout or ''):gmatch('[^\r\n]+') do
    table.insert(all_lines, line)
    if not hunk_start and line:match('^@@') then hunk_start = #all_lines end
  end
  if not hunk_start then return all_lines end
  local lines = {}
  for index = hunk_start, #all_lines do table.insert(lines, all_lines[index]) end
  return lines
end

local function patch_selection(bufnr, model, first_row, last_row, action, visual)
  local first = M.entry_at(bufnr, first_row)
  local last = M.entry_at(bufnr, last_row)
  if not first or first ~= last or first.header then return nil end
  if first.section ~= 'staged' and first.section ~= 'unstaged' then return nil end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local header_row
  for row = first_row, 1, -1 do
    if model.entries_by_row[row] ~= first then break end
    if lines[row] and lines[row]:match('^@@') then header_row = row; break end
  end
  if not header_row then return nil end
  if action == 'unstage' and first.section ~= 'staged' then return false, 'Only staged changes can be unstaged' end
  local hunk_number = 0
  for row = 1, header_row do
    if model.entries_by_row[row] == first and lines[row] and lines[row]:match('^@@') then
      hunk_number = hunk_number + 1
    end
  end
  local selected = {}
  local final_row = header_row
  while model.entries_by_row[final_row + 1] == first and not (lines[final_row + 1] or ''):match('^@@') do
    final_row = final_row + 1
  end
  if last_row > final_row then return false, 'Select lines within one hunk' end
  if visual and first_row > header_row then
    for row = first_row, last_row do selected[row - header_row] = true end
  end
  local expected = {}
  for row = header_row, final_row do expected[#expected + 1] = lines[row] end
  if action == 'discard' then
    return status_patch.discard(model.work_tree, first.section, first.path, hunk_number, selected, expected)
  end
  return status_patch.apply(model.work_tree, first.section, first.path, hunk_number, selected, expected)
end

local function entry_key(entry)
  return entry.section .. '\0' .. entry.path
end

local function is_expanded(bufnr, entry)
  local value = expanded[bufnr] and expanded[bufnr][entry_key(entry)]
  return value == true
end

local function append_section(lines, entries_by_row, model, title, section, entries)
  if #entries == 0 then return end
  table.insert(lines, '')
  table.insert(lines, ('%s (%d)'):format(title, #entries))
  entries_by_row[#lines] = { section = section, header = true }
  for _, entry in ipairs(entries) do
    table.insert(lines, change_display.line(entry))
    entries_by_row[#lines] = entry
    if is_expanded(model.bufnr, entry) then
      for _, diff_line in ipairs(diff_lines(model, entry)) do
        table.insert(lines, diff_line)
        entries_by_row[#lines] = entry
      end
    end
  end
end

local function parse_commit_lines(result)
  if result.code ~= 0 then return {}, false end
  local commits = {}
  for line in (result.stdout or ''):gmatch('[^\r\n]+') do
    table.insert(commits, (line:gsub('\t', ' ')))
  end
  return commits, true
end

local function commit_args(revisions)
  local args = {
    'log',
    '--date=format:%Y-%m-%d %H:%M',
    '--pretty=format:%h%x09%ad%x09%s',
    '-n',
    '256',
  }
  if type(revisions) == 'table' then
    vim.list_extend(args, revisions)
  else
    table.insert(args, revisions)
  end
  table.insert(args, '--')
  return args
end

local function commit_lines(work_tree, revisions)
  return parse_commit_lines(run(work_tree, commit_args(revisions)))
end

local function commit_lines_async(work_tree, revisions, callback)
  run_async(work_tree, commit_args(revisions), function(result)
    local commits, ok = parse_commit_lines(result)
    callback(commits, ok)
  end)
end

function M.take_ownership(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.b[bufnr].custom_git_status = true
end

function M.is_owned(bufnr)
  return vim.api.nvim_buf_is_valid(bufnr) and vim.b[bufnr].custom_git_status == true
end

local function snapshot_from_model(bufnr, model, opts)
  if not vim.api.nvim_buf_is_valid(bufnr) then return nil, 'Invalid status buffer' end
  opts = opts or {}
  model.bufnr = bufnr
  local previous = models[bufnr]
  if previous and previous.work_tree ~= model.work_tree then
    expanded[bufnr] = nil
    operation_cache_by_buf[bufnr] = nil
    chosen_conflict_side_by_buf[bufnr] = nil
    conflict_diff_cache_by_buf[bufnr] = nil
  end
  local active_conflicts = {}
  for _, entry in ipairs(model.conflicted) do active_conflicts[entry.path] = true end
  local conflict_prefix = 'conflicted\0'
  for key in pairs(expanded[bufnr] or {}) do
    if key:sub(1, #conflict_prefix) == conflict_prefix
      and not active_conflicts[key:sub(#conflict_prefix + 1)]
    then
      expanded[bufnr][key] = nil
    end
  end
  local function prune_conflict_cache(cache)
    for path in pairs(cache or {}) do
      if not active_conflicts[path] then cache[path] = nil end
    end
  end
  prune_conflict_cache(chosen_conflict_side_by_buf[bufnr])
  prune_conflict_cache(conflict_diff_cache_by_buf[bufnr])
  local function with_subject(line, subject)
    return subject and (line .. '  ' .. subject) or line
  end

  local lines = {
    with_subject(
      'Head: ' .. ((model.branch and model.branch ~= '(detached)') and model.branch or (model.oid or 'unknown'):sub(1, 12)),
      model.head_subject
    ),
  }
  if model.upstream then
    table.insert(lines, with_subject(
      ('Upstream: %s (+%d/-%d)'):format(model.upstream, model.ahead, model.behind),
      model.upstream_subject
    ))
  end
  if model.push and model.push ~= model.upstream then
    table.insert(lines, with_subject('Push: ' .. model.push, model.push_subject))
  end
  vim.list_extend(lines, opts.header_lines or {})
  local cached_operation = operation_cache_by_buf[bufnr]
  local git_dir = vim.b[bufnr].git_dir or (cached_operation and cached_operation.git_dir)
  local signature, resolved_git_dir = operation.signature(model.work_tree, git_dir, model.oid)
  local operation_lines
  if cached_operation and cached_operation.work_tree == model.work_tree
    and cached_operation.signature == signature
  then
    operation_lines = cached_operation.lines
  elseif not opts.fast then
    operation_lines = operation.status_lines(operation.inspect(model.work_tree))
    operation_cache_by_buf[bufnr] = {
      work_tree = model.work_tree,
      git_dir = resolved_git_dir,
      signature = signature,
      lines = operation_lines,
    }
  end
  for _, line in ipairs(operation_lines or {}) do table.insert(lines, line) end
  table.insert(lines, 'Help: g?')

  if not opts.fast and model.upstream and model.behind > 0 then
    if previous and previous.work_tree == model.work_tree and previous.oid == model.oid
      and previous.upstream == model.upstream and model.upstream_oid
      and previous.upstream_oid == model.upstream_oid and previous.behind == model.behind
      and previous.unpulled
    then
      model.unpulled = previous.unpulled
    else
      model.unpulled = commit_lines(model.work_tree, 'HEAD..' .. model.upstream)
    end
  end

  local entries_by_row = {}
  append_section(lines, entries_by_row, model, 'Unmerged paths', 'conflicted', model.conflicted)
  append_section(lines, entries_by_row, model, 'Untracked files', 'untracked', model.untracked)
  append_section(lines, entries_by_row, model, 'Unstaged changes', 'unstaged', model.unstaged)
  append_section(lines, entries_by_row, model, 'Staged changes', 'staged', model.staged)
  model.entries_by_row = entries_by_row
  models[bufnr] = model
  M.take_ownership(bufnr)
  return lines
end

function M.snapshot(bufnr, work_tree, opts)
  local model, err = parse_status(bufnr, work_tree)
  if not model then return nil, err end
  return snapshot_from_model(bufnr, model, opts)
end

function M.snapshot_async(bufnr, work_tree, opts, callback)
  vim.system({
    'git', '--no-optional-locks', 'status', '--porcelain=v2', '-z', '--branch', '--untracked-files=all',
  }, { cwd = work_tree, text = true }, function(result)
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(bufnr) then return end
      if opts and opts.is_current and not opts.is_current() then return end
      local model, err = parse_status_result(work_tree, result)
      if not model then callback(nil, err); return end
      -- Keep displayed statistics until enrichment replaces them. Never carry
      -- counts across sections (staging), renames, or repositories.
      local previous = models[bufnr]
      if previous and previous.work_tree == work_tree then
        if previous.oid == model.oid and previous.upstream == model.upstream
          and previous.behind == model.behind
        then
          model.unpulled = previous.unpulled
          model.upstream_oid = previous.upstream_oid
        end
        for _, section in ipairs({ 'staged', 'unstaged', 'untracked' }) do
          local entries = {}
          for _, entry in ipairs(previous[section]) do entries[entry.path] = entry end
          for _, entry in ipairs(model[section]) do
            local cached = entries[entry.path]
            if cached and cached.status == entry.status and cached.old_path == entry.old_path then
              entry.additions = cached.additions
              entry.deletions = cached.deletions
              entry.binary = cached.binary
            end
          end
        end
      end
      local subjects = subject_cache(bufnr, work_tree)
      local head = subjects.HEAD
      if head and head.oid == model.oid then model.head_subject = head.subject end
      local upstream = model.upstream and subjects[model.upstream]
      if upstream then model.upstream_subject = upstream.subject end
      model.push = previous and previous.upstream == model.upstream and previous.push or model.upstream
      if model.push and model.push ~= model.upstream then
        local push = subjects[model.push]
        if push then model.push_subject = push.subject end
      end
      local lines, snapshot_err = snapshot_from_model(bufnr, model, vim.tbl_extend('force', opts or {}, {
        fast = true,
      }))
      callback(lines, snapshot_err)
    end)
  end)
end

function M.entry_at(bufnr, row)
  local model = models[bufnr]
  return model and model.entries_by_row[row] or nil
end

function M.conflict_worktree_line(bufnr, row)
  local entry = M.entry_at(bufnr, row)
  if not entry or entry.section ~= 'conflicted' or entry.header then return nil end
  local direct = M.entry_row(bufnr, row)
  return direct and entry.conflict_worktree_lines
    and entry.conflict_worktree_lines[row - direct] or nil
end

function M.apply_conflict_highlights(bufnr, ns)
  local model = models[bufnr]
  if not model then return end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for row, entry in pairs(model.entries_by_row) do
    local previous = model.entries_by_row[row - 1]
    if entry.section == 'conflicted' and not entry.header and previous ~= entry then
      for offset in pairs(entry.conflict_highlight_lines or {}) do
        local target = row + offset
        local line = lines[target]
        if model.entries_by_row[target] == entry and line
          and (line:sub(1, 1) == '+' or line:sub(1, 1) == '-')
        then
          vim.api.nvim_buf_set_extmark(bufnr, ns, target - 1, 0, {
            end_row = target, end_col = 0, hl_group = 'GitStatusConflictLine',
            hl_eol = true, priority = 205,
          })
        end
      end
    end
  end
end

function M.shift_entries(bufnr, from_row, delta)
  local model = models[bufnr]
  if not model or delta == 0 then return end
  local shifted = {}
  for row, entry in pairs(model.entries_by_row) do
    shifted[row >= from_row and row + delta or row] = entry
  end
  model.entries_by_row = shifted
end

function M.entry_row(bufnr, row)
  local model = models[bufnr]
  local entry = M.entry_at(bufnr, row)
  if not model or not entry then return nil end
  local direct_row
  for candidate, value in pairs(model.entries_by_row) do
    if value == entry and (not direct_row or candidate < direct_row) then direct_row = candidate end
  end
  return direct_row
end

function M.paths_in_range(bufnr, first_row, last_row)
  local model = models[bufnr]
  if not model then return {} end
  local paths, seen = {}, {}
  for row = first_row, last_row do
    local entry = model.entries_by_row[row]
    if entry and not entry.header and entry.path and not seen[entry.path] then
      seen[entry.path] = true
      table.insert(paths, entry.path)
    end
  end
  return paths
end

function M.unpushed_commits(bufnr)
  local model = models[bufnr]
  if not model then return {} end
  if model.push then
    local commits, ok = commit_lines(model.work_tree, model.push .. '..HEAD')
    if ok then return commits end
  end

  local remotes = run(model.work_tree, { 'remote' })
  if remotes.code ~= 0 or vim.trim(remotes.stdout or '') == '' then return {} end
  return commit_lines(model.work_tree, { 'HEAD', '--not', '--remotes' })
end

function M.unpushed_commits_async(bufnr, callback)
  local model = models[bufnr]
  if not model then callback({}); return end
  local work_tree = model.work_tree
  if model.push then
    commit_lines_async(work_tree, model.push .. '..HEAD', function(commits, ok)
      if ok then callback(commits); return end
      callback({})
    end)
    return
  end

  run_async(work_tree, { 'remote' }, function(result)
    if result.code ~= 0 or vim.trim(result.stdout or '') == '' then callback({}); return end
    commit_lines_async(work_tree, { 'HEAD', '--not', '--remotes' }, function(commits)
      callback(commits)
    end)
  end)
end

function M.recent_commits_async(bufnr, limit, callback)
  local model = models[bufnr]
  if not model then callback({}); return end
  local args = {
    'log',
    '--date=format:%Y-%m-%d %H:%M',
    '--pretty=format:%h%x09%ad%x09%s',
    '-n',
    tostring(limit),
    'HEAD',
    '--',
  }
  run_async(model.work_tree, args, function(result)
    local commits = parse_commit_lines(result)
    callback(commits)
  end)
end

function M.unpulled_commits(bufnr)
  local model = models[bufnr]
  if not model or not model.unpulled then return nil, nil end
  return model.unpulled, model.upstream
end

local section_entries

function M.toggle_diff(bufnr, row)
  local entry = M.entry_at(bufnr, row)
  if not entry then return false end
  expanded[bufnr] = expanded[bufnr] or {}
  if entry.header then
    local entries = section_entries(models[bufnr], entry.section)
    local expand = false
    for _, item in ipairs(entries) do
      if not is_expanded(bufnr, item) then expand = true; break end
    end
    for _, item in ipairs(entries) do expanded[bufnr][entry_key(item)] = expand end
    return #entries > 0
  end
  local key = entry_key(entry)
  expanded[bufnr][key] = not is_expanded(bufnr, entry)
  return true
end

function M.set_diff(bufnr, row, value)
  local entry = M.entry_at(bufnr, row)
  if not entry then return false end
  expanded[bufnr] = expanded[bufnr] or {}
  if entry.header then
    local entries = section_entries(models[bufnr], entry.section)
    for _, item in ipairs(entries) do expanded[bufnr][entry_key(item)] = value end
    return #entries > 0
  end
  expanded[bufnr][entry_key(entry)] = value
  return true
end

section_entries = function(model, section)
  if section == 'staged' then return model.staged end
  if section == 'unstaged' then return model.unstaged end
  if section == 'untracked' then return model.untracked end
  if section == 'conflicted' then return model.conflicted end
  return {}
end

local function update_entry_rows(model, direct_row, end_row, entry, replacement_count)
  local removed = end_row - direct_row
  local delta = replacement_count - removed
  local updated = {}
  for old_row, value in pairs(model.entries_by_row) do
    if old_row <= direct_row then
      updated[old_row] = value
    elseif old_row > end_row then
      updated[old_row + delta] = value
    end
  end
  for offset = 1, replacement_count do updated[direct_row + offset] = entry end
  model.entries_by_row = updated
end

local function direct_row_for_entry(model, entry)
  local row
  for candidate, value in pairs(model.entries_by_row) do
    if value == entry and (not row or candidate < row) then row = candidate end
  end
  return row
end

function M.update_diff(bufnr, row, mode)
  local model = models[bufnr]
  local selected = M.entry_at(bufnr, row)
  if not model or not selected then return false end
  local entries = selected.header and section_entries(model, selected.section) or { selected }
  if #entries == 0 then return false end

  expanded[bufnr] = expanded[bufnr] or {}
  local expand = mode == 'show'
  if mode == 'toggle' then
    expand = false
    for _, entry in ipairs(entries) do
      if not is_expanded(bufnr, entry) then expand = true; break end
    end
  end
  local changed_entries = {}
  for _, entry in ipairs(entries) do
    local key = entry_key(entry)
    if is_expanded(bufnr, entry) ~= expand then table.insert(changed_entries, entry) end
    expanded[bufnr][key] = expand
  end
  if #changed_entries == 0 then return true end

  local ordered = {}
  for _, entry in ipairs(changed_entries) do
    local direct_row = direct_row_for_entry(model, entry)
    if direct_row then table.insert(ordered, { entry = entry, row = direct_row }) end
  end
  table.sort(ordered, function(left, right) return left.row > right.row end)

  local previous_modifiable = vim.bo[bufnr].modifiable
  local previous_readonly = vim.bo[bufnr].readonly
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].readonly = false
  local ok, err = pcall(function()
    for _, item in ipairs(ordered) do
      local direct_row = direct_row_for_entry(model, item.entry)
      local end_row = direct_row
      while model.entries_by_row[end_row + 1] == item.entry do end_row = end_row + 1 end
      local replacement = expand and diff_lines(model, item.entry) or {}
      vim.api.nvim_buf_set_lines(bufnr, direct_row, end_row, false, replacement)
      update_entry_rows(model, direct_row, end_row, item.entry, #replacement)
    end
  end)
  vim.bo[bufnr].modifiable = previous_modifiable
  vim.bo[bufnr].readonly = previous_readonly
  vim.bo[bufnr].modified = false
  if not ok then
    vim.notify('Failed to update inline diff: ' .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  return true
end

local function change_entry_paths(entries, action)
  if #entries == 0 then return nil, nil, 'Section is empty' end
  local stage_paths, unstage_paths = {}, {}
  local stage_seen, unstage_seen = {}, {}
  for _, item in ipairs(entries) do
    local should_stage = action == 'stage' or (action == 'toggle' and item.section ~= 'staged')
    local should_unstage = action == 'unstage' or (action == 'toggle' and item.section == 'staged')
    if should_stage and item.section ~= 'staged' and not stage_seen[item.path] then
      stage_seen[item.path] = true
      table.insert(stage_paths, item.path)
    elseif should_unstage and item.section == 'staged' and not unstage_seen[item.path] then
      unstage_seen[item.path] = true
      table.insert(unstage_paths, item.path)
    end
  end
  if #stage_paths == 0 and #unstage_paths == 0 then return nil, nil, 'Nothing to update here' end
  return stage_paths, unstage_paths
end

local function change_entries(model, entries, action)
  local stage_paths, unstage_paths, path_err = change_entry_paths(entries, action)
  if not stage_paths then return false, path_err end

  if #stage_paths > 0 then
    local args = { 'add', '--' }
    vim.list_extend(args, stage_paths)
    local result = run(model.work_tree, args)
    if result.code ~= 0 then return false, vim.trim(result.stderr or 'Git add failed') end
  end
  if #unstage_paths > 0 then
    local args = { 'restore', '--staged', '--' }
    vim.list_extend(args, unstage_paths)
    local result = run(model.work_tree, args)
    if result.code ~= 0 then
      args = { 'reset', '--' }
      vim.list_extend(args, unstage_paths)
      result = run(model.work_tree, args)
    end
    if result.code ~= 0 then return false, vim.trim(result.stderr or 'Git reset failed') end
  end
  return true
end

local function change_entries_async(model, entries, action, callback)
  local stage_paths, unstage_paths, path_err = change_entry_paths(entries, action)
  if not stage_paths then callback(false, path_err); return end

  local function unstage()
    if #unstage_paths == 0 then callback(true); return end
    local args = { 'restore', '--staged', '--' }
    vim.list_extend(args, unstage_paths)
    run_async(model.work_tree, args, function(result)
      if result.code == 0 then callback(true); return end
      local fallback = { 'reset', '--' }
      vim.list_extend(fallback, unstage_paths)
      run_async(model.work_tree, fallback, function(reset_result)
        if reset_result.code == 0 then callback(true); return end
        callback(false, vim.trim(reset_result.stderr or 'Git reset failed'))
      end)
    end)
  end

  if #stage_paths == 0 then unstage(); return end
  local args = { 'add', '--' }
  vim.list_extend(args, stage_paths)
  run_async(model.work_tree, args, function(result)
    if result.code ~= 0 then
      callback(false, vim.trim(result.stderr or 'Git add failed'))
      return
    end
    unstage()
  end)
end

local function accept_conflict(bufnr, row)
  local model = models[bufnr]
  local entry = M.entry_at(bufnr, row)
  local chosen = entry and chosen_conflict_side_by_buf[bufnr]
  chosen = chosen and chosen[entry.path]
  if chosen then
    local stages, err = conflict_stages(model, entry)
    if not stages then return false, err end
    if not vim.deep_equal(stages, chosen.stages)
      or (entry.conflict_stages and not vim.deep_equal(stages, entry.conflict_stages))
    then
      return false, 'The displayed conflict has changed; refresh status'
    end
    return M.mark_resolved(bufnr, row)
  end
  return M.resolve_conflict(bufnr, row, 'theirs', true)
end

function M.change_index(bufnr, row, action)
  local model = models[bufnr]
  local entry = M.entry_at(bufnr, row)
  if not model or not entry then return false, 'No status entry at cursor' end
  if entry.section == 'conflicted' then
    if action == 'unstage' then return false, 'Only staged changes can be unstaged' end
    if entry.header then
      local rows = {}
      for _, item in ipairs(model.conflicted) do
        local direct = direct_row_for_entry(model, item)
        if direct then rows[#rows + 1] = direct end
      end
      if #rows == 0 then return false, 'Section is empty' end
      for _, direct in ipairs(rows) do
        local ok, err = accept_conflict(bufnr, direct)
        if not ok then return false, err end
      end
      return true
    end
    return accept_conflict(bufnr, row)
  end
  local patched, err = patch_selection(bufnr, model, row, row, action)
  if patched ~= nil then return patched, err end
  local entries = entry.header and section_entries(model, entry.section) or { entry }
  return change_entries(model, entries, action)
end

function M.change_index_range(bufnr, first_row, last_row, action)
  local model = models[bufnr]
  if not model then return false, 'Status model is unavailable' end
  local patched, err = patch_selection(bufnr, model, first_row, last_row, action, true)
  if patched ~= nil then return patched, err end
  local entries = {}
  local conflict_rows, seen = {}, {}
  for row = first_row, last_row do
    local entry = M.entry_at(bufnr, row)
    if entry and not entry.header then
      if entry.section == 'conflicted' then
        if row ~= M.entry_row(bufnr, row) then
          return false, 'Select the conflict file row to choose the whole side'
        end
        if not seen[entry] then conflict_rows[#conflict_rows + 1] = row; seen[entry] = true end
      else
        entries[#entries + 1] = entry
      end
    end
  end
  if #conflict_rows > 0 and action == 'unstage' then
    return false, 'Only staged changes can be unstaged'
  end
  for _, row in ipairs(conflict_rows) do
    local ok, err = accept_conflict(bufnr, row)
    if not ok then return false, err end
  end
  if #entries == 0 then return #conflict_rows > 0 end
  return change_entries(model, entries, action)
end

function M.change_index_async(bufnr, row, action, callback)
  local model = models[bufnr]
  local entry = M.entry_at(bufnr, row)
  if not model or not entry then callback(false, 'No status entry at cursor'); return end
  if entry.section == 'conflicted' then
    callback(M.change_index(bufnr, row, action))
    return
  end
  local patched, err = patch_selection(bufnr, model, row, row, action)
  if patched ~= nil then callback(patched, err); return end
  local entries = entry.header and section_entries(model, entry.section) or { entry }
  change_entries_async(model, entries, action, callback)
end

function M.change_index_range_async(bufnr, first_row, last_row, action, callback)
  local model = models[bufnr]
  if not model then callback(false, 'Status model is unavailable'); return end
  for row = first_row, last_row do
    local entry = M.entry_at(bufnr, row)
    if entry and not entry.header and entry.section == 'conflicted' then
      callback(M.change_index_range(bufnr, first_row, last_row, action))
      return
    end
  end
  local patched, err = patch_selection(bufnr, model, first_row, last_row, action, true)
  if patched ~= nil then callback(patched, err); return end
  local entries = {}
  for row = first_row, last_row do
    local entry = M.entry_at(bufnr, row)
    if entry and not entry.header then table.insert(entries, entry) end
  end
  change_entries_async(model, entries, action, callback)
end

function M.reset_index(bufnr)
  local model = models[bufnr]
  if not model then return false, 'Status model is unavailable' end
  local result = run(model.work_tree, { 'reset', '--quiet' })
  if result.code ~= 0 then return false, vim.trim(result.stderr or 'Git reset failed') end
  return true
end

function M.stage_all(bufnr)
  local model = models[bufnr]
  if not model then return false, 'Status model is unavailable' end
  local result = run(model.work_tree, { 'add', '-A' })
  if result.code ~= 0 then return false, vim.trim(result.stderr or 'Git add failed') end
  return true
end

function M.reset_index_async(bufnr, callback)
  local model = models[bufnr]
  if not model then callback(false, 'Status model is unavailable'); return end
  run_async(model.work_tree, { 'reset', '--quiet' }, function(result)
    callback(result.code == 0, result.code == 0 and nil or vim.trim(result.stderr or 'Git reset failed'))
  end)
end

function M.stage_all_async(bufnr, callback)
  local model = models[bufnr]
  if not model then callback(false, 'Status model is unavailable'); return end
  run_async(model.work_tree, { 'add', '-A' }, function(result)
    callback(result.code == 0, result.code == 0 and nil or vim.trim(result.stderr or 'Git add failed'))
  end)
end

function M.collapse_all(bufnr)
  if not models[bufnr] then return false end
  expanded[bufnr] = {}
  return true
end

function M.discard(bufnr, row)
  local model = models[bufnr]
  local entry = M.entry_at(bufnr, row)
  if not model or not entry or entry.header then return false, 'No status entry at cursor' end
  if entry.section == 'conflicted' then
    return M.resolve_conflict(bufnr, row, 'ours', true)
  end
  local patched, err = patch_selection(bufnr, model, row, row, 'discard')
  if patched ~= nil then return patched, err end
  if entry.section == 'untracked' then
    local absolute = vim.fs.joinpath(model.work_tree, entry.path)
    local flags = vim.fn.isdirectory(absolute) == 1 and 'rf' or ''
    if vim.fn.delete(absolute, flags) ~= 0 then return false, 'Failed to delete ' .. entry.path end
    return true
  end

  local args = { 'restore' }
  if entry.section == 'staged' then vim.list_extend(args, { '--staged', '--worktree' }) end
  vim.list_extend(args, { '--', entry.path })
  local result = run(model.work_tree, args)
  if result.code ~= 0 then return false, vim.trim(result.stderr or 'Git restore failed') end
  return true
end

function M.discard_range(bufnr, first_row, last_row)
  local model = models[bufnr]
  if not model then return false, 'Status model is unavailable' end
  local patched, err = patch_selection(bufnr, model, first_row, last_row, 'discard', true)
  if patched ~= nil then return patched, err end

  local direct_rows = {}
  for row = 1, last_row do
    local entry = model.entries_by_row[row]
    if entry and not entry.header and not direct_rows[entry] then direct_rows[entry] = row end
  end
  local entries, by_path = {}, {}
  for row = first_row, last_row do
    local entry = model.entries_by_row[row]
    if entry and not entry.header then
      if row ~= direct_rows[entry] then
        return false, 'Select changed lines within one hunk, or select file rows'
      end
      local previous = by_path[entry.path]
      if not previous then
        entries[#entries + 1] = entry
        by_path[entry.path] = #entries
      elseif entry.section == 'staged' then
        entries[previous] = entry
      end
    end
  end
  if #entries == 0 then return false, 'No discardable item in selection' end
  for _, entry in ipairs(entries) do
    local ok, discard_err = M.discard(bufnr, direct_rows[entry])
    if not ok then return false, discard_err end
  end
  return true
end

local function prepare_conflict_undo_buffer(absolute)
  local file_buf = vim.fn.bufadd(absolute)
  if vim.bo[file_buf].modified then
    return nil, 'Save or discard unsaved edits in ' .. absolute .. ' before choosing a side'
  end
  local loaded, load_err = pcall(vim.fn.bufload, file_buf)
  if not loaded then return nil, 'Could not load ' .. absolute .. ': ' .. tostring(load_err) end
  if vim.bo[file_buf].modified then
    return nil, 'Save or discard unsaved edits in ' .. absolute .. ' before choosing a side'
  end
  -- Reload any external edits first so the next reload's undo state is the
  -- worktree content immediately before the checkout.
  local ok, err = pcall(vim.api.nvim_buf_call, file_buf, function() vim.cmd('edit!') end)
  if not ok then return nil, 'Could not refresh ' .. absolute .. ': ' .. tostring(err) end
  return file_buf
end

function M.resolve_conflict(bufnr, row, side, mark_resolved)
  local model = models[bufnr]
  local entry = M.entry_at(bufnr, row)
  if not model or not entry or entry.header or entry.section ~= 'conflicted' then
    return false, 'No conflicted file at cursor'
  end
  if side ~= 'ours' and side ~= 'theirs' then return false, 'Unknown conflict side' end

  local stages, err = conflict_stages(model, entry)
  if not stages then return false, err end
  if entry.conflict_stages and not vim.deep_equal(stages, entry.conflict_stages) then
    return false, 'The displayed conflict has changed; refresh status'
  end
  local present = stages[side == 'ours' and 2 or 3] ~= nil

  local chosen = chosen_conflict_side_by_buf[bufnr]
  chosen = chosen and chosen[entry.path]
  local absolute = vim.fs.joinpath(model.work_tree, entry.path)
  local stat = vim.uv.fs_lstat(absolute)
  local worktree = not chosen and stages[2] and stages[3]
    and stat and stat.type == 'file' and read_worktree_content(model.work_tree, entry.path)
  local cache = conflict_diff_cache_by_buf[bufnr]
  local displayed = cache and cache[entry.path]
  if worktree and displayed and is_expanded(bufnr, entry) then
    local current_key = table.concat({ stages[2], stages[3], vim.fn.sha256(worktree) }, '\0')
    if displayed.key ~= current_key then
      return false, 'The displayed conflict has changed; refresh status'
    end
  end
  local blocks = worktree and conflict_blocks(worktree)
  if worktree and not blocks then
    return false, 'Incomplete conflict markers in worktree; edit them and use cr'
  end
  if blocks and #blocks == 0 then
    if mark_resolved then return M.mark_resolved(bufnr, row) end
    return false, 'No conflict markers in worktree; use cr to stage the edited result'
  end
  if blocks and #blocks > 0 then
    local selected
    local direct_row = M.entry_row(bufnr, row)
    if row > direct_row then
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      for candidate = row, direct_row + 1, -1 do
        if lines[candidate] and lines[candidate]:match('^@@') then
          selected = tonumber(lines[candidate]:match('conflict (%d+)'))
          break
        end
      end
      if not selected or not blocks[selected] then
        return false, 'No conflict marker for the selected hunk; select the file row'
      end
    end
    local file_buf, buffer_err = prepare_conflict_undo_buffer(absolute)
    if not file_buf then return false, buffer_err end
    local file, open_err = io.open(absolute, 'wb')
    if not file then return false, open_err or ('Could not write ' .. entry.path) end
    local ok, write_err = file:write(resolve_conflict_blocks(worktree, blocks, side, selected))
    file:close()
    if not ok then return false, write_err or ('Could not write ' .. entry.path) end
    local reloaded, reload_err = pcall(vim.api.nvim_buf_call, file_buf, function() vim.cmd('edit!') end)
    if not reloaded then return false, 'Could not refresh ' .. entry.path .. ': ' .. tostring(reload_err) end
    if mark_resolved and (not selected or #blocks == 1) then
      local staged = run(model.work_tree, { 'add', '-A', '--', entry.path })
      if staged.code ~= 0 then
        return false, 'Resolved conflict markers, but could not stage result: '
          .. vim.trim(staged.stderr or 'Git add failed')
      end
    end
    chosen_conflict_side_by_buf[bufnr] = chosen_conflict_side_by_buf[bufnr] or {}
    chosen_conflict_side_by_buf[bufnr][entry.path] = not mark_resolved
      and (not selected or #blocks == 1) and { side = side, stages = stages } or nil
    return true
  end

  -- A missing stage means that side deleted the path. Checkout cannot select it.
  local file_buf, buffer_err = prepare_conflict_undo_buffer(absolute)
  if not file_buf then return false, buffer_err end
  local args = present and { 'checkout', '--' .. side, '--', entry.path }
    or { 'rm', '--', entry.path }
  local result = run(model.work_tree, args)
  if result.code ~= 0 then
    return false, vim.trim(result.stderr or ('Failed to choose ' .. side .. ' for ' .. entry.path))
  end
  local reloaded, reload_err = pcall(vim.api.nvim_buf_call, file_buf, function() vim.cmd('edit!') end)
  if not reloaded then
    return false, 'Selected ' .. side .. ', but could not refresh the file buffer: '
      .. tostring(reload_err)
  end
  if mark_resolved and present then
    local staged = run(model.work_tree, { 'add', '-A', '--', entry.path })
    if staged.code ~= 0 then
      return false, 'Selected ' .. side .. ', but could not stage it: '
        .. vim.trim(staged.stderr or 'Git add failed')
    end
  end
  chosen_conflict_side_by_buf[bufnr] = chosen_conflict_side_by_buf[bufnr] or {}
  chosen_conflict_side_by_buf[bufnr][entry.path] = not mark_resolved and present
    and { side = side, stages = stages } or nil
  return true
end

function M.mark_resolved(bufnr, row)
  local model = models[bufnr]
  local entry = M.entry_at(bufnr, row)
  if not model or not entry or entry.header or entry.section ~= 'conflicted' then
    return false, 'No conflicted file at cursor'
  end
  local result = run(model.work_tree, { 'add', '-A', '--', entry.path })
  if result.code ~= 0 then return false, vim.trim(result.stderr or 'Failed to mark conflict resolved') end
  if chosen_conflict_side_by_buf[bufnr] then chosen_conflict_side_by_buf[bufnr][entry.path] = nil end
  return true
end

function M.patch_command(bufnr, row)
  local entry = M.entry_at(bufnr, row)
  if not entry then return nil, 'No status entry at cursor' end
  local args
  if entry.section == 'staged' then
    args = 'Git reset --patch'
  elseif entry.section == 'unstaged' or entry.section == 'conflicted' then
    args = 'Git add --patch'
  elseif entry.section == 'untracked' then
    args = 'Git add --interactive'
  else
    return nil, 'Patch mode is unavailable here'
  end
  if not entry.header then args = args .. ' -- ' .. vim.fn.fnameescape(entry.path) end
  return 'tab ' .. args
end

local function blob_lines(model, revision, path)
  local result = run(model.work_tree, { 'show', revision .. ':' .. path })
  if result.code ~= 0 then return {} end
  local value = (result.stdout or ''):gsub('\r\n', '\n')
  local lines = vim.split(value, '\n', { plain = true })
  if lines[#lines] == '' then table.remove(lines) end
  return lines
end

local function worktree_lines(model, path)
  local absolute = vim.fs.joinpath(model.work_tree, path)
  if vim.fn.filereadable(absolute) ~= 1 then return {} end
  local ok, lines = pcall(vim.fn.readfile, absolute, 'b')
  return ok and lines or {}
end

function M.diff_sides(bufnr, row)
  local model = models[bufnr]
  local entry = M.entry_at(bufnr, row)
  if not model or not entry or entry.header then return nil, 'No status entry at cursor' end
  if vim.fn.isdirectory(vim.fs.joinpath(model.work_tree, entry.path)) == 1 then
    return nil, 'Cannot diff a directory'
  end

  return {
    path = entry.path,
    left = entry.section == 'untracked' and {} or blob_lines(model, 'HEAD', entry.old_path or entry.path),
    right = worktree_lines(model, entry.path),
    left_label = entry.section == 'untracked' and 'empty' or 'HEAD',
    right_label = 'current file',
  }
end

function M.conflict_sides(bufnr, row)
  local model = models[bufnr]
  local entry = M.entry_at(bufnr, row)
  if not model or not entry or entry.header or entry.section ~= 'conflicted' then
    return nil, 'No conflicted file at cursor'
  end
  return {
    path = entry.path,
    { label = 'base', lines = blob_lines(model, ':1', entry.path) },
    { label = 'ours', lines = blob_lines(model, ':2', entry.path) },
    { label = 'theirs', lines = blob_lines(model, ':3', entry.path) },
  }
end

function M.cleanup(bufnr)
  models[bufnr] = nil
  expanded[bufnr] = nil
  subjects_by_buf[bufnr] = nil
  operation_cache_by_buf[bufnr] = nil
  chosen_conflict_side_by_buf[bufnr] = nil
  conflict_diff_cache_by_buf[bufnr] = nil
end

return M

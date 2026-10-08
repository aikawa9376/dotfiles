-- Git view identities for Harpoon. Never persist buffer/window IDs or replay actions.
local M = {}
local api = vim.api
local panels = { gitstatus = 'status', gitlog = 'log', gitbranch = 'branch',
  gitreflog = 'reflog', gitstash = 'stash', gitworktree = 'worktree', gitwip = 'wip' }

local function git(root, args)
  local argv = { 'git', '--no-pager', '--no-optional-locks', '-C', root }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  if result.code ~= 0 then error(vim.trim(result.stderr or 'Git object unavailable'), 0) end
  return result.stdout or ''
end
local function commit(root, revision)
  if not revision or revision == '' then return nil end
  return vim.trim(git(root, { 'rev-parse', '--verify', '--end-of-options', revision .. '^{commit}' }))
end
local function line(buf, row) return api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or '' end

function M.capture(buf, pos, with_preview)
  buf = (not buf or buf == 0) and api.nvim_get_current_buf() or buf
  pos = pos or api.nvim_win_get_cursor(0)
  local ft, name = vim.bo[buf].filetype, api.nvim_buf_get_name(buf)
  -- Ordinary files need no Git modules loaded. Code in an active blame pair is an exception.
  local blame = package.loaded['git.features.blame']
  local nav = blame and blame.navigation(buf)
  if nav then
    nav.view, nav.row, nav.col = 'blame', pos[1], pos[2]
    nav.revision = commit(nav.root, nav.revision)
    return nav
  end
  local view = panels[ft]
  local object = vim.b[buf].git_object
  local source = vim.b[buf].lazyagent_note_source
  local graph = vim.b[buf].git_graph
  if not view and not object and not vim.b[buf].custom_git_commit and not graph
    and ft ~= 'floggraph' and not (ft == 'git' and vim.b[buf].git_command)
    and not (name:match('^git%-commit%-blob://') and source) then return nil end
  local root = require('git.utils').get_buf_work_tree(buf)
  if not root then return nil end
  nav = { root = root, view = view, row = pos[1], col = pos[2] }
  if vim.b[buf].custom_git_commit then
    nav = vim.tbl_extend('force', nav, require('git.features.commit').navigation(buf, pos[1]))
    nav.view = 'commit'
  elseif object or name:match('^git%-commit%-blob://') then
    source = object or source
    nav.view, nav.path, nav.stage = 'object', source.path, source.stage
    nav.revision = source.stage and nil or commit(root, source.revision ~= 'blob' and source.revision or nil)
    nav.object = source.object or (nav.revision .. ':' .. nav.path)
    if nav.revision and nav.path then nav.object = nav.revision .. ':' .. nav.path end
    nav.base = vim.b[buf].git_blob_base
    nav.base_path = vim.b[buf].git_blob_base_path
  elseif view == 'status' then
    nav.anchor = require('git.features.status').navigation(buf, api.nvim_get_current_win())
  elseif view == 'branch' then
    nav.filter = vim.b[buf].branch_filter or 'all'
    nav.ref = (vim.b[buf].branch_map or {})[pos[1]]
    nav.ref_kind = (vim.b[buf].branch_kinds or {})[pos[1]]
  elseif view == 'worktree' then
    local entry = (vim.b[buf].worktree_entries or {})[pos[1]]
    nav.path = entry and entry.path
  elseif view == 'log' then
    nav.args = vim.b[buf].git_log_args or ''
    nav.menu_flags = vim.b[buf].git_log_menu_flags
    nav.line_history = vim.b[buf].git_log_line_history
    if nav.line_history then
      nav.line_history.revision = commit(root, nav.line_history.revision or 'HEAD')
    end
    nav.hash = commit(root, line(buf, pos[1]):match('^(%x%x%x%x%x%x%x+)%s'))
  elseif view == 'reflog' then
    local entry = require('git.features.reflog').entry_at(buf, pos[1])
    if entry then nav.hash, nav.timestamp, nav.action, nav.detail = entry.hash, entry.timestamp, entry.action, entry.detail end
  elseif view == 'stash' then
    nav.hash = commit(root, line(buf, pos[1]):match('^(stash@{%d+})'))
  elseif view == 'wip' then
    local entry = (vim.b[buf].git_wip_entries or {})[pos[1] - 1]
    nav.hash = entry and entry.hash
  elseif graph or ft == 'floggraph' then
    nav.view, nav.backend = 'graph', graph and 'native' or 'flog'
    if graph then nav.revision = graph.revision
    else
      local state = vim.b[buf].flog_state
      nav.flog_opts = state and state.opts
      if nav.flog_opts then nav.flog_opts.open_cmd = nil end
      nav.hash = commit(root, api.nvim_buf_call(buf, function() return vim.fn['flog#Format']('%H') end))
    end
    if graph then nav.hash = commit(root, line(buf, pos[1]):match('[|%s*/\\_-]*(%x%x%x%x%x%x%x+) ')) end
  else
    -- Output can originate from any Git invocation. Reopen a snapshot, never rerun it.
    nav.view, nav.args, nav.lines = 'output', vim.b[buf].git_command, api.nvim_buf_get_lines(buf, 0, -1, false)
  end
  -- Retain the renderer's rows instead of trying to map them onto `git show`.
  -- Draft messages stay in Neovim, outside persisted Harpoon data.
  if with_preview and nav.view ~= 'object'
    and not (nav.view == 'commit' and vim.bo[buf].modified) then
    nav.preview = require('plugins.harpoon_preview_buffer').capture(buf, pos)
    if nav.view == 'output' then nav.preview.lines = nil end
  end
  return vim.deepcopy(nav)
end

-- Explicit fields make identity independent of transient layout and JSON key order.
local function canonical(value)
  if type(value) ~= 'table' then return value end
  if vim.islist(value) then
    local list = {}
    for i, v in ipairs(value) do list[i] = canonical(v) end
    return list
  end
  local keys, pairs_list = {}, {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do pairs_list[#pairs_list + 1] = { key, canonical(value[key]) } end
  return pairs_list
end
function M.identity(nav)
  local a = nav.anchor or {}
  return vim.json.encode({ nav.root, nav.view, nav.revision or '', nav.object or '', nav.parent or 0,
    nav.base or '', nav.base_path or '',
    nav.path or '', nav.patch_row or 0, nav.hash or '', nav.ref or '', nav.ref_kind or '',
    nav.filter or '', canonical(nav.args or ''), canonical(nav.line_history or false), nav.backend or '', canonical(nav.flog_opts or false),
    a.key_type or '', a.stash_hash or a.commit_hash or a.key or '', a.section or '', a.entry_text or '', a.entry_offset or 0,
    nav.timestamp or 0, nav.action or '', nav.detail or '',
    (nav.view == 'object' or nav.view == 'blame') and nav.row or 0 })
end
function M.label(nav)
  -- Full repository identity prevents identical labels for equally named worktrees.
  local label = vim.fn.fnamemodify(nav.root, ':~') .. ' · ' .. nav.view:gsub('^%l', string.upper)
  local target = nav.revision or nav.hash
  if target then label = label .. ' ' .. target:sub(1, 8) end
  if nav.ref then label = label .. ' · ' .. nav.ref end
  if nav.ref_kind then label = label .. ' [' .. nav.ref_kind .. ']' end
  if nav.stage then label = label .. ' [index ' .. nav.stage .. ']' end
  if nav.view == 'object' and not nav.path then label = label .. ' · ' .. nav.object end
  if nav.path then label = label .. ' · ' .. nav.path end
  if nav.anchor and nav.anchor.key and nav.anchor.key ~= '' then
    label = label .. ' · ' .. (nav.anchor.stash_hash and ('stash ' .. nav.anchor.stash_hash:sub(1, 8)) or nav.anchor.key)
    if nav.anchor.section then label = label .. ' [' .. nav.anchor.section .. ']' end
    if nav.anchor.entry_offset then label = label .. ' +' .. nav.anchor.entry_offset end
  end
  if nav.view == 'log' and nav.args ~= '' then label = label .. ' · ' .. nav.args end
  if nav.line_history then
    label = label .. (' · %s:%d–%d'):format(nav.line_history.path, nav.line_history.first, nav.line_history.last)
  end
  if nav.view == 'branch' then label = label .. ' [' .. nav.filter .. ']' end
  if nav.view == 'reflog' and nav.hash then
    label = label .. ' · ' .. (nav.action or '') .. ': ' .. (nav.detail or '')
      .. ' [' .. os.date('%Y-%m-%d %H:%M:%S', nav.timestamp) .. ']'
  end
  if nav.view == 'graph' then
    label = label .. ' [' .. nav.backend .. ']'
    if nav.flog_opts then
      -- Flog has many independent filters; keep their distinct pins distinguishable.
      label = label .. ' · ' .. vim.fn.sha256(vim.json.encode(canonical(nav.flog_opts))):sub(1, 8)
    end
  end
  if nav.view == 'object' or nav.view == 'blame' then label = label .. ':' .. nav.row end
  if nav.patch_row then label = label .. ' · diff ' .. nav.patch_row end
  if nav.base then label = label .. ' [base ' .. nav.base:sub(1, 8) .. ']' end
  if nav.view == 'output' then label = label .. ' snapshot · ' .. table.concat(nav.args, ' ') end
  return label:gsub('[\r\n\t]', ' ')
end
function M.position(buf, row, col)
  row = math.max(1, math.min(tonumber(row) or 1, api.nvim_buf_line_count(buf)))
  api.nvim_win_set_cursor(0, { row, math.max(0, math.min(tonumber(col) or 0, #line(buf, row))) })
end

local function focus(nav, buf)
  if nav.view == 'commit' then
    require('git.features.commit').restore_navigation(buf, nav)
    if not nav.path then M.position(buf, nav.row, nav.col) end
    return
  end
  local found
  for row, text in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if nav.view == 'branch' then
      found = nav.ref and (vim.b[buf].branch_map or {})[row] == nav.ref
        and (vim.b[buf].branch_kinds or {})[row] == nav.ref_kind
    elseif nav.view == 'worktree' then
      found = nav.path and ((vim.b[buf].worktree_entries or {})[row] or {}).path == nav.path
    elseif nav.view == 'reflog' then
      local e = require('git.features.reflog').entry_at(buf, row)
      found = e and e.hash == nav.hash and e.timestamp == nav.timestamp and e.action == nav.action and e.detail == nav.detail
    elseif nav.view == 'stash' then
      local ref = text:match('^(stash@{%d+})')
      found = ref and nav.hash and commit(nav.root, ref) == nav.hash
    elseif nav.view == 'wip' then
      found = nav.hash and ((vim.b[buf].git_wip_entries or {})[row - 1] or {}).hash == nav.hash
    elseif nav.hash then
      if nav.backend == 'flog' then
        local state = vim.b[buf].flog_state
        local index = state and state.line_commits[row]
        local e = index and state.commits[index + 1]
        found = e and (e.hash == nav.hash or e.hash == nav.hash:sub(1, #e.hash))
      else
        local hash = text:match('^(%x%x%x%x%x%x%x+)%s') or text:match('[|%s*/\\_-]*(%x%x%x%x%x%x%x+) ')
        found = hash and nav.hash:sub(1, #hash) == hash
      end
    end
    if found then M.position(buf, row, nav.col); return end
  end
  -- A disappearing list item must not silently select whatever took its old row.
  if nav.view == 'object' or nav.view == 'output' then M.position(buf, nav.row, nav.col)
  else M.position(buf, 1, 0) end
end

function M.open(nav)
  -- Resolve the lazy provider even when restored Harpoon data is the first Git entry point.
  if vim.fn.exists(':GitStatus') ~= 2 or not package.loaded['git.features.status'] then
    local ok, lazy = pcall(require, 'lazy')
    if ok then lazy.load({ plugins = { 'git' } }) end
  end
  assert(vim.fn.isdirectory(nav.root) == 1, 'Pinned repository no longer exists: ' .. nav.root)
  local buf
  if nav.view == 'blame' then return require('git.features.blame').open_navigation(nav)
  elseif nav.view == 'commit' then
    buf = require('git.features.commit').open({ work_tree = nav.root, revision = nav.revision, parent = nav.parent })
  elseif nav.view == 'object' then
    buf = require('git.objects').open(nav.object, 'edit', nav.root)
    if nav.base and nav.path then
      vim.b[buf].git_blob_base, vim.b[buf].git_blob_base_path = nav.base, nav.base_path
      require('git.objects').attach_gitsigns(buf, nav.root, nav.path, nav.base, nav.base_path)
    end
  elseif nav.view == 'status' then
    local status = require('git.features.status')
    buf = status.open({ work_tree = nav.root, split = true, focus = false })
    -- A warm panel may still show old stash selectors until its probe finishes.
    if buf then status.refresh_buffer(buf) end
  elseif nav.view == 'graph' then
    buf = require('git.graph').open(nav.revision, nav.backend, { work_tree = nav.root, flog_opts = nav.flog_opts })
  elseif nav.view == 'wip' then buf = require('git.features.wip').open(nav.root)
  elseif nav.view == 'output' then
    require('git.utils').open_panel_split()
    buf = api.nvim_get_current_buf()
    require('git.utils').set_buf_work_tree(buf, nav.root)
    api.nvim_buf_set_lines(buf, 0, -1, false, nav.lines)
    vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].filetype = 'nofile', 'wipe', 'git'
    vim.bo[buf].modifiable = false
    vim.b[buf].git_command = nav.args
  else
    buf = require('git.features.' .. nav.view).open({ work_tree = nav.root, args = nav.args,
      filter = nav.filter, menu_flags = nav.menu_flags, line_history = nav.line_history })
  end
  if not buf then return end
  if nav.view == 'status' and nav.anchor then
    local win, attempts = api.nvim_get_current_win(), 0
    local function restore()
      if not api.nvim_win_is_valid(win) or api.nvim_get_current_win() ~= win or api.nvim_win_get_buf(win) ~= buf then return end
      attempts = attempts + 1
      if not require('git.features.status').restore_navigation(buf, nav.anchor) and attempts < 100 then
        vim.defer_fn(restore, 30)
      end
    end
    restore()
  else focus(nav, buf) end
  return buf
end

function M.preview(nav)
  if nav.preview then
    return nav.preview.lines or nav.lines, nav.preview.row, nav.preview.col, nav.preview.syntax, nav.preview
  end
  local args, row = nil, 1
  if nav.view == 'output' then return nav.lines, nav.row, nav.col, 'git' end
  if nav.view == 'object' then
    args, row = { 'show', nav.object }, nav.row
  elseif nav.view == 'blame' then
    if not nav.revision then
      local lines
      for _, buf in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_get_name(buf) == nav.root .. '/' .. nav.path and api.nvim_buf_is_loaded(buf) then
          lines = api.nvim_buf_get_lines(buf, 0, -1, false); break
        end
      end
      return lines or vim.fn.readfile(nav.root .. '/' .. nav.path), nav.row, nav.col,
        vim.filetype.match({ filename = nav.path })
    end
    args, row = { 'show', nav.revision .. ':' .. nav.path }, nav.row
  elseif nav.view == 'status' then args = { 'status', '--short', '--branch' }
  elseif nav.view == 'worktree' then args = { 'worktree', 'list' }
  elseif nav.view == 'branch' then args = { 'for-each-ref', '--format=%(refname:short)  %(objectname:short)  %(subject)', 'refs/heads', 'refs/remotes', 'refs/tags' }
  elseif nav.view == 'stash' then args = { 'stash', 'list' }
  elseif nav.revision or nav.hash then args = { 'show', '-s', '--format=fuller', nav.revision or nav.hash, '--' }
  elseif nav.view == 'reflog' then args = { 'reflog', '-30' }
  else args = { 'log', '-30', '--oneline', '--decorate' } end
  local text = git(nav.root, args):gsub('\n$', '')
  if text:find('\0', 1, true) then return { 'Binary Git object' }, 1, 0, 'git' end
  return vim.split(text, '\n', { plain = true }), row, nav.col,
    (nav.view == 'object' or nav.view == 'blame') and vim.filetype.match({ filename = nav.path or '' }) or 'git'
end
return M

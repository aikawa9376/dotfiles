local M = {}
local utils = require("fugitive_utils")

local BLAME_COLORS = {
  '#50c878', '#70cd80', '#90d288', '#b0d790', '#d0dc98', '#f0e1a0', '#ffc580',
  '#ffb060', '#ff9b40', '#ff8620', '#ff7100', '#e85040', '#d03030',
}
local heatmap_ns = vim.api.nvim_create_namespace('fugitive_blame_heatmap')

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

local function apply_blame_gradient(bufnr)
  local ns_id = vim.api.nvim_create_namespace('fugitive_blame_gradient')
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  if vim.g.fugitive_blame_gradient_mode == 'absolute' then
    -- 絶対モード: 現在の日付から何ヶ月前かで判定
    local now = os.time()

    for idx, line in ipairs(lines) do
      local date_start, date_end = line:find('%d%d%d%d%-%d%d%-%d%d %d%d:%d%d')
      if date_start then
        local y, m, d, h, min = line:match('(%d%d%d%d)%-(%d%d)%-(%d%d) (%d%d):(%d%d)')
        if y then
          local commit_time = os.time({
            year = tonumber(y) or 0,
            month = tonumber(m) or 1,
            day = tonumber(d) or 1,
            hour = tonumber(h) or 0,
            min = tonumber(min) or 0,
          })
          local diff_months = math.floor((now - commit_time) / (30 * 24 * 60 * 60))

          -- 2ヶ月ごとに色を変える（0-24ヶ月を13段階に）
          local color_idx = math.min(math.floor(diff_months / 2), 12)

          vim.api.nvim_buf_set_extmark(bufnr, ns_id, idx - 1, date_start - 1, {
            end_col = date_end,
            hl_group = 'FugitiveBlameDate' .. color_idx,
          })
        end
      end
    end
  else
    -- 相対モード: ファイル内の最古と最新の日付を基準に
    local dates = {}

    for _, line in ipairs(lines) do
      local date = line:match('%d%d%d%d%-%d%d%-%d%d')
      if date then
        table.insert(dates, date)
      end
    end

    table.sort(dates)
    local oldest_date = dates[1]
    local newest_date = dates[#dates]

    if oldest_date and newest_date then
      local function date_to_days(date_str)
        local y, m, d = date_str:match('(%d%d%d%d)%-(%d%d)%-(%d%d)')
        return tonumber(y) * 365 + tonumber(m) * 30 + tonumber(d)
      end

      local oldest_days = date_to_days(oldest_date)
      local newest_days = date_to_days(newest_date)
      local range = newest_days - oldest_days

      for idx, line in ipairs(lines) do
        local date_start, date_end = line:find('%d%d%d%d%-%d%d%-%d%d %d%d:%d%d')
        if date_start then
          local date = line:match('%d%d%d%d%-%d%d%-%d%d')
          local days = date_to_days(date)

          local color_idx
          if range == 0 then
            color_idx = 0
          else
            local ratio = (days - oldest_days) / range
            color_idx = math.floor((1 - ratio) * 12)
          end

          vim.api.nvim_buf_set_extmark(bufnr, ns_id, idx - 1, date_start - 1, {
            end_col = date_end,
            hl_group = 'FugitiveBlameDate' .. color_idx,
          })
        end
      end
    end
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

function M.setup(group)
  setup_blame_gradients()

  -- グラデーションモード: 'absolute' または 'relative'
  vim.g.fugitive_blame_gradient_mode = vim.g.fugitive_blame_gradient_mode or 'absolute'

  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = setup_blame_gradients,
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

  local preview_state = {
    win = nil,
    buf = nil,
    augroup = nil,
    blame_bufnr = nil,
    last_commit = nil,
  }

  local function close_preview_window()
    if preview_state.win and vim.api.nvim_win_is_valid(preview_state.win) then
      vim.api.nvim_win_close(preview_state.win, true)
    end
    if preview_state.buf and vim.api.nvim_buf_is_valid(preview_state.buf) then
      vim.api.nvim_buf_delete(preview_state.buf, { force = true })
    end
    if preview_state.augroup then
      vim.api.nvim_del_augroup_by_id(preview_state.augroup)
    end
    preview_state.win = nil
    preview_state.buf = nil
    preview_state.augroup = nil
    preview_state.blame_bufnr = nil
    preview_state.last_commit = nil
  end

  local function update_preview()
    local blame_bufnr = preview_state.blame_bufnr
    if not blame_bufnr or not vim.api.nvim_buf_is_valid(blame_bufnr) then
      close_preview_window()
      return
    end

    local cursor_pos = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_buf_get_lines(blame_bufnr, cursor_pos[1] - 1, cursor_pos[1], false)[1]
    if not line then
      return
    end

    local commit = line:match('^(%x+)')
    if not commit or commit == preview_state.last_commit then
      return
    end
    preview_state.last_commit = commit

    local file_path = vim.api.nvim_buf_get_name(preview_state.source_bufnr)
    if not file_path or file_path == '' then
      close_preview_window()
      return
    end

    local content
    if commit:match('^0+$') then
      content = vim.fn.systemlist('git diff -- ' .. vim.fn.shellescape(file_path))
    else
      content = vim.fn.systemlist('git show ' .. commit .. ' -- ' .. vim.fn.shellescape(file_path))
    end

    if not utils.is_valid_buf(preview_state.buf) then
      close_preview_window()
      return
    end

    utils.with_buf_modifiable(preview_state.buf, function()
      vim.api.nvim_buf_set_lines(preview_state.buf, 0, -1, false, content)
    end)
  end

  local function open_preview_window(blame_bufnr)
    -- Get the source buffer by temporarily switching windows
    local original_win = vim.api.nvim_get_current_win()
    vim.cmd.wincmd('p')
    preview_state.source_bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_set_current_win(original_win)

    if not preview_state.source_bufnr or not vim.api.nvim_buf_is_valid(preview_state.source_bufnr) then
      print("Could not determine source buffer for blame.")
      return
    end

    preview_state.blame_bufnr = blame_bufnr
    preview_state.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value('buftype', 'nofile', { buf = preview_state.buf })
    vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = preview_state.buf })
    vim.api.nvim_set_option_value('filetype', 'diff', { buf = preview_state.buf })

    local width = math.floor(vim.o.columns * 0.6)
    local height = math.floor(vim.o.lines * 0.8)
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    preview_state.win = vim.api.nvim_open_win(preview_state.buf, false, {
      relative = 'editor',
      width = width,
      height = height,
      row = row,
      col = col,
      style = 'minimal',
      border = 'rounded',
      focusable = false,
    })

    vim.keymap.set('n', 'q', close_preview_window, { buffer = preview_state.buf })

    preview_state.augroup = vim.api.nvim_create_augroup('FugitiveBlamePreview', { clear = true })

    local debounce_timer
    local debounced_update = function()
      if debounce_timer then
        vim.fn.timer_stop(debounce_timer)
      end
      debounce_timer = vim.fn.timer_start(100, function()
        vim.schedule(update_preview)
      end)
    end

    vim.api.nvim_create_autocmd('CursorMoved', {
      group = preview_state.augroup,
      buffer = blame_bufnr,
      callback = debounced_update,
    })
    vim.api.nvim_create_autocmd({ 'BufWinLeave', 'BufUnload' }, {
      group = preview_state.augroup,
      buffer = blame_bufnr,
      callback = close_preview_window,
    })

    update_preview()
  end

  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'fugitiveblame',
    callback = function(ev)
      apply_blame_gradient(ev.buf)

      vim.keymap.set('n', 'c', function()
        vim.g.fugitive_blame_gradient_mode = vim.g.fugitive_blame_gradient_mode == 'absolute' and 'relative' or 'absolute'
        apply_blame_gradient(ev.buf)
        print('Blame gradient mode: ' .. vim.g.fugitive_blame_gradient_mode)
      end, { buffer = ev.buf, nowait = true, silent = true })

      vim.keymap.set('n', '<C-p>', function()
        if preview_state.win then
          close_preview_window()
        else
          open_preview_window(ev.buf)
        end
      end, { buffer = ev.buf, nowait = true, silent = true, desc = "Toggle blame preview" })

      vim.keymap.set('n', 'd', function()
        local commit = vim.api.nvim_get_current_line():match('^(%x+)')
        if not commit then
          return
        end

        vim.cmd.wincmd('p')
        local file_path = vim.fn.expand('%:.'):match('//[%x]+/(.+)$') or vim.fn.expand('%:.')
        local line_num = vim.api.nvim_win_get_cursor(0)[1]
        local target_line = vim.api.nvim_buf_get_lines(0, line_num - 1, line_num, false)[1]
        vim.cmd.wincmd('p')

        -- Resolve the path the file had at commit^ (handles renames/moves)
        local function resolve_path_at_commit_parent(cmt, cur_path)
          vim.fn.system('git cat-file -e ' .. vim.fn.shellescape(cmt .. '^:' .. cur_path) .. ' 2>/dev/null')
          if vim.v.shell_error == 0 then
            return cur_path
          end
          local log_lines = vim.fn.systemlist(
            'git log --follow --format=COMMIT:%H --name-status -- ' .. vim.fn.shellescape(cur_path)
          )
          local in_commit = false
          for _, line in ipairs(log_lines) do
            local sha = line:match('^COMMIT:(%x+)$')
            if sha then
              in_commit = (sha:sub(1, #cmt) == cmt or cmt:sub(1, #sha) == sha)
            elseif in_commit and line ~= '' then
              local old = line:match('^R%d*\t(.+)\t.+$')
              if old then return old end
              local path = line:match('^[MAD]\t(.+)$')
              if path then return path end
              in_commit = false
            end
          end
          return cur_path
        end

        local resolved_path = commit:match('^0+$') and file_path or resolve_path_at_commit_parent(commit, file_path)
        local rev = commit:match('^0+$') and ':' or commit .. '^:'
        local fugitive_path = vim.fn.FugitiveFind(rev .. resolved_path)
        local existing_buf = vim.fn.bufnr(fugitive_path)

        vim.cmd(existing_buf ~= -1 and 'tabedit #' .. existing_buf or 'tabedit ' .. fugitive_path)
        vim.cmd(commit:match('^0+$') and 'Gvdiffsplit' or 'Gvdiffsplit ' .. commit)

        local found_line = 1
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        for i, line in ipairs(lines) do
          if line == target_line then
            found_line = i
            break
          end
        end
        vim.cmd.normal({ found_line .. 'Gzz', bang = true })
      end, { buffer = ev.buf, nowait = true, silent = true })
    end,
  })
end

return M

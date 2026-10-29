local M = {}
local ns = vim.api.nvim_create_namespace('git_transient_menu')
vim.api.nvim_set_hl(0, 'GitActionMenuKey', { link = 'Identifier', default = true })
vim.api.nvim_set_hl(0, 'GitActionMenuTarget', { link = 'DiagnosticHint', default = true })
vim.api.nvim_set_hl(0, 'GitActionMenuHeading', { link = 'Statement', default = true })

local function target_end(value)
  local target = value:match('^Commit: %x+') or value:match('^Ref: .+')
    or value:match('^Selected: .+')
  return target and #target or nil
end

local function layout()
  return vim.g.git_action_menu_layout == 'float' and 'float' or 'split'
end

function M.show(spec, opts)
  opts = opts or {}
  local source_win = opts.source_win or vim.api.nvim_get_current_win()
  local source_buf = opts.source_buf or vim.api.nvim_win_get_buf(source_win)
  local remember = require('git.features.transient_presets').bind(spec,
    require('git.utils').get_buf_work_tree(source_buf))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'gitactionmenu'
  vim.b[buf].git_action_menu_source = source_buf
  vim.b[buf].git_action_menu_kind = spec.kind

  local rows, lines, headings = {}, {}, {}
  local action_groups = {}
  for _, group in ipairs(spec.groups or {}) do
    for _, action in ipairs(group.actions) do action_groups[action] = group end
  end
  local function evaluate(action, check)
    local enabled, reason = action.enabled, action.reason
    if type(enabled) == 'function' then enabled, reason = enabled() end
    if enabled == false then return false, reason end
    if check then return check(action, action_groups[action]) end
    return true
  end
  local win
  local function available_width()
    if (opts.layout or layout()) == 'float' then return math.max(vim.o.columns - 4, 1) end
    local target = win and vim.api.nvim_win_is_valid(win) and win or source_win
    return math.max(vim.api.nvim_win_get_width(target), 1)
  end
  local function fit_text(value, width)
    if vim.fn.strdisplaywidth(value) <= width then return value end
    if width <= 1 then return '…' end
    local first, last = 0, vim.fn.strchars(value)
    while first < last do
      local middle = math.ceil((first + last) / 2)
      if vim.fn.strdisplaywidth(vim.fn.strcharpart(value, 0, middle) .. '…') <= width then
        first = middle
      else last = middle - 1 end
    end
    return vim.fn.strcharpart(value, 0, first) .. '…'
  end
  local function render()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local selected
    if win and vim.api.nvim_win_is_valid(win) then
      local cursor = vim.api.nvim_win_get_cursor(win)
      for _, cell in ipairs(rows[cursor[1]] or {}) do
        if cursor[2] >= cell.start_col then selected = cell.action end
      end
    end
    lines, rows, headings = {}, {}, {}
    -- Width measurement, painting, and highlights must use the same snapshot.
    local snapshots = {}
    local check = opts.availability and opts.availability(spec)
    local function snapshot(action)
      if not snapshots[action] then
        local state = action.state and action.state() or nil
        local enabled = evaluate(action, check)
        local marker = not enabled and '·'
          or (action.marker and action.marker(state))
          or (state == nil and ' ' or state and '✓' or '○')
        local label = type(action.label) == 'function' and action.label() or action.label
        local value = ('%s %s %s'):format(marker, action.key, label)
        snapshots[action] = { text = value, width = vim.fn.strdisplaywidth(value),
          active = state, enabled = enabled, key_offset = #marker + 1 }
      end
      return snapshots[action]
    end
    local available = available_width()
    if spec.title then lines[#lines + 1] = fit_text(spec.title, available) end
    if spec.context and spec.context ~= '' then
      lines[#lines + 1] = fit_text(spec.context, available)
    end
    local info_highlights = {}
    for _, line in ipairs(spec.info or {}) do
      local entry = type(line) == 'table' and line or { text = line }
      lines[#lines + 1] = fit_text(entry.text, available)
      info_highlights[#lines] = entry.hl_group
    end
    if #lines > 0 then lines[#lines + 1] = '' end
    local groups = vim.tbl_filter(function(group) return #group.actions > 0 end, spec.groups or {})
    local vertical = vim.g.git_action_menu_group_layout == 'vertical'
    -- Keep long lists near half the screen without widening short menus needlessly.
    local row_limit = math.max(4, math.min(12, math.floor((vim.o.lines - 5) / 2)))
    local function group_layout(group)
      local count = #group.actions
      local function measure(columns)
        local height = math.ceil(count / columns)
        local widths = {}
        for index, action in ipairs(group.actions) do
          local column = math.floor((index - 1) / height) + 1
          widths[column] = math.max(widths[column] or 0, snapshot(action).width)
        end
        local width = 0
        for _, value in ipairs(widths) do width = width + value end
        width = math.max(math.min(vim.fn.strdisplaywidth(group.title), available),
          width + (#widths - 1) * 2)
        return { group = group, height = height, widths = widths, width = width }
      end
      local item = measure(1)
      local preferred = group.columns or spec.columns or 1
      for columns = 2, count do
        if columns > preferred and (vertical or item.height <= row_limit) then break end
        local candidate = measure(columns)
        if candidate.width <= available then item = candidate end
      end
      item.width = math.min(item.width, available)
      if #item.widths == 1 then item.widths[1] = item.width end
      return item
    end
    local band, used = {}, 0
    local function flush()
      if #band == 0 then return end
      local height = 0
      for _, item in ipairs(band) do height = math.max(height, item.height) end
      for offset = 0, height do
        local line, cells, spans = '', {}, {}
        for index, item in ipairs(band) do
          local start_col = #line
          local value = ''
          if offset == 0 then
            value = fit_text(item.group.title, item.width)
            spans[#spans + 1] = { start_col, start_col + #value }
          else
            for column, width in ipairs(item.widths) do
              local action = item.group.actions[(column - 1) * item.height + offset]
              local text = offset <= item.height and action and fit_text(snapshot(action).text, width) or ''
              local cell_start = start_col + #value
              value = value .. text
              if text ~= '' then
                cells[#cells + 1] = { action = action, start_col = cell_start,
                  end_col = start_col + #value }
              end
              if column < #item.widths then
                value = value .. string.rep(' ', width - vim.fn.strdisplaywidth(text) + 2)
              end
            end
          end
          line = line .. value
          if index < #band then
            line = line .. string.rep(' ', math.max(item.width - vim.fn.strdisplaywidth(value) + 2, 2))
          end
        end
        lines[#lines + 1] = line:gsub('%s+$', '')
        if #cells > 0 then rows[#lines] = cells end
        if #spans > 0 then headings[#lines] = spans end
      end
      lines[#lines + 1] = ''
      band, used = {}, 0
    end
    for _, group in ipairs(groups) do
      local item = group_layout(group)
      if used > 0 and (spec.kind == 'root' or vertical or used + item.width + 2 > available) then
        flush()
      end
      band[#band + 1] = item
      used = used + item.width + (#band > 1 and 2 or 0)
    end
    flush()
    if lines[#lines] == '' then table.remove(lines) end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for row, group in pairs(info_highlights) do
      vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0,
        { end_col = #lines[row], hl_group = group })
    end
    if spec.title then
      vim.api.nvim_buf_set_extmark(buf, ns, 0, 0,
        { end_col = #lines[1], hl_group = 'Title' })
    end
    if spec.context and spec.context ~= '' then
      local row = spec.title and 2 or 1
      local finish = target_end(lines[row])
      if finish then
        vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0,
          { end_col = finish, hl_group = 'GitActionMenuTarget' })
      end
    end
    for row, spans in pairs(headings) do
      for _, span in ipairs(spans) do
        local heading = lines[row]:sub(span[1] + 1, span[2])
        local finish = target_end(heading)
        vim.api.nvim_buf_set_extmark(buf, ns, row - 1, span[1],
          { end_col = finish and span[1] + finish or span[2],
            hl_group = finish and 'GitActionMenuTarget' or 'GitActionMenuHeading' })
      end
    end
    for row, cells in pairs(rows) do
      for _, cell in ipairs(cells) do
        local action = cell.action
        if not snapshot(action).enabled then
          vim.api.nvim_buf_set_extmark(buf, ns, row - 1, cell.start_col,
            { end_col = cell.end_col, hl_group = 'Comment' })
        elseif snapshot(action).active then
          local start_col, end_col = cell.start_col, cell.end_col
          if action.highlight_argument then
            local cell_text = lines[row]:sub(start_col + 1, end_col)
            local open = cell_text:find('%(%-')
            local close = cell_text:match('.*()%)')
            if open and close then
              start_col = start_col + open
              end_col = cell.start_col + close - 1
            else
              start_col = end_col
            end
          end
          if start_col < end_col then
            vim.api.nvim_buf_set_extmark(buf, ns, row - 1, start_col,
              { end_col = end_col, hl_group = 'DiagnosticOk' })
          end
        end
        if snapshot(action).enabled then
          local cell_text = lines[row]:sub(cell.start_col + 1, cell.end_col)
          local key_offset = snapshot(action).key_offset
          if cell_text:sub(key_offset + 1, key_offset + #action.key) == action.key then
            local key_start = cell.start_col + key_offset
            vim.api.nvim_buf_set_extmark(buf, ns, row - 1, key_start,
              { end_col = key_start + #action.key, hl_group = 'GitActionMenuKey', priority = 4100 })
          end
        end
      end
    end
    if win and vim.api.nvim_win_is_valid(win) then
      if selected then
        for row, cells in pairs(rows) do
          for _, cell in ipairs(cells) do
            if cell.action == selected then vim.api.nvim_win_set_cursor(win, { row, cell.start_col }) end
          end
        end
      end
      local height = math.min(#lines, math.max(vim.o.lines - 5, 1))
      if (opts.layout or layout()) == 'float' then
        local width = 46
        for _, line in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(line) + 2) end
        width = math.min(width, math.max(vim.o.columns - 4, 1))
        vim.api.nvim_win_set_config(win, { relative = 'editor', width = width,
          height = height, col = math.max(vim.o.columns - width - 2, 0),
          row = math.max(vim.o.lines - height - 4, 0) })
      else vim.api.nvim_win_set_height(win, height) end
    end
  end
  render()

  local width = 46
  for _, line in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(line) + 2) end
  width = math.min(width, math.max(vim.o.columns - 4, 1))
  local height = math.min(#lines, math.max(vim.o.lines - 5, 1))
  if (opts.layout or layout()) == 'float' then
    win = vim.api.nvim_open_win(buf, true, {
      relative = 'editor', width = width, height = height,
      col = math.max(vim.o.columns - width - 2, 0),
      row = math.max(vim.o.lines - height - 4, 0),
      style = 'minimal', border = 'rounded', title = ' Actions ', title_pos = 'center',
    })
  else
    win = vim.api.nvim_open_win(buf, true, {
      split = 'below', win = source_win, height = height,
    })
    vim.wo[win].winfixheight = true
  end
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].foldcolumn = '0'
  vim.wo[win].statuscolumn = ''
  vim.wo[win].list = false
  vim.api.nvim_set_option_value('wrap', false, { win = win, scope = 'local' })
  vim.wo[win].cursorline = true

  local resize_group = vim.api.nvim_create_augroup('git_transient_menu_resize_' .. buf, { clear = true })
  local resize_pending = false
  local function schedule_render()
    if resize_pending then return end
    resize_pending = true
    vim.schedule(function()
      resize_pending = false
      render()
    end)
  end
  vim.api.nvim_create_autocmd({ 'VimResized', 'WinResized' }, {
    group = resize_group,
    callback = schedule_render,
  })
  if opts.availability then
    vim.api.nvim_create_autocmd('User', {
      group = resize_group, pattern = 'GitChanged', callback = schedule_render,
    })
    vim.api.nvim_create_autocmd({ 'FocusGained', 'BufEnter' }, {
      group = resize_group, callback = schedule_render,
    })
    vim.api.nvim_create_autocmd({ 'TextChanged', 'BufWritePost', 'BufWipeout' }, {
      group = resize_group, buffer = source_buf, callback = schedule_render,
    })
    -- Status/log enrichment can replace a noncurrent buffer without TextChanged.
    -- Clear the subscription's only menu reference on wipe; its next event
    -- detaches just this Lua listener without disturbing the panel's listeners.
    local subscription = { schedule = schedule_render }
    vim.api.nvim_buf_attach(source_buf, false, {
      on_lines = function()
        if not subscription.schedule then return true end
        subscription.schedule()
      end,
    })
    vim.api.nvim_create_autocmd('BufWipeout', {
      group = resize_group, buffer = buf, once = true,
      callback = function() subscription.schedule = nil end,
    })
  end
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = resize_group, buffer = buf, once = true,
    callback = function() vim.api.nvim_del_augroup_by_id(resize_group) end,
  })

  local function close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    if vim.api.nvim_win_is_valid(source_win) then vim.api.nvim_set_current_win(source_win) end
  end
  local function execute(action)
    local function validate()
      local check = opts.availability and opts.availability(spec)
      local enabled, reason = evaluate(action, check)
      if not enabled then
        render()
        vim.notify(reason or 'Action is unavailable here', vim.log.levels.WARN)
      end
      return enabled
    end
    if not validate() then return end
    if not action.keep_open then
      if remember then remember(true) end
      close()
    end
    if action.run then action.run({
      source_win = source_win, source_buf = source_buf,
      layout = opts.layout or layout(), render = render, close = close,
      availability = opts.availability, validate = validate,
      action_context = opts.action_context,
    }) end
  end
  vim.keymap.set('n', 'q', close, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set('n', '<Esc>', close, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set('n', '<CR>', function()
    local cursor = vim.api.nvim_win_get_cursor(win)
    local cells = rows[cursor[1]]
    if not cells then return end
    local selected = cells[1]
    for _, cell in ipairs(cells) do
      if cursor[2] >= cell.start_col then selected = cell end
    end
    execute(selected.action)
  end, { buffer = buf, nowait = true, silent = true })
  local mapped = {}
  for _, group in ipairs(spec.groups or {}) do
    for _, action in ipairs(group.actions) do
      for _, key in ipairs(vim.list_extend({ action.key }, action.aliases or {})) do
        if not mapped[key] and key ~= 'q' then
          mapped[key] = true
          vim.keymap.set('n', key, function() execute(action) end,
            { buffer = buf, nowait = true, silent = true })
        end
      end
    end
  end
  return { bufnr = buf, winid = win, close = close, render = render }
end

return M

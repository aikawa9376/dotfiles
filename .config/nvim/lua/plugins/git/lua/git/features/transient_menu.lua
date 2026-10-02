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
  vim.b[buf].git_action_menu_kind = spec.kind

  local rows, lines, headings = {}, {}, {}
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
    lines, rows, headings = {}, {}, {}
    -- Width measurement, painting, and highlights must use the same snapshot.
    local snapshots = {}
    local function snapshot(action)
      if not snapshots[action] then
        local state = action.state and action.state() or nil
        local marker = action.enabled == false and '·'
          or (action.marker and action.marker(state))
          or (state == nil and ' ' or state and '✓' or '○')
        local label = type(action.label) == 'function' and action.label() or action.label
        local value = ('%s %s %s'):format(marker, action.key, label)
        snapshots[action] = { text = value, width = vim.fn.strdisplaywidth(value),
          active = state, key_offset = #marker + 1 }
      end
      return snapshots[action]
    end
    local available = available_width()
    if spec.title then lines[#lines + 1] = fit_text(spec.title, available) end
    if spec.context and spec.context ~= '' then
      lines[#lines + 1] = fit_text(spec.context, available)
    end
    if #lines > 0 then lines[#lines + 1] = '' end
    local groups = vim.tbl_filter(function(group) return #group.actions > 0 end, spec.groups or {})
    if spec.kind ~= 'root' and vim.g.git_action_menu_group_layout ~= 'vertical' then
      local band, used = {}, 0
      local function flush()
        if #band == 0 then return end
        local height = 0
        for _, item in ipairs(band) do height = math.max(height, #item.group.actions) end
        for offset = 0, height do
          local line, cells, spans = '', {}, {}
          for index, item in ipairs(band) do
            local group = item.group
            local value = offset == 0 and group.title
              or (group.actions[offset] and snapshot(group.actions[offset]).text or '')
            value = fit_text(value, item.width)
            local start_col = #line
            line = line .. value
            if offset == 0 then
              spans[#spans + 1] = { start_col, #line }
            elseif group.actions[offset] then
              cells[#cells + 1] = { action = group.actions[offset],
                start_col = start_col, end_col = #line }
            end
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
        local width = vim.fn.strdisplaywidth(group.title)
        for _, action in ipairs(group.actions) do
          width = math.max(width, snapshot(action).width)
        end
        if used > 0 and used + width + 2 > available then flush() end
        width = math.min(width, available)
        band[#band + 1] = { group = group, width = width }
        used = used + width + (#band > 1 and 2 or 0)
      end
      flush()
    else
      for _, group in ipairs(groups) do
        local title = fit_text(group.title, available)
        lines[#lines + 1] = title
        headings[#lines] = { { 0, #title } }
        local columns = group.columns or spec.columns or 1
        if available < 76 then columns = 1 end
        if columns > 1 then
          for first = 1, #group.actions, columns do
            local width = 0
            for index = first, math.min(first + columns - 1, #group.actions) do
              if index > first then width = width + math.max(32 - width, 2) end
              width = width + snapshot(group.actions[index]).width
            end
            if width > available then columns = 1; break end
          end
        end
        for first = 1, #group.actions, columns do
          local line, cells = '', {}
          for index = first, math.min(first + columns - 1, #group.actions) do
            local action = group.actions[index]
            if index > first then
              line = line .. string.rep(' ', math.max(32 - vim.fn.strdisplaywidth(line), 2))
            end
            local start_col = #line
            line = line .. fit_text(snapshot(action).text, available)
            cells[#cells + 1] = { action = action, start_col = start_col, end_col = #line }
          end
          lines[#lines + 1] = line
          rows[#lines] = cells
        end
        lines[#lines + 1] = ''
      end
    end
    if lines[#lines] == '' then table.remove(lines) end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
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
        if action.enabled == false then
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
        if action.enabled ~= false then
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
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true

  local function close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    if vim.api.nvim_win_is_valid(source_win) then vim.api.nvim_set_current_win(source_win) end
  end
  local function execute(action)
    if action.enabled == false then
      vim.notify(action.reason or 'Action is unavailable here', vim.log.levels.WARN)
      return
    end
    if not action.keep_open then
      if remember then remember(true) end
      close()
    end
    if action.run then action.run({
      source_win = source_win, source_buf = source_buf,
      layout = opts.layout or layout(), render = render, close = close,
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

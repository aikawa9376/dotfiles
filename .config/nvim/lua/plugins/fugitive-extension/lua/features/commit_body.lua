local M = {}
local utils = require('fugitive_utils')
local namespace = vim.api.nvim_create_namespace('fugitive_commit_body')
local states = {}
local preview
local icon = '󰍡'

local function commit_at(line)
  return line:match('^(%x%x%x%x%x%x%x+)%s')
end

local function close_preview()
  local old = preview
  preview = nil
  if old and vim.api.nvim_win_is_valid(old.win) then
    pcall(vim.api.nvim_win_close, old.win, true)
  end
end

local function preview_lines(body)
  if not body or not body:find('%S') then return { 'No commit message body.' } end
  local lines = vim.split(body, '\n', { plain = true })
  while #lines > 1 and not lines[1]:find('%S') do table.remove(lines, 1) end
  while #lines > 1 and not lines[#lines]:find('%S') do table.remove(lines) end
  return lines
end

local function paint_preview(lines)
  if not preview or not vim.api.nvim_win_is_valid(preview.win) then return end
  local width = 24
  for _, line in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(line)) end
  width = math.min(width, 90, math.max(vim.o.columns - 4, 1))
  local height = 0
  for _, line in ipairs(lines) do
    height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
  end
  vim.bo[preview.buf].modifiable = true
  vim.api.nvim_buf_set_lines(preview.buf, 0, -1, false, lines)
  vim.bo[preview.buf].modifiable = false
  vim.api.nvim_win_set_config(preview.win, { width = width, height = math.min(height, math.max(math.floor(vim.o.lines * 0.4), 1)) })
end

local function render(bufnr, state)
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local hash = commit_at(line)
    if hash and state.bodies[hash] and state.bodies[hash] ~= '' then
      local col = #line
      if vim.bo[bufnr].filetype == 'fugitivelog' then
        -- hash <tab> date <tab> subject <tab> author <tab> refs/stats
        local author_end = line:match('^%x+\t[^\t]*\t[^\t]*\t[^\t]*()\t')
        if author_end then col = author_end - 1 end
      end
      vim.api.nvim_buf_set_extmark(bufnr, namespace, row - 1, col, {
        virt_text = { { ' ' .. icon, 'Comment' } },
        virt_text_pos = 'inline',
      })
    end
  end
  if preview and preview.source == bufnr and state.bodies[preview.hash] ~= nil then
    paint_preview(preview_lines(state.bodies[preview.hash]))
  end
end

function M.refresh(bufnr)
  local state = states[bufnr]
  if not state or not vim.api.nvim_buf_is_loaded(bufnr) then return end
  local wanted, missing, seen = {}, {}, {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local hash = commit_at(line)
    if hash and not seen[hash] then
      seen[hash] = true
      if state.bodies[hash] ~= nil then wanted[hash] = state.bodies[hash]
      else missing[#missing + 1] = hash end
    end
  end
  -- Retain only the current list, not every commit visited during the session.
  state.bodies = wanted
  render(bufnr, state)
  if #missing == 0 or state.pending then return end
  local root = utils.get_buf_work_tree(bufnr)
  if not root then return end
  state.pending = true
  local ok, job = pcall(vim.system, {
    'git', 'log', '--no-walk=unsorted', '--no-show-signature', '--format=%H%x00%b%x00', '--stdin',
  }, { cwd = root, text = true, stdin = table.concat(missing, '\n') .. '\n' }, function(result)
    vim.schedule(function()
      if states[bufnr] ~= state or not vim.api.nvim_buf_is_loaded(bufnr) then return end
      state.pending, state.job = false, nil
      if result.code ~= 0 then
        if preview and preview.source == bufnr then
          paint_preview({ 'Failed to read commit body.', vim.trim(result.stderr or '') })
        end
        return
      end
      local lengths, bodies = {}, {}
      for _, hash in ipairs(missing) do lengths[#hash] = true end
      for full, body in (result.stdout or ''):gmatch('(%x+)%z(.-)%z') do
        for length in pairs(lengths) do bodies[full:sub(1, length)] = body:find('%S') and body or '' end
      end
      for _, hash in ipairs(missing) do state.bodies[hash] = bodies[hash] or '' end
      M.refresh(bufnr)
    end)
  end)
  if ok then state.job = job
  else
    state.pending = false
    if preview and preview.source == bufnr then paint_preview({ 'Failed to start commit body lookup.' }) end
  end
end

function M.show(bufnr)
  local state = states[bufnr]
  local hash = commit_at(vim.api.nvim_get_current_line())
  if not state or not hash then
    vim.notify('No commit found at cursor', vim.log.levels.WARN)
    return
  end
  close_preview()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'cursor', row = 1, col = 0, width = 24, height = 1,
    style = 'minimal', border = 'rounded', title = ' Commit body ' .. hash .. ' ',
  })
  preview = { buf = buf, win = win, source = bufnr, hash = hash }
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.bo[buf].filetype = 'markdown'
  for _, key in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', key, close_preview, { buffer = buf, silent = true, nowait = true, desc = 'Close commit body' })
  end
  paint_preview(state.bodies[hash] == nil and { 'Loading commit body…' } or preview_lines(state.bodies[hash]))
  if state.bodies[hash] == nil then M.refresh(bufnr) end
end

function M.attach(bufnr)
  if states[bufnr] then return end
  local state = { bodies = {} }
  states[bufnr] = state
  local group = vim.api.nvim_create_augroup('FugitiveCommitBody' .. bufnr, { clear = true })
  vim.keymap.set('n', 'gk', function() M.show(bufnr) end,
    { buffer = bufnr, nowait = true, silent = true, desc = 'Show commit message body' })
  vim.api.nvim_create_autocmd({ 'BufUnload', 'BufWipeout' }, {
    group = group, buffer = bufnr, once = true,
    callback = function()
      states[bufnr] = nil
      if state.job then pcall(function() state.job:kill(15) end) end
      if preview and preview.source == bufnr then close_preview() end
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
end

return M

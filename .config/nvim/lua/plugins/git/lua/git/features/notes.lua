local M = {}

local namespace = vim.api.nvim_create_namespace('fugitive_commit_notes')
local note_icon = '󰍡'
local active_float = { win = nil, buf = nil }

local function run(work_tree, args, opts)
  local command = { 'git', 'notes' }
  vim.list_extend(command, args)
  local system_opts = { cwd = work_tree, text = true }
  if opts and opts.stdin ~= nil then system_opts.stdin = opts.stdin end
  return vim.system(command, system_opts):wait()
end

local function close_float()
  if active_float.win and vim.api.nvim_win_is_valid(active_float.win) then
    vim.api.nvim_win_close(active_float.win, true)
  end
  active_float.win, active_float.buf = nil, nil
end

local function trim_trailing_empty(lines)
  while #lines > 1 and lines[#lines] == '' do table.remove(lines) end
  return lines
end

local function note_lines(work_tree, commit)
  local result = run(work_tree, { 'show', commit })
  if result.code ~= 0 then return nil end
  return trim_trailing_empty(vim.split(result.stdout or '', '\n', { plain = true }))
end

local function open_float(lines, opts)
  close_float()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'markdown'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, #lines > 0 and lines or { '' })

  local max_line_width = 1
  for _, line in ipairs(lines) do max_line_width = math.max(max_line_width, vim.fn.strdisplaywidth(line)) end
  local width = math.min(math.max(max_line_width + 2, 36), math.max(vim.o.columns - 4, 1), 72)
  local height = math.min(math.max(#lines, 1), math.max(vim.o.lines - 6, 1), 20)
  local win = vim.api.nvim_open_win(buf, opts.enter == true, {
    relative = 'editor',
    width = width,
    height = height,
    col = math.max(math.floor((vim.o.columns - width) / 2), 0),
    row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0),
    style = 'minimal',
    border = 'rounded',
    title = opts.title,
    title_pos = 'center',
  })
  active_float.win, active_float.buf = win, buf
  vim.wo[win].wrap = true
  vim.wo[win].cursorline = false
  return buf, win
end

local function notify_failure(action, result)
  local message = vim.trim(result.stderr or result.stdout or '')
  if message == '' then message = 'git notes ' .. action .. ' failed' end
  vim.notify(message, vim.log.levels.ERROR)
end

function M.edit(work_tree, commit, on_saved)
  if not work_tree or not commit or commit == '' then return end
  local existing = note_lines(work_tree, commit)
  local buf = open_float(existing or { '' }, {
    enter = true,
    title = (' Note %s  <C-s>/ZZ save · q cancel '):format(commit:sub(1, 12)),
  })
  vim.bo[buf].modifiable = true

  local function save()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local content = table.concat(lines, '\n'):gsub('%s+$', '')
    local result
    if content == '' then
      if existing then result = run(work_tree, { 'remove', commit })
      else result = { code = 0 } end
    else
      result = run(work_tree, { 'add', '-f', '-F', '-', commit }, { stdin = content .. '\n' })
    end
    if result.code ~= 0 then
      notify_failure(content == '' and 'remove' or 'add', result)
      return
    end
    close_float()
    vim.notify(content == '' and 'Git note removed' or 'Git note saved', vim.log.levels.INFO)
    if on_saved then on_saved() end
  end

  vim.keymap.set({ 'n', 'i' }, '<C-s>', save, { buffer = buf, silent = true, desc = 'Save Git note' })
  vim.keymap.set('n', 'ZZ', save, { buffer = buf, silent = true, desc = 'Save Git note' })
  vim.keymap.set('n', 'q', close_float, { buffer = buf, silent = true, desc = 'Cancel Git note edit' })
  vim.keymap.set('n', '<Esc>', close_float, { buffer = buf, silent = true, desc = 'Cancel Git note edit' })
  vim.cmd('startinsert')
end

function M.show(work_tree, commit, on_saved)
  if not work_tree or not commit or commit == '' then return end
  local lines = note_lines(work_tree, commit)
  if not lines then
    vim.notify('No Git note for ' .. commit:sub(1, 12) .. ' (gN to add)', vim.log.levels.INFO)
    return
  end
  local buf = open_float(lines, {
    enter = true,
    title = (' Note %s  e edit · q close '):format(commit:sub(1, 12)),
  })
  vim.bo[buf].modifiable = false
  vim.keymap.set('n', 'q', close_float, { buffer = buf, silent = true, desc = 'Close Git note' })
  vim.keymap.set('n', '<Esc>', close_float, { buffer = buf, silent = true, desc = 'Close Git note' })
  vim.keymap.set('n', 'e', function()
    M.edit(work_tree, commit, on_saved)
  end, { buffer = buf, silent = true, desc = 'Edit Git note' })
end

local function note_objects(work_tree)
  local result = run(work_tree, { 'list' })
  if result.code ~= 0 then return {} end
  local objects = {}
  for line in (result.stdout or ''):gmatch('[^\r\n]+') do
    local object = line:match('^%x+%s+(%x+)$')
    if object then table.insert(objects, object) end
  end
  return objects
end

function M.apply_icons(bufnr, work_tree, commit_at_line)
  if not vim.api.nvim_buf_is_valid(bufnr) or not work_tree then return end
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  local objects = note_objects(work_tree)
  if #objects == 0 then return end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for index, line in ipairs(lines) do
    local commit = commit_at_line(line, index)
    if commit then
      for _, object in ipairs(objects) do
        if object:sub(1, #commit) == commit then
          vim.api.nvim_buf_set_extmark(bufnr, namespace, index - 1, 0, {
            virt_text = { { ' ' .. note_icon, 'DiagnosticInfo' } },
            virt_text_pos = 'right_align',
            hl_mode = 'combine',
          })
          break
        end
      end
    end
  end
end

function M.clear(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  end
end

return M

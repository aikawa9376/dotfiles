local Differ = {}
Differ.__index = Differ

function Differ.new(sign_name, sign_number)
  local self = setmetatable({}, Differ)
  self.original_buffer = -1
  self.original_bufhidden = ''
  self.diff_buffer = -1
  self.index = -1
  self.filetype = ''
  self.from = -1
  self.to = -1
  self.sign_name = sign_name
  self.sign_number = sign_number
  self.sign_text = sign_number .. '-'
  self._is_blank = true
  self.other_differs = {}
  self.is_merge = false
  self.merge_from = -1
  self.merge_to = -1
  self.label = ''

  local hl_group = "LinediffSign" .. self.sign_number
  vim.cmd(string.format("sign define %s numhl=%s", self.sign_name, hl_group))

  return self
end

function Differ:init(from, to, options)
  if options and options.bufnr then
    self.original_buffer = options.bufnr
  else
    self.original_buffer = vim.fn.bufnr('%')
  end
  self.original_bufhidden = vim.fn.getbufvar(self.original_buffer, '&bufhidden')

  self.filetype = vim.fn.getbufvar(self.original_buffer, '&filetype')
  self.from = from
  self.to = to

  if options then
    for k, v in pairs(options) do
      self[k] = v
    end
  end

  self:setup_signs()

  vim.fn.setbufvar(self.original_buffer, '&bufhidden', 'hide')

  self._is_blank = false
end

function Differ:is_blank()
  return self._is_blank
end

function Differ:reset()
  if self.original_buffer == -1 then
    return
  end

  vim.cmd(string.format("silent! sign unplace * group=%s buffer=%d", self.sign_name, self.original_buffer))
  vim.fn.setbufvar(self.original_buffer, '&bufhidden', self.original_bufhidden)

  self.original_buffer = -1
  self.original_bufhidden = ''
  self.diff_buffer = -1
  self.filetype = ''
  self.from = -1
  self.to = -1
  self.other_differs = {}

  self._is_blank = true
  self.is_merge = false
  self.merge_from = -1
  self.merge_to = -1
  self.label = ''

  if vim.g.linediff_original_diffopt then
    vim.o.diffopt = vim.g.linediff_original_diffopt
    vim.g.linediff_original_diffopt = nil
  end
end

function Differ:close_and_reset(force)
  self:close_diff_buffer(force)
  self:reset()
end

function Differ:lines()
  return vim.fn.getbufline(self.original_buffer, self.from, self.to)
end

function Differ:create_diff_buffer(edit_command, index)
  local lines = self:lines()

  if vim.g.linediff_buffer_type == 'tempfile' then
    local temp_file = vim.fn.tempname()
    vim.fn.writefile(lines, temp_file)
    vim.cmd(string.format("silent %s %s", edit_command, temp_file))
    vim.cmd('normal! gg')
  else -- scratch
    vim.cmd(string.format("silent %s", edit_command))
    if vim.fn.has('patch-7.4.73') then
      vim.bo.undolevels = -1
    end
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    if vim.fn.has('patch-7.4.73') then
      vim.bo.undolevels = vim.o.undolevels
    end
    vim.bo.buftype = 'nowrite'
    vim.bo.bufhidden = 'wipe'
  end

  self.diff_buffer = vim.fn.bufnr('%')
  vim.cmd('nnoremap <silent> <buffer> <nowait> q :LinediffReset<CR>')
  self.index = index
  self:setup_diff_buffer()
  self:setup_update_autocmds()
  self:indent()

  vim.cmd('diffthis')

  vim.api.nvim_exec_autocmds('User', { pattern = 'LinediffBufferReady', modeline = false })
end

function Differ:indent()
  if vim.g.linediff_indent then
    vim.cmd('silent normal! gg=G')
  end
end

function Differ:setup_diff_buffer()
  vim.b.differ = self

  local label = ''
  if self.label ~= '' then
    label = ' (' .. self.label .. ')'
  end

  self.description = string.format('[%s:%s-%s%s]',
    vim.fn.bufname(self.original_buffer),
    self.from,
    self.to,
    label)

  if vim.g.linediff_buffer_type == 'tempfile' then
    if vim.g.linediff_modify_statusline == 1 then
      if string.match(vim.o.statusline, '%%[fF]') then
        local repl = vim.fn.escape(self.description, '\\%')
        local statusline = string.gsub(vim.o.statusline, '%%[fF]', repl)
        vim.wo.statusline = statusline
      else
        vim.wo.statusline = self.description
      end
    end
    vim.bo.filetype = self.filetype
    vim.bo.bufhidden = 'wipe'
  else -- scratch
    vim.cmd('silent keepalt file ' .. vim.fn.escape(self.description, '[ '))
    vim.bo.filetype = self.filetype
    vim.bo.modified = false
  end
end

function Differ:setup_update_autocmds()
  if vim.g.linediff_buffer_type == 'tempfile' then
    vim.api.nvim_create_autocmd('BufWrite', { buffer = self.diff_buffer, callback = function()
      self:update_original_buffer()
    end})
  else -- scratch
    vim.api.nvim_create_autocmd('BufWriteCmd', { buffer = self.diff_buffer, callback = function()
      self:update_original_buffer()
    end})
  end
end

function Differ:close_diff_buffer(force)
  if vim.fn.bufexists(self.diff_buffer) == 1 then
    local bang = force and '!' or ''
    local diff_buffer = self.diff_buffer
    if vim.fn.has('patch-9.0.907') then
      vim.fn.timer_start(1, function()
        vim.cmd(string.format('silent! bdelete%s %d', bang, diff_buffer))
      end)
    else
      vim.cmd(string.format('silent! bdelete%s %d', bang, diff_buffer))
    end
  end
end

function Differ:setup_signs()
  vim.cmd(string.format("silent! sign unplace * group=%s buffer=%d", self.sign_name, self.original_buffer))

  for i = self.from, self.to do
    local sign_id = (self.sign_number * 100000) + i
    vim.cmd(string.format("silent! sign place %d group=%s name=%s line=%d buffer=%d",
      sign_id, self.sign_name, self.sign_name, i, self.original_buffer))
  end
end

function Differ:update_original_buffer()
  if self:is_blank() then
    return
  end

  local saved_diff_buffer_view = vim.fn.winsaveview()
  local new_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

  vim.bo.bufhidden = 'hide'
  vim.cmd('buffer ' .. self.original_buffer)
  vim.fn.cursor(self.from, 1)
  vim.cmd(string.format("silent! %d,%dfoldopen!", self.from, self.to))
  vim.cmd(string.format('normal! %d"_dd', self.to - self.from + 1))
  vim.fn.append(self.from - 1, new_lines)
  vim.cmd('buffer ' .. self.diff_buffer)
  vim.bo.bufhidden = 'wipe'

  local line_count = self.to - self.from + 1
  local new_line_count = #new_lines

  self.to = self.from + #new_lines - 1
  self:setup_diff_buffer()
  self:setup_signs()

  self:possibly_update_other_differs(new_line_count - line_count)
  vim.fn.winrestview(saved_diff_buffer_view)
end

function Differ:possibly_update_other_differs(delta)
  if delta == 0 then
    return
  end
  for _, other in ipairs(self.other_differs) do
    self:update_other_differ(delta, other)
  end
end

function Differ:update_other_differ(delta, other)
  if self.original_buffer == other.original_buffer and self.to <= other.from then
    other.from = other.from + delta
    other.to = other.to + delta
    other:setup_signs()
  end
  if self.is_merge and other.is_merge then
    other.merge_to = other.merge_to + delta
  end
end

function Differ:is_merge_diff()
  return self.is_merge
end

function Differ:replace_merge()
  local real_from, real_to = self.from, self.to
  self.from = self.merge_from
  self.to = self.merge_to
  self:update_original_buffer()
  self.from, self.to = real_from, real_to
end

return Differ

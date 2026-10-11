-- An immutable context panel and one Markdown draft. Failed requests keep it;
-- a successful :w closes it so another write cannot duplicate the operation.
local M = {}
local serial = 0
function M.open(opts)
  opts = vim.tbl_extend('force', opts, { ctx = vim.deepcopy(opts.ctx) })
  serial = serial + 1
  local prefix = vim.deepcopy(opts.prefix or {})
  vim.list_extend(prefix, { opts.instruction or '<C-s> / :w sends to GitHub · q closes', '────────────────────────────' })
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, ('git-pr-compose://%s/%s/%d/%d'):format(opts.ctx.host, opts.ctx.repo, opts.ctx.number, serial))
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile, vim.bo[buf].undofile = 'acwrite', 'hide', false, false
  vim.bo[buf].filetype = 'markdown'
  require('git.utils').set_buf_work_tree(buf, opts.ctx.root)
  local initial = vim.split(opts.body or '', '\n', { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial)
  vim.bo[buf].modified = false
  local width, height = math.max(1, math.min(80, vim.o.columns - 4)), math.max(1, math.min(5, vim.o.lines - 10))
  local win = vim.api.nvim_open_win(buf, true, { relative = 'editor', style = 'minimal', border = 'rounded',
    width = width, height = height, col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    row = math.max(0, math.floor((vim.o.lines - height) / 2)), title = ' ' .. opts.title .. ' ' })
  vim.wo[win].wrap, vim.wo[win].linebreak = true, true
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  local saving = false
  local function close()
    if saving then vim.notify('A GitHub request is running; wait for its result'); return end
    if vim.bo[buf].modified and vim.fn.confirm('Discard unsent draft?', '&Discard\n&Keep', 2) ~= 1 then return end
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  vim.keymap.set('n', 'q', close, { buffer = buf, silent = true })
  vim.keymap.set('n', 'gx', function() vim.ui.open(opts.ctx.url) end, { buffer = buf, silent = true })
  local function send(submit, success)
    saving, vim.bo[buf].modifiable = true, false
    require('git.features.github_actions').run(opts.ctx, submit, function()
      saving = false
      vim.notify(success)
      if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
    end, true, function()
      saving = false
      if vim.api.nvim_buf_is_valid(buf) then vim.bo[buf].modifiable = true end
    end)
  end
  if opts.delete then
    vim.keymap.set('n', 'gX', function()
      if saving then error('This draft already has a request running') end
      if vim.fn.confirm(opts.delete_prompt, '&Delete\n&Keep', 2) ~= 1 then return end
      send(opts.delete, 'Pending comment deleted')
    end, { buffer = buf, silent = true, desc = 'Delete pending review comment' })
  end
  local group = vim.api.nvim_create_augroup('GitPrComposer' .. buf, { clear = true })
  vim.api.nvim_create_autocmd('BufWriteCmd', { group = group, buffer = buf, callback = function(ev)
    if ev.match ~= vim.api.nvim_buf_get_name(buf) then error('Use :w without a filename to send this draft') end
    if saving then error('This draft is already being sent') end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local body = table.concat(lines, '\n')
    if not opts.allow_empty and vim.trim(body) == '' then error('Comment cannot be empty') end
    send(function(ctx) return opts.submit(ctx, body) end, opts.success or 'Comment sent')
  end })
  -- Sending an empty summary needs a write event even without a local edit.
  local function write() vim.cmd('write') end
  vim.keymap.set({ 'n', 'i' }, '<C-s>', write, { buffer = buf, silent = true, desc = 'Send / save PR draft' })
  require('git.features.pr_history').attach(buf, win, opts.history, opts.viewer, prefix, close)
  vim.api.nvim_create_autocmd('BufWipeout', { group = group, buffer = buf, once = true, callback = function()
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end })
  return buf
end
return M

-- An immutable context panel and one Markdown draft. Failed requests keep it;
-- a successful :w closes it so another write cannot duplicate the operation.
local M = {}
function M.open(opts)
  opts = vim.tbl_extend('force', opts, { ctx = vim.deepcopy(opts.ctx) })
  local prefix = vim.deepcopy(opts.prefix or {})
  while #prefix > 0 and prefix[#prefix]:match('^%s*$') do table.remove(prefix) end
  local buf = vim.api.nvim_create_buf(true, false)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile, vim.bo[buf].undofile = 'acwrite', 'hide', false, false
  local names = require('git.buffer_names')
  local comment = opts.history and opts.history[1]
  local target = ('%s/%s/pull/%d/%s'):format(opts.ctx.host, opts.ctx.repo, opts.ctx.number, opts.title:gsub('[ /]', '-'))
  if comment and comment.id then target = target .. '/comment-' .. comment.id end
  names.assign(buf, names.uri('git-pr-compose', opts.ctx.root, target))
  vim.bo[buf].filetype = 'markdown'
  vim.b[buf].git_pr_ctx = opts.ctx
  require('git.utils').set_buf_work_tree(buf, opts.ctx.root)
  local initial = vim.split(opts.body or '', '\n', { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial)
  vim.bo[buf].modified = false
  local action = opts.action or 'send'
  local title = { { ' ' .. opts.title .. ' ', 'Title' },
    { '· <C-s>/:w ' .. action .. ' · Tab' .. (opts.delete and ' · gX delete' or '') .. ' · q ', 'GitPrCommentInstruction' } }
  local width, height = math.max(1, math.min(80, vim.o.columns - 4)), math.max(1, math.min(5, vim.o.lines - 10))
  local win = vim.api.nvim_open_win(buf, true, { relative = 'editor', style = 'minimal', border = 'rounded',
    width = width, height = height, col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    row = math.max(0, math.floor((vim.o.lines - height) / 2)), title = title })
  vim.wo[win].wrap, vim.wo[win].linebreak = true, true
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  local saving = false
  local spinner_generation = 0
  local function visible()
    return vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf
  end
  local function stop_spinner()
    spinner_generation = spinner_generation + 1
    if visible() then vim.api.nvim_win_set_config(win, { title = title }) end
  end
  local function start_spinner()
    spinner_generation = spinner_generation + 1
    local generation, index = spinner_generation, 0
    local frames = { '◐', '◓', '◑', '◒' }
    local function tick()
      if generation ~= spinner_generation or not saving or not visible() then return end
      index = index % #frames + 1
      local chunks, used = vim.deepcopy(title), 0
      for _, chunk in ipairs(chunks) do used = used + vim.fn.strdisplaywidth(chunk[1]) end
      chunks[#chunks + 1] = { string.rep('─', math.max(0, width - used - 3)), 'FloatBorder' }
      chunks[#chunks + 1] = { ' ' .. frames[index] .. ' ', 'DiagnosticInfo' }
      vim.api.nvim_win_set_config(win, { title = chunks })
      vim.defer_fn(tick, 120)
    end
    tick()
  end
  local function close()
    if saving then vim.notify('A GitHub request is running; wait for its result'); return end
    if vim.bo[buf].modified and vim.fn.confirm('Discard unsent draft?', '&Discard\n&Keep', 2) ~= 1 then return end
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  vim.keymap.set('n', 'q', close, { buffer = buf, silent = true })
  vim.keymap.set('n', 'gx', function() vim.ui.open(opts.ctx.url) end, { buffer = buf, silent = true })
  local function send(submit, success)
    if saving then return end
    -- Claim this send and expose its state before launching any asynchronous
    -- work. Subsequent saves refer to this request until it finishes.
    saving, vim.bo[buf].modifiable = true, false
    start_spinner()
    require('git.features.github_actions').run(opts.ctx, submit, function()
      saving = false
      stop_spinner()
      vim.notify(success)
      if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
    end, true, function()
      saving = false
      if vim.api.nvim_buf_is_valid(buf) then vim.bo[buf].modifiable = true end
      stop_spinner()
    end)
  end
  if opts.delete then
    vim.keymap.set('n', 'gX', function()
      if saving then return end
      if vim.fn.confirm(opts.delete_prompt, '&Delete\n&Keep', 2) ~= 1 then return end
      send(opts.delete, opts.delete_success or 'Pending comment deleted')
    end, { buffer = buf, silent = true, desc = 'Delete selected comment' })
  end
  local group = vim.api.nvim_create_augroup('GitPrComposer' .. buf, { clear = true })
  vim.api.nvim_create_autocmd('BufWriteCmd', { group = group, buffer = buf, callback = function(ev)
    if ev.match ~= vim.api.nvim_buf_get_name(buf) then error('Use :w without a filename to send this draft') end
    -- Repeated saves keep the same in-flight request, rather than treating a
    -- second button press as a failed first submission.
    if saving then return end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local body = table.concat(lines, '\n')
    if not opts.allow_empty and vim.trim(body) == '' then error('Comment cannot be empty') end
    send(function(ctx) return opts.submit(ctx, body) end, opts.success or 'Comment sent')
  end })
  -- Sending an empty summary needs a write event even without a local edit.
  local function write() vim.cmd('write') end
  vim.keymap.set({ 'n', 'i' }, '<C-s>', write, { buffer = buf, silent = true, desc = 'Send / save PR draft' })
  require('git.features.pr_history').attach(buf, win, opts.history, opts.viewer, prefix, close, opts.hint, opts.history_contexts)
  vim.api.nvim_create_autocmd('BufWipeout', { group = group, buffer = buf, once = true, callback = function()
    stop_spinner()
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end })
  return buf
end
return M

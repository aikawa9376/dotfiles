-- Shared asynchronous execution for repository-scoped transient workflows.
local M = {}
local git = require('git.features.commit_model').git
local utils = require('git.utils')
function M.path(root, path)
  if path:sub(1, 2) == '~/' then path = vim.fn.expand('~') .. path:sub(2) end
  return vim.fs.normalize(path:sub(1, 1) == '/' and path or root .. '/' .. path, { expand_env = false })
end
function M.output(root, title, content)
  utils.open_panel_split()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = 'nofile', 'wipe', false
  vim.api.nvim_buf_set_name(buf, 'git-workflow://' .. title:gsub('[ /]', '-') .. '/' .. buf)
  utils.set_buf_work_tree(buf, root)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content:gsub('\n$', ''), '\n', { plain = true }))
  vim.bo[buf].filetype, vim.bo[buf].modifiable = 'git', false
  vim.keymap.set('n', 'q', '<Cmd>close<CR>', { buffer = buf, silent = true })
  return buf
end
function M.write(path, content)
  -- Exclusive creation prevents overwriting an existing export, including one
  -- created while Git was running. Do not translate patch bytes or newlines.
  local file, err = vim.uv.fs_open(path, 'wx', 420)
  if not file then error(err, 0) end
  local offset, failure = 0, nil
  while offset < #content do
    local written, write_err = vim.uv.fs_write(file, content:sub(offset + 1), offset)
    if not written or written == 0 then failure = write_err or 'Could not write export'; break end
    offset = offset + written
  end
  vim.uv.fs_close(file)
  if failure then os.remove(path); error(failure, 0) end
end
function M.run(root, args, opts)
  opts = opts or {}
  local env = opts.editor and require('git.editor').environment() or opts.env
  local task, err = require('git.features.async').run(root, function()
    if opts.before then opts.before() end
    if opts.new_file and vim.uv.fs_lstat(opts.new_file) then error('File already exists: ' .. opts.new_file, 0) end
    local output, failure, result = git(root, args, { env = env, stdin = opts.stdin })
    if not output then error(failure, 0) end
    if opts.output_file then M.write(opts.output_file, output) end
    return opts.include_stderr and (output .. (result and result.stderr or '')) or output
  end, function(ok, result)
    -- am/apply/subtree can leave conflict state even when Git exits nonzero.
    if opts.mutation ~= false then utils.fire_git_changed({ work_tree = root }) end
    if opts.callback then opts.callback(ok, result)
    elseif not ok then vim.notify(result, vim.log.levels.ERROR)
    elseif opts.output then M.output(root, opts.title or table.concat(args, ' '), result)
    else vim.notify(opts.success or 'Git ' .. (args[1] or '') .. ' completed', vim.log.levels.INFO) end
  end, { mutation = opts.mutation ~= false })
  if not task then vim.notify(err, vim.log.levels.WARN) end
  return task, err
end
return M

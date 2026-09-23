local M = {}

local function run(work_tree, args)
  local command = { 'git' }
  vim.list_extend(command, args)
  return vim.system(command, { cwd = work_tree, text = true }):wait()
end

local function comparison_ref(work_tree)
  for _, revision in ipairs({ '@{push}', '@{upstream}' }) do
    local result = run(work_tree, {
      'rev-parse', '--abbrev-ref', '--symbolic-full-name', revision,
    })
    if result.code == 0 and vim.trim(result.stdout or '') ~= '' then
      return vim.trim(result.stdout)
    end
  end
  return nil
end

function M.open(work_tree)
  local reference = comparison_ref(work_tree)
  if not reference then
    vim.notify('No push remote or upstream is configured for range-diff', vim.log.levels.WARN)
    return false
  end

  local result = run(work_tree, {
    'range-diff', '--no-color', reference .. '...HEAD',
  })
  if result.code ~= 0 then
    vim.notify(vim.trim(result.stderr or 'git range-diff failed'), vim.log.levels.ERROR)
    return false
  end

  local output = vim.split((result.stdout or ''):gsub('\r\n', '\n'), '\n', { plain = true })
  if output[#output] == '' then table.remove(output) end
  if #output == 0 then output = { 'No differences between ' .. reference .. ' and HEAD.' } end

  vim.cmd('tabnew')
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].undofile = false
  vim.api.nvim_buf_set_name(bufnr, 'git-range-diff://' .. reference .. '...HEAD')
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, output)
  vim.bo[bufnr].filetype = 'git'
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
  vim.keymap.set('n', 'q', '<Cmd>tabclose<CR>', { buffer = bufnr, silent = true, nowait = true })
  return true
end

return M

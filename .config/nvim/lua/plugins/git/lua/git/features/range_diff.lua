local M = {}
local model = require('git.features.commit_model')
function M.open(work_tree)
  if not work_tree then vim.notify('Git work tree not found', vim.log.levels.WARN); return false end
  return require('git.features.async').run(work_tree, function()
    local reference
    for _, revision in ipairs({ '@{push}', '@{upstream}' }) do
      local output = model.git(work_tree, { 'rev-parse', '--abbrev-ref', '--symbolic-full-name', revision })
      if output and vim.trim(output) ~= '' then reference = vim.trim(output); break end
    end
    if not reference then error('No push remote or upstream is configured for range-diff', 0) end
    local output, err = model.git(work_tree, { 'range-diff', '--no-color', reference .. '...HEAD' })
    if not output then error(err, 0) end
    if vim.trim(output) == '' then output = 'No differences between ' .. reference .. ' and HEAD.\n' end
    return reference, output
  end, function(ok, reference, output)
    if not ok then vim.notify(reference, vim.log.levels.WARN); return end
    vim.cmd('tabnew')
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = 'nofile', 'wipe', false
    vim.bo[buf].undofile = false
    vim.api.nvim_buf_set_name(buf, 'git-range-diff://' .. buf .. '/' .. reference .. '...HEAD')
    require('git.utils').set_buf_work_tree(buf, work_tree)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(output:gsub('\n$', ''), '\n', { plain = true }))
    vim.bo[buf].filetype, vim.bo[buf].modifiable, vim.bo[buf].readonly = 'git', false, true
    vim.keymap.set('n', 'q', '<Cmd>tabclose<CR>', { buffer = buf, silent = true, nowait = true })
  end)
end
return M

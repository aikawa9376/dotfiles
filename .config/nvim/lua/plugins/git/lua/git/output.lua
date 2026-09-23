-- Navigation for plain Git diff/show output.
local M = {}
function M.setup(group)
  vim.api.nvim_create_autocmd('FileType', { group = group, pattern = 'git', callback = function(ev)
    local function map(key, fn) vim.keymap.set('n', key, fn, { buffer = ev.buf, silent = true }) end
    vim.bo[ev.buf].syntax = 'git'
    vim.wo.foldmethod = 'syntax'
    map(']]', function() vim.fn.search('^diff --git ', 'W'); vim.cmd('silent! normal! zv') end)
    map('[[', function() vim.fn.search('^diff --git ', 'bW'); vim.cmd('silent! normal! zv') end)
    map('i', function() vim.fn.search('^@@ ', 'W'); vim.cmd('silent! normal! zvzt') end)
    map('o', 'za')
    map('q', '<cmd>close<CR>')
    map('<CR>', function()
      local lines = vim.api.nvim_buf_get_lines(ev.buf, 0, -1, false)
      local row, hash, path, line = vim.fn.line('.'), nil, nil, 1
      for i = 1, row do
        hash = lines[i]:match('^commit (%x+)') or hash
        if lines[i]:match('^diff %-%-git ') then path = nil; line = 1 end
        path = lines[i]:match('^%+%+%+ b/(.*)$') or path
        local start = tonumber(lines[i]:match('^@@ %-%d+,?%d* %+(%d+)'))
        if start then line = start
        elseif path and i < row and lines[i]:match('^[ +]') and not lines[i]:match('^%+%+%+') then line = line + 1 end
      end
      local root = require('git.objects').context(ev.buf)
      if path then
        if hash then require('git.objects').open(hash .. ':' .. path, 'edit', root)
        else vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/' .. path)) end
        vim.api.nvim_win_set_cursor(0, { math.max(1, math.min(line, vim.api.nvim_buf_line_count(0))), 0 })
      elseif hash then require('git.features.commit').open({ work_tree = root, revision = hash }) end
    end)
  end })
end
return M

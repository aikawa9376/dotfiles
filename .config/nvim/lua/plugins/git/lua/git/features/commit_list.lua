local M = {}
local spans_by_buf = {}
function M.cleanup(bufnr) spans_by_buf[bufnr] = nil end
vim.api.nvim_create_autocmd({ 'BufUnload', 'BufWipeout' }, {
  group = vim.api.nvim_create_augroup('GitCommitList', { clear = true }),
  callback = function(ev) M.cleanup(ev.buf) end,
})

M.format = '--pretty=format:%h%x09%ad%x09%an%x09%s'

function M.lines(output, bufnr, kind)
  local lines, spans = {}, {}
  for line in (output or ''):gmatch('[^\r\n]+') do
    local hash, date, author, subject = line:match('^([^\t]+)\t([^\t]+)\t([^\t]*)\t(.*)$')
    if hash then
      author = vim.trim(author:gsub('%s+', ' '))
      local prefix = hash .. ' ' .. date .. ' ' .. subject:gsub('\t', ' ')
      local text = prefix .. (author ~= '' and (' ' .. author) or '')
      lines[#lines + 1] = text
      if author ~= '' then spans[text] = { #prefix + 1, #text } end
    else
      lines[#lines + 1] = line:gsub('\t', ' ')
    end
  end
  if bufnr and vim.api.nvim_buf_is_loaded(bufnr) then
    spans_by_buf[bufnr] = spans_by_buf[bufnr] or {}
    spans_by_buf[bufnr][kind] = spans
  end
  return lines
end

-- Preserve exact byte columns from Git fields; display separators are not parsable.
-- Three query buckets bound metadata to current recent/unpushed/unpulled results.
function M.author_span(bufnr, line)
  for _, spans in pairs(spans_by_buf[bufnr] or {}) do
    if spans[line] then return unpack(spans[line]) end
  end
end

return M

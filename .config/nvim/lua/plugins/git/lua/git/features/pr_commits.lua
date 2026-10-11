-- PR history is the same immutable merge-base..head comparison as its files.
local M = {}
local changes = require('git.features.commit_model')
local highlight = require('git.features.commit_highlight')
vim.api.nvim_set_hl(0, 'GitLogDate', { default = true, link = 'Directory' })
vim.api.nvim_set_hl(0, 'GitLogAuthor', { default = true, link = 'Type' })

function M.load(root, base, head)
  local output, err = changes.git(root, { 'log', '--no-color', '--no-show-signature', '--no-notes', '-z',
    '--format=%H%x00%h%x00%as%x00%s%x00%an', base .. '..' .. head, '--' })
  if not output then error(err, 0) end
  local fields = vim.split(output, '\0', { plain = true })
  if fields[#fields] == '' then table.remove(fields) end
  local commits = {}
  for i = 1, #fields, 5 do
    assert(fields[i + 4], 'Invalid PR commit log')
    commits[#commits + 1] = { hash = fields[i], short = fields[i + 1], date = fields[i + 2],
      subject = fields[i + 3]:gsub('[\r\n\t]', ' '), author = fields[i + 4]:gsub('[\r\n\t]', ' ') }
  end
  return commits
end

function M.chunks(commit)
  return { { commit.short, highlight.group('default') }, { '\t', 'Normal' },
    { commit.date, 'GitLogDate' }, { '\t', 'Normal' }, { commit.subject, 'Normal' },
    { '\t', 'Normal' }, { commit.author, 'GitLogAuthor' } }
end
return M

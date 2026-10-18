-- Command parsing/completion is local; listing has a finite default budget.
local M = {}
local flags = { ['--state'] = 'state', ['--limit'] = 'limit', ['--label'] = 'labels', ['--assignee'] = 'assignee',
  ['-s'] = 'state', ['-L'] = 'limit', ['-l'] = 'labels', ['-a'] = 'assignee' }
local states = { 'open', 'closed', 'all' }
function M.normalize(filters)
  local result = vim.tbl_extend('force', { state = 'open', limit = 50 }, filters or {})
  assert(vim.tbl_contains(states, result.state), 'Issue --state must be open, closed or all')
  result.limit = tonumber(result.limit)
  assert(result.limit and result.limit >= 1 and result.limit % 1 == 0 and result.limit < math.huge,
    'Issue --limit must be a positive integer')
  return result
end
function M.parse(text, allow_selector)
  local words = require('git.commands').argv(text)
  local filters, selector, index, has_filters = {}, nil, 1, false
  while index <= #words do
    local word = words[index]
    local flag, value = word:match('^(%-%-[%w%-]+)=(.*)$')
    local field = flags[flag or word]
    if field then
      has_filters = true
      if not flag then index = index + 1; value = words[index] end
      assert(value and value ~= '' and not value:match('^%-'), 'Missing value for ' .. (flag or word))
      if field == 'labels' and filters.labels then filters.labels = filters.labels .. ',' .. value
      else filters[field] = value end
    else
      assert(not word:match('^%-'), 'Unknown Issue option: ' .. word)
      assert(allow_selector and not selector, 'Use Issue list flags or a single Issue number/URL')
      selector = word
    end
    index = index + 1
  end
  assert(not selector or not has_filters, 'Use list flags without an Issue number/URL')
  return M.normalize(filters), selector
end
function M.complete(lead, line, pos)
  local before = line:sub(1, pos - #lead):gsub('^%s*%S+%s*', '')
  local ok, words = pcall(require('git.commands').argv, before)
  if not ok then return {} end
  local inline = lead:match('^(%-%-[%w%-]+=)(.*)$')
  local field = inline and flags[inline:sub(1, -2)] or flags[words[#words]]
  local candidates
  if field then
    candidates = ({ state = states, limit = { '20', '50', '100', '200' }, assignee = { '@me' } })[field] or {}
  else
    candidates = { '--state', '--limit', '--label', '--assignee' }
  end
  local result = {}
  for _, value in ipairs(candidates) do
    local candidate = (inline or '') .. value
    if candidate:sub(1, #lead) == lead then result[#result + 1] = candidate end
  end
  return result
end
return M

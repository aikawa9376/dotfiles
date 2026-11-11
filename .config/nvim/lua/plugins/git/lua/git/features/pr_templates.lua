local M = {}
local github = require('git.features.github')

-- Ask the target repository, not the checked-out feature branch or cwd.
-- GitHub resolves its published templates, including the default template.
function M.load(ctx)
  local owner, name = ctx.repo:match('^([^/]+)/([^/]+)$')
  local response = github.api(ctx, 'graphql', {
    query = 'query($owner:String!,$name:String!){repository(owner:$owner,name:$name){pullRequestTemplates{filename body}}}',
    variables = { owner = owner, name = name },
  })
  assert(type(response) == 'table' and not response.errors, 'Could not load PR templates from GitHub')
  local repo = response.data and github.scalar(response.data.repository)
  assert(type(repo) == 'table', 'Missing repository for PR templates')
  assert(repo.pullRequestTemplates ~= nil, 'Missing PR templates from GitHub')
  if repo.pullRequestTemplates == vim.NIL then return {} end
  local templates = repo.pullRequestTemplates
  assert(type(templates) == 'table' and vim.islist(templates), 'Missing PR templates from GitHub')
  for _, template in ipairs(templates) do
    assert(type(template) == 'table' and type(template.filename) == 'string' and type(template.body) == 'string',
      'Invalid PR template from GitHub')
  end
  return templates
end

function M.choose(templates, callback)
  if #templates == 0 then callback(nil)
  elseif #templates == 1 then callback(templates[1].body)
  else
    vim.ui.select(templates, { prompt = 'PR template', format_item = function(template) return template.filename end },
      function(template) if template then callback(template.body) end end)
  end
end

return M

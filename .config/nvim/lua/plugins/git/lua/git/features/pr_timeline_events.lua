-- One catalog owns event query details, readable labels and restrained colors.
local M = {}
local scalar = require('git.features.github').scalar
local function text(value, missing) return tostring(scalar(value) or missing or '—'):gsub('[\r\n\t]', ' ') end
local function field(node, name) return type(scalar(node)) == 'table' and scalar(node[name]) or nil end
local function short(commit)
  local value = field(commit, 'abbreviatedOid') or (field(commit, 'oid') or ''):sub(1, 7)
  return value ~= '' and text(value) or '—'
end
local function person(value)
  if not scalar(value) then return '—' end
  if field(value, 'login') then return '@' .. text(value.login) end
  if field(value, 'slug') then return text(field(value.organization, 'login'), '') .. '/' .. text(value.slug) end
  return text(field(value, 'name'))
end
local subject = '... on Issue { number title url repository { nameWithOwner } } ... on PullRequest { number title url repository { nameWithOwner } }'
local actor = '... on Actor { login }'
local reviewer = actor .. ' ... on Team { name slug organization { login } }'
local function reference(value)
  if not scalar(value) then return '—' end
  return text(field(value.repository, 'nameWithOwner'), '') .. '#' .. text(value.number) .. ' ' .. text(value.title, '')
end
local function ref_link(node) return field(node.source, 'url') or field(node.canonical, 'url') end
local specs = {}
local function add(names, label, category, fields, detail, link)
  for name in names:gmatch('%S+') do
    specs[name] = { label = label, category = category, fields = fields or {}, detail = detail, link = link }
  end
end
add('HeadRefForcePushedEvent BaseRefForcePushedEvent', 'force-pushed', 'warning',
  { 'beforeCommit { oid abbreviatedOid }', 'afterCommit { oid abbreviatedOid }' },
  function(n) return short(n.beforeCommit) .. ' → ' .. short(n.afterCommit) end)
specs.BaseRefForcePushedEvent.label = 'force-pushed the base branch'
add('MergedEvent', 'merged', 'positive', { 'commit { oid abbreviatedOid url }' }, function(n) return short(n.commit) end,
  function(n) return field(n.commit, 'url') end)
add('ClosedEvent', 'closed the PR', 'muted')
add('ReopenedEvent', 'reopened the PR', 'positive')
add('ReadyForReviewEvent', 'marked ready for review', 'positive')
add('ConvertToDraftEvent', 'converted to draft', 'warning')
add('HeadRefDeletedEvent', 'deleted the head branch', 'branch', { 'headRefName' }, function(n) return text(n.headRefName) end)
add('HeadRefRestoredEvent', 'restored the head branch', 'branch')
add('BaseRefDeletedEvent', 'deleted the base branch', 'warning', { 'baseRefName' }, function(n) return text(n.baseRefName) end)
add('BaseRefChangedEvent', 'changed the base branch', 'branch', { 'previousRefName', 'currentRefName' },
  function(n) return text(n.previousRefName) .. ' → ' .. text(n.currentRefName) end)
add('AutomaticBaseChangeSucceededEvent', 'automatically changed the base', 'branch', { 'oldBase', 'newBase' },
  function(n) return text(n.oldBase) .. ' → ' .. text(n.newBase) end)
add('AutomaticBaseChangeFailedEvent', 'could not change the base', 'warning', { 'oldBase', 'newBase' },
  function(n) return text(n.oldBase) .. ' → ' .. text(n.newBase) end)
add('LabeledEvent', 'added label', 'label', { 'label { name }' }, function(n) return text(field(n.label, 'name')) end)
add('UnlabeledEvent', 'removed label', 'label', { 'label { name }' }, function(n) return text(field(n.label, 'name')) end)
add('AssignedEvent', 'assigned', 'review', { 'assignee { ' .. actor .. ' }' }, function(n) return person(n.assignee) end)
add('UnassignedEvent', 'unassigned', 'review', { 'assignee { ' .. actor .. ' }' }, function(n) return person(n.assignee) end)
add('ReviewRequestedEvent', 'requested a review from', 'review', { 'requestedReviewer { ' .. reviewer .. ' }' },
  function(n) return person(n.requestedReviewer) end)
add('ReviewRequestRemovedEvent', 'removed the review request for', 'review', { 'requestedReviewer { ' .. reviewer .. ' }' },
  function(n) return person(n.requestedReviewer) end)
add('ReviewDismissedEvent', 'dismissed a review', 'warning',
  { 'review { author { login } url }', 'previousReviewState', 'dismissalMessage' },
  function(n) return person(field(n.review, 'author')) .. ' (' .. text(n.previousReviewState) .. ')'
    .. (scalar(n.dismissalMessage) and (' · ' .. text(n.dismissalMessage)) or '') end,
  function(n) return field(n.review, 'url') end)
add('RenamedTitleEvent', 'changed the title', 'branch', { 'previousTitle', 'currentTitle' },
  function(n) return text(n.previousTitle) .. ' → ' .. text(n.currentTitle) end)
add('MilestonedEvent', 'added to milestone', 'project', { 'milestoneTitle' }, function(n) return text(n.milestoneTitle) end)
add('DemilestonedEvent', 'removed from milestone', 'project', { 'milestoneTitle' }, function(n) return text(n.milestoneTitle) end)
add('AddedToProjectEvent', 'added to a project', 'project')
add('RemovedFromProjectEvent', 'removed from a project', 'project')
add('MovedColumnsInProjectEvent', 'moved project columns', 'project')
add('AddedToProjectV2Event', 'added to project', 'project', { 'project { title url }' },
  function(n) return text(field(n.project, 'title')) end, function(n) return field(n.project, 'url') end)
add('RemovedFromProjectV2Event', 'removed from project', 'project', { 'project { title url }' },
  function(n) return text(field(n.project, 'title')) end, function(n) return field(n.project, 'url') end)
add('ProjectV2ItemStatusChangedEvent', 'changed project status', 'project', { 'project { title url }', 'previousStatus', 'status' },
  function(n) return text(field(n.project, 'title')) .. ': ' .. text(n.previousStatus) .. ' → ' .. text(n.status) end,
  function(n) return field(n.project, 'url') end)
add('ConvertedFromDraftEvent', 'converted a project draft to an issue', 'project', { 'project { title url }' },
  function(n) return text(field(n.project, 'title')) end)
add('ConvertedNoteToIssueEvent', 'converted a project note to an issue', 'project', { 'projectColumnName' },
  function(n) return text(n.projectColumnName) end)
add('DeployedEvent', 'deployed to', 'deployment', { 'deployment { environment description commit { oid abbreviatedOid url } }' },
  function(n) return text(field(n.deployment, 'environment')) .. ' · ' .. short(field(n.deployment, 'commit')) end)
add('DeploymentEnvironmentChangedEvent', 'deployment status', 'deployment',
  { 'deploymentStatus { state environment environmentUrl logUrl description }' },
  function(n) return text(field(n.deploymentStatus, 'environment')) .. ' · ' .. text(field(n.deploymentStatus, 'state'))
    .. (field(n.deploymentStatus, 'description') and (' · ' .. text(n.deploymentStatus.description)) or '') end,
  function(n) return field(n.deploymentStatus, 'logUrl') or field(n.deploymentStatus, 'environmentUrl') end)
add('AutoMergeEnabledEvent', 'enabled auto-merge', 'positive')
add('AutoRebaseEnabledEvent', 'enabled auto-rebase', 'positive')
add('AutoSquashEnabledEvent', 'enabled auto-squash', 'positive')
add('AutoMergeDisabledEvent', 'disabled auto-merge', 'warning', { 'reason' }, function(n) return scalar(n.reason) end)
add('AddedToMergeQueueEvent', 'added to the merge queue', 'positive')
add('RemovedFromMergeQueueEvent', 'removed from the merge queue', 'warning', { 'reason' }, function(n) return scalar(n.reason) end)
add('AddedToStackEvent', 'added to stack', 'branch', { 'stackNumber' }, function(n) return '#' .. text(n.stackNumber) end)
add('RemovedFromStackEvent', 'removed from stack', 'branch', { 'stackNumber' }, function(n) return '#' .. text(n.stackNumber) end)
add('CrossReferencedEvent', 'mentioned this PR in', 'reference', { 'source { ' .. subject .. ' }' },
  function(n) return reference(n.source) end, ref_link)
add('ConnectedEvent', 'connected', 'reference', { 'source { ' .. subject .. ' }' }, function(n) return reference(n.source) end, ref_link)
add('DisconnectedEvent', 'disconnected', 'reference', { 'source { ' .. subject .. ' }' }, function(n) return reference(n.source) end, ref_link)
add('ReferencedEvent', 'referenced this PR in commit', 'reference', { 'commit { oid abbreviatedOid url messageHeadline }' },
  function(n) return short(n.commit) .. ' ' .. text(field(n.commit, 'messageHeadline'), '') end,
  function(n) return field(n.commit, 'url') end)
add('MarkedAsDuplicateEvent', 'marked as a duplicate of', 'reference', { 'canonical { ' .. subject .. ' }' },
  function(n) return reference(n.canonical) end, ref_link)
add('UnmarkedAsDuplicateEvent', 'removed duplicate status for', 'reference', { 'canonical { ' .. subject .. ' }' },
  function(n) return reference(n.canonical) end, ref_link)
add('TransferredEvent', 'transferred from', 'reference', { 'fromRepository { nameWithOwner }' },
  function(n) return text(field(n.fromRepository, 'nameWithOwner')) end)
add('ConvertedToDiscussionEvent', 'converted to discussion', 'reference', { 'discussion { title url number }' },
  function(n) return '#' .. text(field(n.discussion, 'number')) .. ' ' .. text(field(n.discussion, 'title')) end,
  function(n) return field(n.discussion, 'url') end)
add('LockedEvent', 'locked the conversation', 'warning', { 'lockReason' }, function(n) return scalar(n.lockReason) end)
add('UnlockedEvent', 'unlocked the conversation', 'muted')
add('PinnedEvent', 'pinned the issue', 'muted')
add('UnpinnedEvent', 'unpinned the issue', 'muted')
add('IssueCommentPinnedEvent', 'pinned a comment', 'muted', { 'issueComment { url }' }, nil, function(n) return field(n.issueComment, 'url') end)
add('IssueCommentUnpinnedEvent', 'unpinned a comment', 'muted', { 'issueComment { url }' }, nil, function(n) return field(n.issueComment, 'url') end)
add('SubscribedEvent', 'subscribed', 'muted')
add('UnsubscribedEvent', 'unsubscribed', 'muted')
add('MentionedEvent', 'was mentioned', 'muted')
add('CommentDeletedEvent', 'deleted a comment', 'muted', { 'deletedCommentAuthor { login }' }, function(n) return person(n.deletedCommentAuthor) end)
add('UserBlockedEvent', 'blocked a user', 'warning', { 'blockDuration' }, function(n) return scalar(n.blockDuration) end)
add('ArchivedEvent', 'archived', 'muted')
add('UnarchivedEvent', 'unarchived', 'muted')
add('IssueTypeAddedEvent', 'set issue type', 'project', { 'issueType { name }' }, function(n) return text(field(n.issueType, 'name')) end)
add('IssueTypeRemovedEvent', 'removed issue type', 'project', { 'issueType { name }' }, function(n) return text(field(n.issueType, 'name')) end)
add('IssueTypeChangedEvent', 'changed issue type', 'project', { 'prevIssueType { name }', 'issueType { name }' },
  function(n) return text(field(n.prevIssueType, 'name')) .. ' → ' .. text(field(n.issueType, 'name')) end)
for _, relation in ipairs({ { 'SubIssue', 'sub-issue', 'subIssue' }, { 'ParentIssue', 'parent issue', 'parent' },
  { 'BlockedBy', 'blocking issue', 'blockingIssue' }, { 'Blocking', 'blocked issue', 'blockedIssue' } }) do
  for _, action in ipairs({ 'Added', 'Removed' }) do
    local key = relation[3]
    add(relation[1] .. action .. 'Event', (action == 'Added' and 'added ' or 'removed ') .. relation[2], 'reference',
      { key .. ' { number title url repository { nameWithOwner } }' }, function(n) return reference(n[key]) end,
      function(n) return field(n[key], 'url') end)
  end
end
add('IssueFieldAddedEvent', 'set issue field', 'project', { 'issueField { ... on IssueFieldCommon { name } }', 'value' },
  function(n) return text(field(n.issueField, 'name')) .. ': ' .. text(n.value) end)
add('IssueFieldChangedEvent', 'changed issue field', 'project', { 'issueField { ... on IssueFieldCommon { name } }', 'previousValue', 'newValue' },
  function(n) return text(field(n.issueField, 'name')) .. ': ' .. text(n.previousValue) .. ' → ' .. text(n.newValue) end)
add('IssueFieldRemovedEvent', 'removed issue field', 'project', { 'issueField { ... on IssueFieldCommon { name } }' }, function(n) return text(field(n.issueField, 'name')) end)

local categories = {
  label = { '◆ ', 'GitPrTimelineLabel', 'Type' }, review = { '◇ ', 'GitPrTimelineReview', 'DiagnosticInfo' },
  branch = { '↻ ', 'GitPrTimelineBranch', 'Special' }, project = { '▣ ', 'GitPrTimelineProject', 'Identifier' },
  deployment = { '▶ ', 'GitPrTimelineDeployment', 'DiagnosticInfo' }, reference = { '↗ ', 'GitPrTimelineReference', 'Underlined' },
  warning = { '↻ ', 'DiagnosticWarn' }, positive = { '✓ ', 'GitPrPositive' }, muted = { '· ', 'Comment' },
}
function M.setup_groups()
  for _, category in pairs(categories) do if category[3] then
    vim.api.nvim_set_hl(0, category[2], { default = true, link = category[3] })
  end end
end
function M.fragments(types)
  local fragments = {}
  for _, name in ipairs(vim.tbl_keys(types)) do
    local fields = types[name]
    if fields.actor and fields.createdAt and fields.id then
      local selected = { 'id', 'createdAt', 'actor { login }' }
      if fields.url then selected[#selected + 1] = 'url' end
      for _, query in ipairs(specs[name] and specs[name].fields or {}) do
        if fields[query:match('^%w+')] then selected[#selected + 1] = query end
      end
      fragments[#fragments + 1] = '... on ' .. name .. ' { ' .. table.concat(selected, ' ') .. ' }'
    end
  end
  table.sort(fragments)
  return table.concat(fragments, '\n')
end
function M.fallback_types()
  local result = {}
  for name in ('HeadRefForcePushedEvent MergedEvent ClosedEvent ReopenedEvent ReadyForReviewEvent ConvertToDraftEvent '
    .. 'HeadRefDeletedEvent HeadRefRestoredEvent LabeledEvent UnlabeledEvent AssignedEvent UnassignedEvent '
    .. 'ReviewRequestedEvent ReviewRequestRemovedEvent RenamedTitleEvent MilestonedEvent DemilestonedEvent'):gmatch('%S+') do
    local fields = { id = true, actor = true, createdAt = true }
    for _, query in ipairs(specs[name].fields) do fields[query:match('^%w+')] = true end
    result[name] = fields
  end
  return result
end
function M.entry(ctx, node)
  if type(node.__typename) ~= 'string' or not node.__typename:match('Event$') or not scalar(node.id) then return end
  local spec = specs[node.__typename] or { label = node.__typename:gsub('Event$', ''):gsub('(%l)(%u)', '%1 %2'):lower(), category = 'muted' }
  local category = categories[spec.category]
  if node.__typename == 'DeploymentEnvironmentChangedEvent' then
    local state = field(node.deploymentStatus, 'state')
    if state == 'SUCCESS' then category = categories.positive
    elseif state == 'ERROR' or state == 'FAILURE' then category = { '✗ ', 'DiagnosticError' }
    elseif state == 'PENDING' or state == 'IN_PROGRESS' or state == 'QUEUED' or state == 'WAITING' then category = { '◷ ', 'DiagnosticWarn' } end
  end
  local detail = spec.detail and spec.detail(node)
  local parts = { { spec.label, 'Normal' } }
  if detail and detail ~= '' then parts[#parts + 1] = { ' ' .. text(detail), category[2] } end
  local label = ''; for _, part in ipairs(parts) do label = label .. part[1] end
  local url = (spec.link and spec.link(node)) or scalar(node.url) or ctx.url
  -- Deployment environment/log targets may be external. Only browser URLs
  -- belong in the shared Enter/gx route.
  local authority = type(url) == 'string' and url:match('^https?://([^/?#%s]+)')
  if not authority or authority:find('@', 1, true) or url:find('[\r\n%z]') then url = ctx.url end
  return { kind = 'event', key = 'event:' .. node.id, id = node.id, event_type = node.__typename,
    label = label, parts = parts, icon = category[1], group = category[2], body = '', user = scalar(node.actor),
    created_at = scalar(node.createdAt) or '', updated_at = scalar(node.createdAt) or '', url = url }
end
M.setup_groups()
vim.api.nvim_create_autocmd('ColorScheme', {
  group = vim.api.nvim_create_augroup('GitPrTimelineColors', { clear = true }), callback = M.setup_groups,
})
return M

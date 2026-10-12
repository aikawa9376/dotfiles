local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local model = require('git.features.ci.model')
local ctx = { host = 'github.com', repo = 'org/repo', number = 7 }
local sha = string.rep('a', 40)
local checks = model.normalize({
  { id = 1, name = 'same', status = 'completed', conclusion = 'success', details_url = 'https://github.com/org/repo/actions/runs/9/job/11', app = { slug = 'github-actions' } },
  { id = 2, name = 'same', status = 'queued', details_url = 'https://github.com/org/repo/actions/runs/9/job/12' },
  { id = 3, name = 'cancel', conclusion = 'cancelled' },
  { id = 4, name = 'neutral', conclusion = 'neutral' },
  { id = 5, name = 'fail1', conclusion = 'timed_out' },
  { id = 6, name = 'fail2', conclusion = 'action_required' },
}, {
  { id = 20, context = 'ci/circleci: build', state = 'failure', created_at = '2026-10-11', target_url = 'https://circleci.com/gh/org/repo/10' },
  { id = 21, context = 'ci/circleci: build', state = 'success', created_at = '2026-10-12', target_url = 'https://circleci.com/gh/org/repo/11' },
}, ctx, sha)
assert(#checks == 7 and checks[1].name == 'fail1' and checks[2].name == 'fail2', 'Outcome sort should preserve source order')
assert(checks[3].bucket == 'pending' and checks[4].bucket == 'cancel' and checks[7].bucket == 'skipping')
assert(checks[6].kind == 'status' and checks[6].provider == 'circleci' and checks[6].raw.id == 21)
assert(checks[3].id ~= checks[5].id and checks[3].name == checks[5].name, 'Same names must retain distinct identities')
local seed = model.rollup({ headRefOid = sha, statusCheckRollup = { { name = 'same', detailsUrl = checks[3].url, status = 'QUEUED' } } }, ctx)[1]
assert(model.match(seed, checks).check_run_id == 2)
assert(model.check(seed.raw, ctx, sha, 'check_run', 99).id == seed.id, 'Linked check identity must survive list reordering')
local duplicate = vim.deepcopy(checks[3]); duplicate.check_run_id = 99
local found, err = model.match(seed, { checks[3], duplicate }); assert(not found and err:find('Ambiguous'))
assert(not model.match(seed, { checks[5] }), 'Names alone must not resolve jobs')
for _, url in ipairs({ 'file:///tmp/file', 'javascript:alert(1)', 'http://example.test/a', 'https://good.test@evil.test/a', 'https://good.test/a\nheader' }) do assert(not model.web_url(url)) end
assert(model.web_url('https://example.test/path?secret=signature#x') == 'https://example.test/path')
assert(model.duration('2026-10-12T01:00:00Z', '2026-10-12T01:00:42Z') == '42s')
assert(model.duration('2026-10-12T10:00:00+09:00', '2026-10-12T01:00:42Z') == '42s')
print('PASS: stable provider IDs, outcome sorting, latest statuses, ambiguous identities, safe web URLs and timezone durations')

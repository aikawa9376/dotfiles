local source = debug.getinfo(1, 'S').source:sub(2)
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ':p')))
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/tests/?.lua;' .. package.path
local f = require('helpers.pr_fixture').new()
f.git({ 'commit', '--allow-empty', '-qm', '追加\tcommit' })
local head = f.git({ 'rev-parse', 'HEAD' })
f.pr.headRefOid = head
f.git({ 'update-ref', 'refs/pull/7/head', head })
local view = require('git.features.pr')
local ui = require('helpers.pr_ui').new(f)
local log_reads, system = 0, vim.system
vim.system = function(argv, opts, callback)
  if argv[1] == 'git' and vim.tbl_contains(argv, 'log') then
    assert(callback, 'PR history collection blocked the UI')
    log_reads = log_reads + 1
  end
  return system(argv, opts, callback)
end
ui.open()
local function lines() return vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false) end
local function collapsed() assert(not pcall(ui.row, head:sub(1, 7) .. '\t')) end
local function marker(value)
  local row = ui.row('Commits (')
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(ui.buf, vim.api.nvim_create_namespace('git_pr_status'),
    { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    if mark[4].sign_text then assert(mark[4].sign_text:gsub('%s+$', '') == value); return end
  end
  error('Missing commit-section gutter marker')
end
local model = view.model(ui.buf)
assert(model.commit_count == 2 and #model.commits == 2 and model.commits[1].hash == head)
assert(model.commits[2].hash == f.head and model.commits[1].subject == '追加 commit')
assert(ui.row('Commits (2)') < ui.row('Changes (4)'))
collapsed(); marker('▸')
local calls = #f.calls
ui.key('o', ui.row('Commits (2)'))
local commit_row = ui.row(head:sub(1, 7) .. '\t')
assert(view.commit_at(ui.buf, commit_row).hash == head and not view.entry_at(ui.buf, commit_row))
marker('▾')
local groups = {}
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(ui.buf, vim.api.nvim_create_namespace('git_pr_status'),
  { commit_row - 1, 0 }, { commit_row - 1, -1 }, { details = true })) do
  groups[lines()[commit_row]:sub(mark[3] + 1, mark[4].end_col)] = mark[4].hl_group
end
assert(groups[model.commits[1].short] == require('git.features.commit_highlight').group('default'))
assert(groups[model.commits[1].date] == 'GitLogDate' and groups['追加 commit'] == 'Normal' and groups.Test == 'GitLogAuthor')
-- Draft growth shifts commit rows; folding must preserve it and file state.
local title = ui.row('PR title')
vim.api.nvim_buf_set_lines(ui.buf, title - 1, title, false, { 'Edited PR title' })
vim.api.nvim_buf_set_lines(ui.buf, title + 1, title + 1, false, { 'Added body line' })
commit_row = ui.row(head:sub(1, 7) .. '\t')
assert(view.commit_at(ui.buf, commit_row).hash == head)
local opened
vim.ui.open = function(url) opened = url end
ui.key('gx', commit_row)
assert(opened == ('https://ghe.example.test/org/repo/commit/' .. head))
ui.key('<CR>', commit_row)
local commit_buf = vim.api.nvim_get_current_buf()
assert(vim.b[commit_buf].git_commit == head and vim.bo[commit_buf].filetype == 'gitcommitview')
vim.api.nvim_buf_delete(commit_buf, { force = true }); ui.source()
for _, key in ipairs({ '=', '<Tab>', 'o', '<CR>' }) do
  ui.key(key, ui.row('Commits (2)')); collapsed(); marker('▸')
  assert(ui.row('Edited PR title') and ui.row('Added body line') and vim.bo[ui.buf].modified)
  ui.key('>', ui.row('Commits (2)')); marker('▾')
end
assert(#f.calls == calls and log_reads == 1, 'Opening/folding history repeated remote or Git log work')
-- Commit rows are read-only and cannot be submitted as PR metadata.
commit_row = ui.row(head:sub(1, 7) .. '\t')
local original = lines()[commit_row]
vim.api.nvim_buf_set_lines(ui.buf, commit_row - 1, commit_row, false, { 'Tampered commit' })
assert(not pcall(view.write, ui.buf) and #f.calls == calls)
vim.api.nvim_buf_set_lines(ui.buf, commit_row - 1, commit_row, false, { original })
view.refresh(ui.buf, true)
ui.wait(function() return view.model(ui.buf) ~= model end)
assert(ui.row(head:sub(1, 7) .. '\t') and log_reads == 1, 'Refresh lost expansion or rebuilt immutable history')
ui.key('<', ui.row('Commits (2)')); collapsed()
ui.expand_files()
ui.wait(function() return vim.tbl_contains(lines(), '+TWO') end)
collapsed(); assert(ui.row('+TWO'))
ui.refresh(); collapsed(); assert(ui.row('+TWO') and log_reads == 1)
-- No PR commits still has an operable, empty section and the correct count.
f.git({ 'update-ref', 'refs/heads/main', head }); f.pr.baseRefOid = head
ui.refresh()
assert(view.model(ui.buf).commit_count == 0 and #view.model(ui.buf).commits == 0 and log_reads == 2)
ui.key('o', ui.row('Commits (0)')); marker('▾')
assert(ui.row('Changes (0)') == ui.row('Commits (0)') + 2)
vim.api.nvim_buf_delete(ui.buf, { force = true }); f.cleanup()
print('PASS: PR-only history, default folding, GitLog colors, navigation, draft protection, fold/cache persistence and empty history')

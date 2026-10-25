local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.rtp:prepend(plugin)
vim.opt.rtp:append(vim.fn.stdpath('data') .. '/site')
vim.opt.rtp:prepend(vim.fn.stdpath('data') .. '/lazy/nvim-treesitter/runtime')
vim.cmd('syntax enable')
local syntax = require('git.features.syntax_highlight')
local ns = vim.api.nvim_create_namespace('git_extension_syntax')
assert(syntax.config.highlight_new_files == false, 'new files must be untinted by default')
local function settle(buf)
  assert(vim.wait(10000, function() return not syntax.is_pending(buf) end, 1), 'highlighting did not settle')
end
local function open(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = 'diff'
  syntax.attach(buf)
  settle(buf)
  return buf
end
local function groups(buf)
  local found = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local opts = mark[4]
    if opts.hl_group then found[opts.hl_group] = true end
    if opts.virt_text then found[opts.virt_text[1][2]] = true end
  end
  return found
end
local additions = { 'GitExtAdd', 'GitExtAddText', 'GitExtSyntaxAdd', 'GitExtSyntaxAddText', 'GitExtNovelAdd', 'GitExtAddPrefix' }
local function plain(buf)
  -- Headless -l does not enter the normal input loop that emits TextChanged
  -- after a background Status snapshot replaces its lines.
  local ready = vim.wait(5000, function()
    syntax.refresh(buf)
    return groups(buf).GitExtCode and not syntax.is_pending(buf)
  end, 5)
  assert(ready, 'new file did not finish syntax rendering')
  local found = groups(buf)
  for _, group in ipairs(additions) do assert(not found[group], 'new file retained ' .. group) end
  assert(found.GitExtCode, 'new file must override the underlying diff foreground')
end
for _, style in ipairs({ 'treesitter', 'delta', 'github', 'diffs' }) do
  syntax.set_word_diff_style(style)
  local added = open({ 'A new.lua', '@@ -0,0 +1,2 @@', '+local added = 42', '+return added' })
  local existing = open({ 'M empty.lua', '@@ -0,0 +1 @@', '+return 42' })
  local deleted = open({ 'D removed.lua', '@@ -1 +0,0 @@', '-return 42' })
  plain(added)
  assert(groups(existing).GitExtAddPrefix, 'adding to an existing empty file lost its diff colors')
  assert(groups(deleted).GitExtDeletePrefix, 'deleted file lost its deletion colors')
  local captures = groups(added)
  local has_syntax = false
  for group in pairs(captures) do if group:match('^@') then has_syntax = true end end
  assert(has_syntax, 'new Lua file lost syntax captures')
  syntax.toggle_changed_fg(); settle(added); plain(added)
  syntax.set_highlight_new_files(true); settle(added)
  assert(groups(added).GitExtAddPrefix, 'legacy new-file colors cannot be selected')
  assert(groups(added)[style == 'treesitter' and 'GitExtSyntaxAdd' or 'GitExtAdd'], 'legacy new-file backgrounds were not restored')
  syntax.set_highlight_new_files(false); settle(added); plain(added)
  assert(groups(existing).GitExtAddPrefix and groups(deleted).GitExtDeletePrefix, 'new-file toggle changed other files')
  syntax.toggle_changed_fg()
  for _, buf in ipairs({ added, existing, deleted }) do vim.api.nvim_buf_delete(buf, { force = true }) end
end
syntax.set_word_diff_style('treesitter')
for _, lines in ipairs({
  { 'diff --git a/raw.lua b/raw.lua', 'new file mode 100644', 'index 0000000..1234567', '--- /dev/null', '+++ b/raw.lua', '@@ -0,0 +1 @@', '+return 42' },
  { '? untracked.lua', '@@ new file: untracked.lua (1 lines) @@', '+return 42' },
  { 'A unknown.no_parser_for_this', '@@ -0,0 +1 @@', '+plain text' },
}) do
  local buf = open(lines); plain(buf); vim.api.nvim_buf_delete(buf, { force = true })
end

-- A rename whose old file happens to be empty remains an ordinary comparison.
local renamed = open({ 'R old.lua -> new.lua', '@@ -0,0 +1 @@', '+return 42' })
assert(groups(renamed).GitExtSyntaxAdd, 'rename was mistaken for a wholly new file')
vim.api.nvim_buf_delete(renamed, { force = true })
require('git').setup({ highlight_new_files = true })
assert(syntax.config.highlight_new_files == true, 'setup cannot select the legacy default')
require('git').setup({ highlight_new_files = false })

-- Real panel metadata, including missing-side flags on native split windows.
local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
local function git(args)
  local argv = { 'git', '-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false' }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait(); assert(result.code == 0, result.stderr)
end
git({ 'init', '-qb', 'main' })
vim.fn.writefile({}, root .. '/empty.lua')
git({ 'add', '.' }); git({ 'commit', '-qm', 'before' })
vim.fn.writefile({ 'local value = 42', 'return value' }, root .. '/new.lua')
vim.fn.writefile({ 'return 42' }, root .. '/empty.lua')
git({ 'add', '.' }); git({ 'commit', '-qm', 'after' })
vim.fn.writefile({ 'local fresh = 42', 'return fresh' }, root .. '/untracked.lua')
local function row(buf, text)
  local found
  assert(vim.wait(3000, function()
    for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if line == text then found = i; return true end
    end
  end, 5), 'missing panel row ' .. text)
  vim.api.nvim_win_set_cursor(0, { found, 0 })
end
local function press(key) assert(vim.fn.maparg(key, 'n', false, true).callback, key)() end
local split = require('git.features.split_diff')
local function split_ready(expected_new)
  local session
  assert(vim.wait(10000, function()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      session = split.session(win)
      if session and session.active and not session.pending then return true end
    end
  end, 5), 'panel did not open a split')
  assert(session.new_file == expected_new, 'split confused a missing file with an existing empty file')
  assert((next(session.plan.new) == nil) == expected_new, 'split new-file tint policy was not applied')
  vim.cmd('tabclose')
end
local status = require('git.features.status').open({ work_tree = root, split = true, auto_fetch = false })
row(status, '? untracked.lua'); press('o'); row(status, '+local fresh = 42'); syntax.refresh(status); settle(status); plain(status)
press('gD'); press('n')
assert(syntax.config.highlight_new_files, 'gD n did not enable the legacy new-file colors')
syntax.set_highlight_new_files(false); settle(status); plain(status)
row(status, '? untracked.lua'); press('d'); split_ready(true)
local commit = require('git.features.commit').open({ work_tree = root, split = true })
row(commit, 'A new.lua'); press('o'); row(commit, '+local value = 42'); syntax.refresh(commit); settle(commit); plain(commit)
press('d'); split_ready(true)
row(commit, 'M empty.lua'); press('d'); split_ready(false)
vim.api.nvim_buf_delete(commit, { force = true }); vim.api.nvim_buf_delete(status, { force = true })
vim.fn.delete(root, 'rf')
print('PASS: new-file tint default/toggle in all styles, syntax, raw/untracked patches, existing empty files, deletion and setup')

-- nvim --headless --clean -u NONE -l tests/syntax_highlight_portability.lua
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.rtp:prepend(plugin)
vim.opt.rtp:append(vim.fn.stdpath('data') .. '/site')
vim.opt.rtp:prepend(vim.fn.stdpath('data') .. '/lazy/nvim-treesitter/runtime')
assert(pcall(vim.treesitter.language.inspect, 'php'), 'install the PHP parser')
local syntax = require('git.features.syntax_highlight')
local ns = vim.api.nvim_create_namespace('git_extension_syntax')
local before = { '<?php', '$map = [', "  M => 'kept',", "  U => 'kept',", "  D => 'kept',", '];',
  '$result = oldCall($map);', 'return $result;' }
local after = vim.deepcopy(before)
after[7] = '$result = newCall($map);'
local following_old, following_new = { '<?php', 'return oldFollowing();' }, { '<?php', 'return newFollowing();' }
local function open(status)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = { (status or 'M') .. ' invoice.php', '@@ -1,8 +1,8 @@' }
  for row = 1, 6 do lines[#lines + 1] = ' ' .. before[row] end
  vim.list_extend(lines, { '-' .. before[7], '+' .. after[7], ' ' .. before[8],
    'M following.php', '@@ -1,2 +1,2 @@', ' <?php', '-' .. following_old[2], '+' .. following_new[2],
    'M following.lua', '@@ -1 +1 @@', '-return oldFollowing()', '+return newFollowing()' })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  syntax.attach(buf, { diff_source = function(hunk)
    local lhs, rhs = before, after
    if hunk.filename == 'following.php' then lhs, rhs = following_old, following_new end
    if hunk.filename == 'following.lua' then lhs, rhs = { 'return oldFollowing()' }, { 'return newFollowing()' } end
    return { path = hunk.filename, old = { text = table.concat(lhs, '\n') },
      new = { text = table.concat(rhs, '\n') } }
  end })
  return buf
end
local function settle(buf)
  assert(vim.wait(10000, function() return not syntax.is_pending(buf) end, 1), 'portable rendering did not finish')
end
local function check(buf, expect_syntax)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local prefixes, backgrounds, captures, lua_captures = {}, {}, {}, {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local row, options = mark[2] + 1, mark[4]
    if options.virt_text_pos == 'overlay' then prefixes[row] = true end
    if (options.hl_group or ''):match('^GitExtSyntax') then backgrounds[row] = true end
    if (options.hl_group or ''):match('^@.*%.php$') then captures[row] = true end
    if (options.hl_group or ''):match('^@.*%.lua$') then lua_captures[row] = true end
    assert(options.virt_text_pos ~= 'eol', 'finished rendering retained its spinner')
  end
  local lua_file = false
  for row, line in ipairs(lines) do
    if line == 'M following.lua' then lua_file = true end
    local changed = line:match('^[+-]') ~= nil
    assert((prefixes[row] == true) == changed, 'missing/misplaced prefix at row ' .. row)
    if changed then
      assert(backgrounds[row], 'change has no background at row ' .. row)
      if lua_file then
        assert(lua_captures[row], 'broken PHP query blocked a healthy subsequent language')
      elseif expect_syntax ~= nil then
        assert((captures[row] == true) == expect_syntax, 'wrong PHP syntax availability at row ' .. row)
      end
    end
  end
end

-- PHP constants that look like statuses must not truncate either file's hunk.
local buf = open()
settle(buf); check(buf, true)
syntax.refresh(buf); settle(buf); check(buf, true)
vim.api.nvim_buf_delete(buf, { force = true })

-- An incompatible query on another machine must not abort attachment or skip
-- later files. Exercise the actual Tree-sitter query compiler, not a mock.
for _, query_text in ipairs({ '(git_test_nonexistent_php_node) @keyword',
  '((name) @function (#lua-match? @function "["))', '' }) do
  vim.treesitter.query.set('php', 'highlights', query_text)
  local valid, query = pcall(vim.treesitter.query.get, 'php', 'highlights')
  if query_text:find('nonexistent', 1, true) then
    assert(not valid and tostring(query):find('Invalid node type', 1, true), 'query fixture is not incompatible')
  elseif query_text ~= '' then
    assert(valid and query, 'predicate fixture did not compile')
    local code = table.concat(before, '\n')
    local tree = vim.treesitter.get_string_parser(code, 'php'):parse()[1]
    local captured, err = pcall(function() for _ in query:iter_captures(tree:root(), code) do end end)
    assert(not captured and tostring(err):find('malformed pattern', 1, true), 'predicate fixture did not fail at runtime')
  else
    assert(valid and query == nil, 'empty query fixture did not simulate a missing query')
  end
  buf = open()
  settle(buf); check(buf, false)
  syntax.refresh(buf); settle(buf); check(buf, false)
  vim.treesitter.query.set('php', 'highlights', nil)
  syntax.refresh(buf); settle(buf); check(buf, true)
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- A new machine can lack PHP parsers altogether. Word backgrounds and gutters
-- still work; restoring the parser without editing restores source captures.
local inspect = vim.treesitter.language.inspect
vim.treesitter.language.inspect = function(lang)
  if lang == 'php' then error('PHP parser unavailable') end
  return inspect(lang)
end
buf = open()
settle(buf); check(buf, false)
vim.treesitter.language.inspect = inspect
syntax.refresh(buf); settle(buf); check(buf, true)
vim.api.nvim_buf_delete(buf, { force = true })

-- T is a real Git type-change status and must supply the file's language.
buf = open('T')
settle(buf); check(buf, true)
vim.api.nvim_buf_delete(buf, { force = true })
print('PASS: PHP status-like context, adjacent files, incompatible queries, missing/restored parsers and type-change file rows')

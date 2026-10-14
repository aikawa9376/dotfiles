local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')))
vim.opt.rtp:prepend(plugin)
local projection = require('diffview_extension.comment_projection')
local function check(reference, current, first, last, expected)
  local a, b = projection.range(projection.prepare(reference, current), first, last)
  assert(vim.deep_equal({ a, b }, expected or {}), vim.inspect({ reference, current, first, last, actual = { a, b }, expected = expected }))
end
local ref = { 'one', 'two', 'three', 'four', 'five' }
check(ref, ref, 2, 4, { 2, 4 })
check(ref, { 'before', 'one', 'two', 'three', 'four', 'five' }, 2, 4, { 3, 5 })
check(ref, { 'one', 'before', 'two', 'three', 'four', 'five' }, 2, 4, { 3, 5 })
check(ref, { 'one', 'two', 'three', 'four', 'after', 'five' }, 2, 4, { 2, 4 })
check(ref, { 'one', 'two', 'inside', 'three', 'four', 'five' }, 2, 4)
check(ref, { 'one', 'TWO', 'three', 'four', 'five' }, 2, 4)
check(ref, { 'one', 'two', 'four', 'five' }, 2, 4)
check(ref, { 'two', 'three', 'four', 'five' }, 2, 4, { 1, 3 })
check(ref, { 'one', 'two', 'three', 'four' }, 2, 4, { 2, 4 })
check(ref, ref, 0, 2)
check(ref, ref, 2, 6)
check(ref, ref, 2.5, 3)
check(ref, {}, 2, 4)
check({ 'repeat', 'repeat', 'repeat', 'repeat', 'repeat', 'repeat', 'repeat' },
  { 'prefix', 'repeat', 'repeat', 'repeat', 'repeat', 'repeat', 'repeat', 'repeat' }, 4, 4)
check({ 'one', 'repeat', 'two', 'repeat', 'three' },
  { 'prefix', 'one', 'repeat', 'two', 'repeat', 'three' }, 2, 2, { 3, 3 })
check({ 'one', 'two', 'three' }, { 'three', 'one', 'two' }, 3, 3) -- Moved/replaced code is not an unchanged anchor.
print('PASS: exact, shifted, multi-line, changed, deleted and ambiguous comment anchors')

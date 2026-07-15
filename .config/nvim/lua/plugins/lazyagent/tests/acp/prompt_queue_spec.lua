local M = {}

local function assert_equal(expected, actual, label)
  if not vim.deep_equal(expected, actual) then
    error(string.format("%s: expected %s, got %s", label, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

function M.run()
  local Queue = require("lazyagent.acp.prompt_queue")
  local session = { prompt_queue = {} }
  local first = Queue.push(session, "first")
  local second = Queue.push(session, "second")
  local third = Queue.push(session, "third")
  assert_equal("prompt-1", first.id, "stable first queue id")
  assert_equal("prompt-3", third.id, "stable third queue id")

  assert_equal("second edited", assert(Queue.edit(session, second.id, "second edited\n")).text, "queue edit")
  assert_equal(1, select(2, Queue.move(session, third.id, -10)), "queue move clamps to start")
  assert_equal(third.id, Queue.list(session)[1].id, "queue reordered item")
  assert_equal(first.id, assert(Queue.promote(session, first.id)).id, "queue promotion")
  assert_equal(first.id, Queue.list(session)[1].id, "promoted queue order")
  assert_equal(second.id, assert(Queue.remove(session, second.id)).id, "queue remove")
  assert_equal(2, #Queue.list(session), "queue size after remove")
  assert_equal("first", assert(Queue.pop(session)).text, "queue pop")
  assert_equal("third", assert(Queue.pop(session)).text, "queue reordered pop")
  assert_equal(nil, Queue.pop(session), "empty queue pop")
end

return M

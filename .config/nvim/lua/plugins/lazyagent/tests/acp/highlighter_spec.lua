local M = {}

function M.run()
  local native = vim.treesitter.highlighter
  local get_parser, get_files = vim.treesitter.get_parser, vim.treesitter.query.get_files
  local defer = vim.defer_fn
  local source = vim.api.nvim_get_current_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  local queued, calls, results = {}, {}, {}
  local parser = { parse = function(_, ranges, callback)
    calls[#calls + 1] = { ranges = ranges, callback = callback }
    if not callback then return "sync" end
  end }
  vim.defer_fn = function(callback, _) queued[#queued + 1] = callback end
  vim.treesitter.get_parser = function() return parser end
  vim.treesitter.query.get_files = function() return {} end
  local active = {}
  vim.treesitter.highlighter = { active = active, new = function(tree)
    active[buf] = { tree = tree, parsing = false }
  end }
  local highlighter = require("lazyagent.acp.highlighter")
  highlighter.start(buf)
  local wrapped = parser.parse
  highlighter.start(buf)
  assert(parser.parse == wrapped, "repeated starts do not stack parse wrappers")
  assert(parser:parse({ 0, 1 }) == "sync", "synchronous callers retain their API")
  local ranges = { { 0, 1 } }
  local function request()
    parser:parse(ranges, function(err, trees) results[#results + 1] = { err = err, trees = trees } end)
  end
  request()
  calls[#calls].callback("TIMEOUT", nil)
  assert(#results == 0 and #queued == 1, "timeout waits for a deferred retry")
  table.remove(queued, 1)()
  assert(calls[#calls].ranges == ranges, "retries preserve injection ranges")
  calls[#calls].callback(nil, {})
  assert(#results == 1 and results[1].trees, "retry delivers completed syntax trees")

  request()
  active[buf].parsing = true
  for _ = 1, 2 do
    calls[#calls].callback("TIMEOUT", nil)
    table.remove(queued, 1)()
  end
  calls[#calls].callback("TIMEOUT", nil)
  -- Native _on_start assigns this after parse returns, even for a sync timeout.
  active[buf].parsing = true
  vim.wait(100, function() return not active[buf].parsing end, 1)
  assert(#queued == 0 and #results == 2 and results[2].err == "TIMEOUT",
    "retries are bounded and notify the caller on exhaustion")
  assert(not active[buf].parsing, "an exhausted native parse cannot stay stuck")

  request()
  calls[#calls].callback("TIMEOUT", nil)
  local call_count = #calls
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "changed reply" })
  table.remove(queued, 1)()
  assert(#calls == call_count and results[#results].err == "CANCELLED",
    "edits cancel queued retries without parsing stale ranges")
  vim.wait(10, function() return false end, 1)

  request()
  calls[#calls].callback("TIMEOUT", nil)
  active[buf] = { tree = {}, parsing = true }
  vim.api.nvim_win_set_buf(0, source)
  table.remove(queued, 1)()
  vim.wait(10, function() return false end, 1)
  assert(#calls == call_count + 1 and results[#results].err == "CANCELLED",
    "hidden buffers cancel queued retries")
  assert(active[buf].parsing, "cleanup leaves a replacement parser alone")
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.treesitter.highlighter = native
  vim.treesitter.get_parser, vim.treesitter.query.get_files = get_parser, get_files
  vim.defer_fn = defer
end

return M

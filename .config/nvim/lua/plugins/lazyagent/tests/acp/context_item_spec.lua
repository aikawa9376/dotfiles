local M = {}

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run()
  local ContextItem = require("lazyagent.acp.context_item")
  local item = ContextItem.file({
    path = "/tmp/example.lua",
    display = "example.lua",
    lines = { "one", "two", "three" },
    start_line = 2,
    end_line = 3,
  })
  assert_equal(item.kind, "range", "range context kind")
  assert_equal(item.content, "two\nthree", "range context content")
  assert_equal(item.note, "Context from example.lua lines 2-3:", "range context note")
  assert_equal(item.size, 9, "range context size")
  assert_equal(item.token_estimate, 3, "range token estimate")
  assert_equal(#item.content_hash, 64, "range content hash")
  assert_equal(item.preview, "two three", "range preview")
  assert_equal(ContextItem.lower(item, { embedded_context = true }).type, "resource", "embedded lowering")
  assert_equal(ContextItem.lower(item, {}).type, "resource_link", "resource link lowering")

  local directory = ContextItem.directory({ path = "/tmp/project", display = "." })
  assert_equal(directory.kind, "directory", "directory context kind")
  assert_equal(ContextItem.lower(directory, {}).type, "resource_link", "directory lowering")

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "/tmp/selection.lua")
  vim.bo[bufnr].filetype = "lua"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "alpha", "beta", "gamma" })
  local selection = assert(ContextItem.selection(bufnr, {
    start_line = 1,
    end_line = 2,
    start_column = 1,
    end_column = 2,
  }))
  assert_equal(selection.kind, "selection", "selection context kind")
  assert_equal(selection.content, "lpha\nbet", "selection context content")
  assert_equal(selection.source_version.bufnr, bufnr, "selection source buffer")
  assert(selection.source_version.changedtick > 0, "selection source changedtick")
  assert_equal(ContextItem.to_markdown(selection), "```lua\nlpha\nbet\n```", "selection markdown lowering")
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

return M

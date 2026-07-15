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
  assert_equal(ContextItem.lower(item, {}).type, "text", "range text fallback lowering")

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
  assert_equal(ContextItem.lower(selection, {}).type, "text", "selection text lowering")

  local namespace = vim.api.nvim_create_namespace("lazyagent-context-item-test")
  vim.diagnostic.set(namespace, bufnr, {
    { lnum = 1, col = 2, severity = vim.diagnostic.severity.WARN, message = "unused value" },
  })
  local diagnostics = assert(ContextItem.diagnostics(bufnr))
  assert_equal(diagnostics.kind, "diagnostics", "diagnostics context kind")
  assert(diagnostics.content:match("selection.lua:2:3: WARN: unused value"), "diagnostics context content")
  assert_equal(ContextItem.lower(diagnostics, {}).type, "text", "diagnostics text lowering")
  assert_equal(ContextItem.lower(diagnostics, { embedded_context = true }).type, "resource", "diagnostics resource lowering")
  vim.diagnostic.reset(namespace, bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  local branch_diff = assert(ContextItem.branch_diff("/tmp/project", {
    run = function(_, args)
      assert_equal(table.concat(args, " "), "diff --no-ext-diff HEAD --", "branch diff git arguments")
      return "diff --git a/file.lua b/file.lua\n+added line\n"
    end,
  }))
  assert_equal(branch_diff.kind, "branch_diff", "branch diff context kind")
  assert_equal(branch_diff.filetype, "diff", "branch diff filetype")
  assert(branch_diff.content:match("%+added line"), "branch diff content")
  assert_equal(ContextItem.lower(branch_diff, {}).type, "text", "branch diff text lowering")

  local symbol_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(symbol_bufnr, "/tmp/symbol.lua")
  vim.bo[symbol_bufnr].filetype = "lua"
  vim.api.nvim_buf_set_lines(symbol_bufnr, 0, -1, false, {
    "local function greet(name)",
    "  return 'hello ' .. name",
    "end",
    "greet('world')",
  })
  local symbol = assert(ContextItem.symbol(symbol_bufnr, { start_line = 1, end_line = 3 }))
  assert_equal(symbol.kind, "symbol", "symbol context kind")
  assert_equal(symbol.content, "local function greet(name)\n  return 'hello ' .. name\nend", "symbol context content")
  assert_equal(symbol.source_version.bufnr, symbol_bufnr, "symbol source buffer")
  assert_equal(ContextItem.lower(symbol, {}).type, "text", "symbol text lowering")
  vim.api.nvim_buf_delete(symbol_bufnr, { force = true })

  local transcript_path = vim.fn.tempname() .. ".md"
  vim.fn.writefile({ "## User", "hello", "## Assistant", "hi" }, transcript_path)
  local previous_thread = assert(ContextItem.previous_thread({
    thread_id = "thread-previous",
    provider_id = "fixture",
    title = "Earlier work",
    transcript_path = transcript_path,
  }))
  assert_equal(previous_thread.kind, "previous_thread", "previous thread context kind")
  assert_equal(previous_thread.thread_id, "thread-previous", "previous thread identity")
  assert(previous_thread.content:match("## Assistant\nhi"), "previous thread content")
  assert_equal(ContextItem.lower(previous_thread, {}).type, "text", "previous thread text lowering")
  vim.fn.delete(transcript_path)

  local terminal = assert(ContextItem.terminal({
    id = "lazyagent-term-4",
    command = { "rg", "TODO", "." },
    cwd = "/tmp/project",
    output = "README.md:1:TODO",
    truncated = true,
    exit_status = { exitCode = 0, signal = vim.NIL },
  }))
  assert_equal(terminal.kind, "terminal", "terminal context kind")
  assert_equal(terminal.terminal_id, "lazyagent-term-4", "terminal context identity")
  assert(terminal.content:match("%$ rg TODO %."), "terminal command content")
  assert(terminal.content:match("earlier terminal output truncated"), "terminal truncation content")
  assert(terminal.content:match("exit code: 0"), "terminal status content")
  assert_equal(ContextItem.lower(terminal, {}).type, "text", "terminal text lowering")

  local url = assert(ContextItem.url("https://example.com/reference?q=acp"))
  assert_equal(url.kind, "url", "URL context kind")
  assert_equal(url.source_version.uri, url.uri, "URL source version")
  local url_block = ContextItem.lower(url, {})
  assert_equal(url_block.type, "resource_link", "URL resource link lowering")
  assert_equal(url_block.uri, "https://example.com/reference?q=acp", "URL resource link URI")
  local invalid_url, invalid_url_err = ContextItem.url("file:///etc/passwd")
  assert_equal(invalid_url, nil, "non-HTTP URL rejection")
  assert(invalid_url_err:match("http or https"), "non-HTTP URL reason")

  local media_path = vim.fn.tempname() .. ".png"
  vim.fn.writefile({ "image fixture" }, media_path, "b")
  local media = assert(ContextItem.media({ path = media_path }))
  assert_equal(media.kind, "image", "media context kind")
  assert_equal(assert(ContextItem.lower(media, { image = true })).type, "image", "image capability lowering")
  local unsupported = ContextItem.lower(media, {})
  assert_equal(unsupported.type, "text", "unsupported image text lowering")
  assert(unsupported.text:match("does not support image"), "unsupported image reason")
  vim.fn.delete(media_path)

  local binary_path = vim.fn.tempname() .. ".pdf"
  local binary_file = assert(io.open(binary_path, "wb"))
  binary_file:write("%PDF\0fixture")
  binary_file:close()
  local binary = assert(ContextItem.binary_file({ path = binary_path, display = "manual.pdf" }))
  assert_equal(binary.kind, "binary_resource", "binary context kind")
  local linked_binary = assert(ContextItem.lower(binary, {}))
  assert_equal(linked_binary.type, "resource_link", "binary resource link lowering")
  assert_equal(linked_binary.title, "manual.pdf", "binary resource title")
  local embedded_binary = assert(ContextItem.lower(binary, { embedded_context = true }))
  assert_equal(embedded_binary.type, "resource", "binary embedded lowering")
  assert_equal(embedded_binary.resource.mimeType, "application/pdf", "binary embedded MIME")
  vim.fn.delete(binary_path)
end

return M

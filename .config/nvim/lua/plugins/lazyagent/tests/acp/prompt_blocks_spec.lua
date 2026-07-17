local M = {}

local function assert_equal(expected, actual, label)
  if not vim.deep_equal(expected, actual) then
    error(string.format("%s: expected %s, got %s", label, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local function build_actions()
  return require("lazyagent.acp.backend.actions").setup({
    state = {},
    read_path_lines = function(path)
      local ok, lines = pcall(vim.fn.readfile, path)
      return ok and lines or nil
    end,
  })
end

function M.run()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  local image_path = root .. "/pasted.png"
  local bytes = "\137PNG\r\n\026\ncomposer fixture"
  local file = assert(io.open(image_path, "wb"))
  file:write(bytes)
  file:close()

  local actions = build_actions()
  local supported = actions.build_prompt_blocks({
    root_dir = root,
    cwd = root,
    prompt_supports_image = true,
  }, "inspect @pasted.png please")

  assert_equal(3, #supported, "supported prompt block count")
  assert_equal({ type = "text", text = "inspect " }, supported[1], "leading prompt text")
  assert_equal("image", supported[2].type, "pasted image ACP block type")
  assert_equal("image/png", supported[2].mimeType, "pasted image MIME")
  assert_equal(bytes, vim.base64.decode(supported[2].data), "pasted image payload")
  assert_equal(vim.uri_from_fname(image_path), supported[2].uri, "pasted image source URI")
  assert_equal({ type = "text", text = "\n\nplease" }, supported[3], "trailing prompt text")

  local unsupported = actions.build_prompt_blocks({
    root_dir = root,
    cwd = root,
    prompt_supports_image = false,
  }, "@pasted.png")
  assert_equal(1, #unsupported, "unsupported prompt block count")
  assert_equal("text", unsupported[1].type, "unsupported image fallback type")
  assert(unsupported[1].text:match("does not support image"), "unsupported image reason")
  assert(not unsupported[1].data, "unsupported image payload must not be sent")

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, root .. "/source.lua")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local unused = true" })
  local namespace = vim.api.nvim_create_namespace("lazyagent-prompt-blocks-test")
  vim.diagnostic.set(namespace, bufnr, {
    { lnum = 0, col = 6, severity = vim.diagnostic.severity.ERROR, message = "fixture error" },
  })
  local diagnostic_blocks = actions.build_prompt_blocks({
    root_dir = root,
    cwd = root,
    agent_cfg = { source_bufnr = bufnr },
  }, "fix @diagnostics")
  assert_equal(2, #diagnostic_blocks, "diagnostics prompt block count")
  assert_equal("text", diagnostic_blocks[2].type, "diagnostics prompt block type")
  assert(diagnostic_blocks[2].text:match("source.lua:1:7: ERROR: fixture error"), "diagnostics prompt content")
  vim.diagnostic.reset(namespace, bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  local url_blocks = actions.build_prompt_blocks({ root_dir = root, cwd = root }, "read @https://example.com/acp")
  assert_equal(2, #url_blocks, "URL prompt block count")
  assert_equal("resource_link", url_blocks[2].type, "URL prompt resource link")
  assert_equal("https://example.com/acp", url_blocks[2].uri, "URL prompt URI")

  local note_path = root .. "/note.lua"
  vim.fn.writefile({ "return true" }, note_path)
  local hidden_note = actions.build_prompt_blocks({ root_dir = root, cwd = root }, "@note.lua:1")
  assert_equal(1, #hidden_note, "context note hidden by default")
  assert_equal({ type = "text", text = "return true" }, hidden_note[1], "hidden note keeps context body")
  local visible_note = actions.build_prompt_blocks({
    root_dir = root,
    cwd = root,
    show_context_notes = true,
  }, "@note.lua:1")
  assert_equal(2, #visible_note, "context note opt-in block count")
  assert_equal("Context from note.lua line 1:", visible_note[1].text, "context note opt-in text")
  assert_equal(hidden_note[1], visible_note[2], "visible note keeps the same context body")

  local pdf_path = root .. "/manual.pdf"
  local pdf_file = assert(io.open(pdf_path, "wb"))
  pdf_file:write("%PDF-1.7\0prompt fixture")
  pdf_file:close()
  local linked_resource = actions.build_prompt_blocks({
    root_dir = root, cwd = root, prompt_supports_embedded_context = false,
  }, "inspect @manual.pdf")
  assert_equal("resource_link", linked_resource[2].type, "binary prompt resource link")
  assert_equal("application/pdf", linked_resource[2].mimeType, "binary prompt resource MIME")
  local embedded_resource = actions.build_prompt_blocks({
    root_dir = root, cwd = root, prompt_supports_embedded_context = true,
  }, "inspect @manual.pdf")
  assert_equal("resource", embedded_resource[2].type, "binary prompt embedded resource")
  assert_equal("%PDF-1.7\0prompt fixture", vim.base64.decode(embedded_resource[2].resource.blob),
    "binary prompt embedded bytes")

  vim.fn.delete(root, "rf")
end

return M

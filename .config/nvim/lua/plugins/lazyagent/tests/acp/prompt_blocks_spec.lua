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

  vim.fn.delete(root, "rf")
end

return M

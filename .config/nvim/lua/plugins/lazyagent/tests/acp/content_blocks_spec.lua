local M = {}

local function assert_equal(expected, actual, label)
  if not vim.deep_equal(expected, actual) then
    error(string.format("%s: expected %s, got %s", label, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local function assert_truthy(value, label)
  if not value then error(label or "expected truthy value", 2) end
end

function M.run()
  local Content = require("lazyagent.acp.content_blocks")
  local base = vim.fn.tempname()
  vim.fn.mkdir(base, "p")
  local image_path = base .. "/pixel.png"
  local bytes = "\137PNG\r\n\026\nfixture"
  local file = assert(io.open(image_path, "wb"))
  file:write(bytes)
  file:close()

  local image, err = Content.from_file(image_path, { image = true })
  assert_truthy(image, "image block: " .. tostring(err))
  assert_equal("image", image.type, "image type")
  assert_equal("image/png", image.mimeType, "image MIME")
  assert_equal(bytes, vim.base64.decode(image.data), "image data")
  assert_truthy(Content.render(image):match("%[image%].*image/png"), "image metadata render")
  assert_truthy(not Content.render(image):find(image.data, 1, true), "base64 hidden from render")

  local omitted = Content.from_file(image_path, { image = false })
  assert_equal("text", omitted.type, "unsupported image lowered to text")
  assert_truthy(not omitted.data, "unsupported image data omitted")

  local audio_path = base .. "/sample.wav"
  local audio_file = assert(io.open(audio_path, "wb"))
  audio_file:write("RIFFfixtureWAVE")
  audio_file:close()
  local audio = assert(Content.from_file(audio_path, { audio = true }))
  assert_equal("audio", audio.type, "audio type")
  assert_equal("audio/wav", audio.mimeType, "audio MIME")
  assert_truthy(Content.render({
    type = "resource",
    resource = { uri = "file:///blob", mimeType = "application/pdf", blob = "YWJj" },
  }):match("3 bytes"), "blob resource metadata")

  vim.fn.delete(base, "rf")
end

return M

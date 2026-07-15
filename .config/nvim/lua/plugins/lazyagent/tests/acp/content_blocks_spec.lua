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
  local output_cache = base .. "/output-cache"
  local rendered_image = Content.render(image, { cache_dir = output_cache })
  assert_truthy(rendered_image:match("%[image%] @.*%.png.*image/png"), "image preview reference render")
  assert_truthy(not rendered_image:find(image.data, 1, true), "base64 hidden from render")
  local materialized_image = assert(Content.materialize(image, { cache_dir = output_cache }))
  assert_equal(bytes, table.concat(vim.fn.readfile(materialized_image, "b"), "\n"), "materialized image bytes")

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
  local materialized_audio = assert(Content.materialize(audio, { cache_dir = output_cache }))
  assert_equal("RIFFfixtureWAVE", table.concat(vim.fn.readfile(materialized_audio, "b"), "\n"),
    "materialized audio bytes")
  local resource = {
    type = "resource",
    resource = { uri = "file:///blob", mimeType = "application/pdf", blob = "YWJj" },
  }
  local rendered_resource = Content.render(resource, { cache_dir = output_cache })
  assert_truthy(rendered_resource:match("output%-cache/.*%.pdf.*3 bytes"), "blob resource cache reference")
  assert_equal("abc", table.concat(vim.fn.readfile(assert(Content.materialize(resource, {
    cache_dir = output_cache,
  })), "b"), "\n"), "materialized resource bytes")

  local pdf_path = base .. "/fixture.pdf"
  local pdf_bytes = "%PDF-1.7\0binary"
  local pdf_file = assert(io.open(pdf_path, "wb"))
  pdf_file:write(pdf_bytes)
  pdf_file:close()
  assert_equal(true, Content.is_binary_resource(pdf_path), "binary resource detection")
  local linked_pdf = assert(Content.resource_from_file(pdf_path, { embedded_context = false }, {
    title = "Fixture PDF",
    description = "binary context",
    annotations = { audience = { "assistant" }, priority = 0.8 },
  }))
  assert_equal("resource_link", linked_pdf.type, "resource link input")
  assert_equal("application/pdf", linked_pdf.mimeType, "resource link MIME")
  assert_equal(#pdf_bytes, linked_pdf.size, "resource link size")
  assert_equal(0.8, linked_pdf.annotations.priority, "resource link annotations")
  local rendered_link = Content.render(linked_pdf)
  assert(rendered_link:match("Fixture PDF") and rendered_link:match("binary context"), "resource link metadata render")
  local embedded_pdf = assert(Content.resource_from_file(pdf_path, { embedded_context = true }))
  assert_equal("resource", embedded_pdf.type, "embedded blob input")
  assert_equal(pdf_bytes, vim.base64.decode(embedded_pdf.resource.blob), "embedded blob bytes")

  local too_small, size_err = Content.resource_from_file(pdf_path, { embedded_context = true }, { max_bytes = 4 })
  assert_equal(nil, too_small, "oversize embedded resource")
  assert(size_err:match("byte limit"), "oversize embedded resource reason")
  local invalid, invalid_err = Content.materialize({
    type = "image", mimeType = "image/png", data = "not!base64",
  }, { cache_dir = output_cache })
  assert_equal(nil, invalid, "invalid output base64")
  assert(invalid_err:match("invalid base64"), "invalid output base64 reason")

  vim.fn.delete(base, "rf")
end

return M

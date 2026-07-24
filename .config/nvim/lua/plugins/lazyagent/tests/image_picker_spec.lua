local M = {}

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function choose_action(expected_id)
  return function(items, opts, done)
    assert(opts.prompt:find("ACP image input supported", 1, true), "picker prompt exposes image capability")
    for _, item in ipairs(items) do
      if item.id == expected_id then
        done(item)
        return
      end
    end
    error("missing image action: " .. expected_id)
  end
end

function M.run()
  local image_picker = require("lazyagent.logic.image_picker")
  local attached_file
  local completed
  local picker = image_picker.new({
    capability = function()
      return { status = "supported", label = "ACP image input supported" }
    end,
    attach_file = function(bufnr, path, opts)
      attached_file = { bufnr = bufnr, path = path, source = opts.source }
      return "/stored/image.png"
    end,
  })

  picker.open(12, {
    select = choose_action("file"),
    pick_file = function(done)
      done("/chosen/image.png")
    end,
    on_done = function(result)
      completed = result
    end,
  })
  assert_equal(attached_file, {
    bufnr = 12,
    path = "/chosen/image.png",
    source = "file",
  }, "file picker attachment")
  assert_equal(completed, "/stored/image.png", "file picker completion")

  local attached_url
  completed = nil
  picker = image_picker.new({
    capability = function()
      return { status = "supported", label = "ACP image input supported" }
    end,
    attach_url = function(bufnr, url)
      attached_url = { bufnr = bufnr, url = url }
      return "/stored/url.png"
    end,
  })
  picker.open(13, {
    select = choose_action("url"),
    input = function(_, done)
      done("https://example.test/image.png")
    end,
    on_done = function(result)
      completed = result
    end,
  })
  assert_equal(attached_url, {
    bufnr = 13,
    url = "https://example.test/image.png",
  }, "URL picker attachment")
  assert_equal(completed, "/stored/url.png", "URL picker completion")

  local select_count = 0
  attached_file = nil
  completed = nil
  picker = image_picker.new({
    capability = function()
      return { status = "supported", label = "ACP image input supported" }
    end,
    recent_images = function()
      return {
        { path = "/recent/one.png", mtime = 2 },
        { path = "/recent/two.png", mtime = 1 },
      }
    end,
    attach_file = function(bufnr, path, opts)
      attached_file = { bufnr = bufnr, path = path, source = opts.source }
      return "/stored/recent.png"
    end,
  })
  picker.open(14, {
    select = function(items, opts, done)
      select_count = select_count + 1
      if select_count == 1 then
        choose_action("recent")(items, opts, done)
      else
        assert_equal(opts.prompt, "Recent LazyAgent image:", "recent picker prompt")
        done(items[1])
      end
    end,
    on_done = function(result)
      completed = result
    end,
  })
  assert_equal(attached_file, {
    bufnr = 14,
    path = "/recent/one.png",
    source = "recent image",
  }, "recent image attachment")
  assert_equal(completed, "/stored/recent.png", "recent picker completion")
end

return M

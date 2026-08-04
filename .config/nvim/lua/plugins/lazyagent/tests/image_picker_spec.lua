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

  local fzf_file_opts
  local fzf_file_entries
  local scheduled_attach
  local picker_root = vim.fn.tempname()
  vim.fn.mkdir(picker_root .. "/nested", "p")
  picker_root = vim.fn.fnamemodify(picker_root, ":p"):gsub("/+$", "")
  vim.fn.writefile({ "old" }, picker_root .. "/old.png")
  vim.fn.writefile({ "new" }, picker_root .. "/nested/new.jpg")
  vim.fn.writefile({ "ignored" }, picker_root .. "/newer.txt")
  local uv = vim.uv or vim.loop
  uv.fs_utime(picker_root .. "/old.png", 100, 100)
  uv.fs_utime(picker_root .. "/nested/new.jpg", 200, 200)
  uv.fs_utime(picker_root .. "/newer.txt", 300, 300)
  attached_file = nil
  completed = nil
  picker = image_picker.new({
    capability = function()
      return { status = "supported", label = "ACP image input supported" }
    end,
    file_cwd = function()
      return picker_root
    end,
    winopts = function()
      return {
        split = false,
        border = "single",
        height = 0.6,
        width = 0.6,
        preview = { border = "single" },
      }
    end,
    load_fzf = function()
      return {
        fzf_exec = function(entries, opts)
          fzf_file_entries = entries
          fzf_file_opts = opts
          opts.actions.enter({ entries[1] }, { cwd = opts.cwd })
        end,
      }
    end,
    schedule = function(callback)
      scheduled_attach = callback
    end,
    entry_to_file = function(entry, opts)
      return { path = opts.cwd .. "/" .. entry }
    end,
    attach_file = function(bufnr, path, opts)
      attached_file = { bufnr = bufnr, path = path, source = opts.source }
      return "/stored/fzf.png"
    end,
  })
  picker.open(15, {
    select = choose_action("file"),
    on_done = function(result)
      completed = result
    end,
  })
  assert_equal(fzf_file_opts.cwd, picker_root, "fzf image picker cwd")
  assert_equal(fzf_file_entries, { "nested/new.jpg", "old.png" }, "fzf images sorted by newest modification")
  assert_equal(fzf_file_opts.previewer, "builtin", "fzf image picker enables image preview")
  assert_equal(fzf_file_opts.fzf_opts["--no-sort"], true, "fzf preserves modification order while filtering")
  assert_equal(fzf_file_opts.winopts.split, false, "fzf image picker stays floating")
  assert_equal(fzf_file_opts.winopts.border, "single", "fzf image picker uses the configured border")
  assert_equal(fzf_file_opts.winopts.preview.border, "single", "fzf image preview uses the configured border")
  assert_equal(fzf_file_opts.winopts.preview.hidden, false, "fzf image preview is visible")
  assert_equal(attached_file, nil, "fzf attachment waits for picker cleanup")
  scheduled_attach()
  assert_equal(attached_file, {
    bufnr = 15,
    path = picker_root .. "/nested/new.jpg",
    source = "file",
  }, "fzf file picker attachment")
  assert_equal(completed, "/stored/fzf.png", "fzf file picker completion")
  vim.fn.delete(picker_root, "rf")

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

  local recent_entries
  local recent_fzf_opts
  select_count = 0
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
    winopts = function()
      return {
        split = false,
        border = "single",
        preview = { border = "single" },
      }
    end,
    load_fzf = function()
      return {
        fzf_exec = function(entries, opts)
          recent_entries = entries
          recent_fzf_opts = opts
          opts.actions.enter({ entries[2] }, {})
        end,
      }
    end,
    schedule = function(callback)
      callback()
    end,
    entry_to_file = function(entry)
      return { path = entry }
    end,
    attach_file = function(bufnr, path, opts)
      attached_file = { bufnr = bufnr, path = path, source = opts.source }
      return "/stored/recent-fzf.png"
    end,
  })
  picker.open(16, {
    select = choose_action("recent"),
    on_done = function(result)
      completed = result
    end,
  })
  assert_equal(recent_entries, { "/recent/one.png", "/recent/two.png" }, "recent fzf entries")
  assert_equal(recent_fzf_opts.previewer, "builtin", "recent picker enables image preview")
  assert_equal(recent_fzf_opts.fzf_opts["--no-sort"], true, "recent picker preserves modification order")
  assert_equal(recent_fzf_opts.winopts.split, false, "recent picker stays floating")
  assert_equal(recent_fzf_opts.winopts.border, "single", "recent picker uses the configured border")
  assert_equal(attached_file, {
    bufnr = 16,
    path = "/recent/two.png",
    source = "recent image",
  }, "recent fzf image attachment")
  assert_equal(completed, "/stored/recent-fzf.png", "recent fzf picker completion")
end

return M

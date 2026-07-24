local M = {}

local IMAGE_EXTENSIONS = { "png", "jpg", "jpeg", "webp", "gif", "bmp", "tif", "tiff", "svg" }

local ACTIONS = {
  { id = "clipboard", label = "Clipboard", detail = "Paste image data from the clipboard" },
  { id = "screenshot", label = "Screenshot", detail = "Capture a screen region" },
  { id = "file", label = "File", detail = "Choose an image file" },
  { id = "url", label = "URL", detail = "Download an image URL" },
  { id = "recent", label = "Recent", detail = "Reuse a recent LazyAgent image" },
}

local function action_label(item)
  return string.format("%-10s %s", item.label, item.detail)
end

local function absolute_path(path)
  path = tostring(path or "")
  if path == "" then
    return nil
  end
  return vim.fn.fnamemodify(path, ":p")
end

function M.new(ctx)
  ctx = ctx or {}
  local picker = {}

  local function input_file(input, done)
    input({
      prompt = "Image file: ",
      completion = "file",
    }, function(path)
      done(absolute_path(path))
    end)
  end

  local function snacks_file_picker(input, done)
    local snacks = type(ctx.load_snacks) == "function" and ctx.load_snacks() or nil
    if not (snacks and snacks.picker and type(snacks.picker.files) == "function") then
      input_file(input, done)
      return
    end

    local completed = false
    local function complete(path)
      if completed then
        return
      end
      completed = true
      done(absolute_path(path))
    end

    local ok = pcall(snacks.picker.files, {
      title = "LazyAgent Image",
      cwd = vim.fn.getcwd(),
      ft = IMAGE_EXTENSIONS,
      confirm = function(snacks_picker, item)
        completed = true
        snacks_picker:close()
        local path = item and (item.file or item.text) or nil
        vim.schedule(function()
          done(absolute_path(path))
        end)
      end,
      on_close = function()
        if not completed then
          vim.schedule(function()
            complete(nil)
          end)
        end
      end,
    })
    if not ok then
      input_file(input, done)
    end
  end

  local function recent_picker(bufnr, select, done)
    local items = type(ctx.recent_images) == "function" and ctx.recent_images(bufnr) or {}
    if type(items) ~= "table" or #items == 0 then
      if type(ctx.notify) == "function" then
        ctx.notify("no recent LazyAgent images", vim.log.levels.INFO)
      end
      done(nil)
      return
    end

    select(items, {
      prompt = "Recent LazyAgent image:",
      format_item = function(item)
        local path = type(item) == "table" and item.path or item
        return vim.fn.fnamemodify(tostring(path or ""), ":~:.")
      end,
    }, function(item)
      local path = type(item) == "table" and item.path or item
      if not item then
        path = nil
      end
      if path and type(ctx.attach_file) == "function" then
        done(ctx.attach_file(bufnr, path, { source = "recent image" }))
      else
        done(nil)
      end
    end)
  end

  function picker.open(bufnr, opts)
    opts = opts or {}
    local select = opts.select or ctx.select or vim.ui.select
    local input = opts.input or ctx.input or vim.ui.input
    local pick_file = opts.pick_file or ctx.pick_file
    local on_done = opts.on_done
    local finished = false

    local function done(result)
      if finished then
        return
      end
      finished = true
      if type(on_done) == "function" then
        pcall(on_done, result)
      end
    end

    local capability = type(ctx.capability) == "function" and ctx.capability(bufnr) or {}
    local capability_label = capability.label or "image capability unknown"
    select(ACTIONS, {
      prompt = "Attach image · " .. capability_label .. ":",
      format_item = action_label,
    }, function(action)
      if not action then
        done(nil)
        return
      end

      if action.id == "clipboard" then
        done(type(ctx.attach_clipboard) == "function" and ctx.attach_clipboard(bufnr) or nil)
      elseif action.id == "screenshot" then
        done(type(ctx.attach_screenshot) == "function" and ctx.attach_screenshot(bufnr) or nil)
      elseif action.id == "file" then
        local choose = pick_file or function(callback)
          snacks_file_picker(input, callback)
        end
        choose(function(path)
          if path and type(ctx.attach_file) == "function" then
            done(ctx.attach_file(bufnr, path, { source = "file" }))
          else
            done(nil)
          end
        end)
      elseif action.id == "url" then
        input({ prompt = "Image URL: " }, function(url)
          if url and url ~= "" and type(ctx.attach_url) == "function" then
            done(ctx.attach_url(bufnr, url))
          else
            done(nil)
          end
        end)
      elseif action.id == "recent" then
        recent_picker(bufnr, select, done)
      else
        done(nil)
      end
    end)

    return true
  end

  return picker
end

return M

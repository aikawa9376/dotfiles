local M = {}
local uv = vim.uv or vim.loop

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

local function image_files_by_mtime(root)
  local files = {}

  local function scan(dir)
    local handle = uv and uv.fs_scandir(dir) or nil
    if not handle then
      return
    end
    while true do
      local name, kind = uv.fs_scandir_next(handle)
      if not name then
        break
      end
      local path = vim.fs.joinpath(dir, name)
      if kind == "directory" and name ~= ".git" then
        scan(path)
      elseif kind == "file" then
        local extension = name:match("%.([^./]+)$")
        if extension and vim.tbl_contains(IMAGE_EXTENSIONS, extension:lower()) then
          local stat = uv.fs_stat(path)
          local modified = stat and stat.mtime or nil
          files[#files + 1] = {
            path = path,
            mtime = type(modified) == "table" and tonumber(modified.sec) or tonumber(modified) or 0,
          }
        end
      end
    end
  end

  scan(root)
  table.sort(files, function(a, b)
    if a.mtime == b.mtime then
      return a.path < b.path
    end
    return a.mtime > b.mtime
  end)
  return vim.tbl_map(function(file)
    return file.path:sub(#root + 2)
  end, files)
end

function M.new(ctx)
  ctx = ctx or {}
  local picker = {}

  local function image_winopts()
    local configured = type(ctx.winopts) == "function" and ctx.winopts() or ctx.winopts
    local base = type(configured) == "table" and configured or { split = false }
    return vim.tbl_deep_extend("force", {}, base, {
      preview = { hidden = false },
    })
  end

  local function file_cwd()
    local configured = type(ctx.file_cwd) == "function" and ctx.file_cwd() or ctx.file_cwd
    local cwd = configured and vim.fn.expand(tostring(configured)) or vim.fn.getcwd()
    if vim.fn.isdirectory(cwd) ~= 1 then
      cwd = vim.fn.getcwd()
    end
    return vim.fn.fnamemodify(cwd, ":p"):gsub("/+$", "")
  end

  local function input_file(input, done, cwd)
    input({
      prompt = "Image file: ",
      completion = "file",
      default = cwd and (cwd .. "/") or nil,
    }, function(path)
      done(absolute_path(path))
    end)
  end

  local function selected_fzf_path(selected, opts)
    if type(selected) ~= "table" or not selected[1] then
      return nil
    end
    local entry_to_file = ctx.entry_to_file
    if type(entry_to_file) ~= "function" then
      local ok, path = pcall(require, "fzf-lua.path")
      entry_to_file = ok and path.entry_to_file or nil
    end
    local entry = type(entry_to_file) == "function" and entry_to_file(selected[1], opts) or nil
    local path = type(entry) == "table" and (entry.path or entry.filename) or selected[1]
    return absolute_path(path)
  end

  local function fzf_actions(done)
    local completed = false
    local function complete(selected, opts)
      if completed then
        return
      end
      completed = true
      local path = selected_fzf_path(selected, opts)
      local schedule = type(ctx.schedule) == "function" and ctx.schedule or vim.schedule
      schedule(function()
        done(path)
      end)
    end
    return {
      ["enter"] = complete,
      ["default"] = complete,
    }
  end

  local function fzf_file_picker(input, done)
    local fzf = type(ctx.load_fzf) == "function" and ctx.load_fzf() or nil
    local cwd = file_cwd()
    if not (fzf and type(fzf.fzf_exec) == "function") then
      input_file(input, done, cwd)
      return
    end

    local paths = type(ctx.image_files) == "function" and ctx.image_files(cwd) or image_files_by_mtime(cwd)
    if #paths == 0 then
      if type(ctx.notify) == "function" then
        ctx.notify("no image files found in " .. cwd, vim.log.levels.INFO)
      end
      done(nil)
      return
    end

    local ok = pcall(fzf.fzf_exec, paths, {
      prompt = "LazyAgent Image > ",
      cwd = cwd,
      file_icons = true,
      git_icons = false,
      previewer = "builtin",
      actions = fzf_actions(done),
      fzf_opts = {
        ["--no-sort"] = true,
      },
      winopts = image_winopts(),
    })
    if not ok then
      input_file(input, done, cwd)
    end
  end

  local function fzf_recent_picker(items, done)
    local fzf = type(ctx.load_fzf) == "function" and ctx.load_fzf() or nil
    if not (fzf and type(fzf.fzf_exec) == "function") then
      return false
    end
    local paths = vim.tbl_map(function(item)
      return type(item) == "table" and item.path or item
    end, items)
    local ok = pcall(fzf.fzf_exec, paths, {
      prompt = "Recent LazyAgent Image > ",
      previewer = "builtin",
      file_icons = true,
      actions = fzf_actions(done),
      fzf_opts = {
        ["--no-sort"] = true,
      },
      winopts = image_winopts(),
    })
    return ok
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

    local function attach(path)
      if path and type(ctx.attach_file) == "function" then
        done(ctx.attach_file(bufnr, path, { source = "recent image" }))
      else
        done(nil)
      end
    end
    if fzf_recent_picker(items, attach) then
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
      attach(path)
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
          fzf_file_picker(input, callback)
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

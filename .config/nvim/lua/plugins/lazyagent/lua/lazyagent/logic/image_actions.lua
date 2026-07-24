local M = {}

local ACTIONS = {
  { id = "preview", label = "Preview", detail = "Show a larger Snacks.image preview" },
  { id = "open", label = "Open", detail = "Open with the system image viewer" },
  { id = "copy", label = "Copy path", detail = "Copy the local path or URL" },
  { id = "remove", label = "Remove", detail = "Remove this image reference from scratch" },
}

local function action_label(item)
  return string.format("%-10s %s", item.label, item.detail)
end

function M.new(ctx)
  ctx = ctx or {}
  local controller = {}

  function controller.open(bufnr, opts)
    opts = opts or {}
    local select = opts.select or ctx.select or vim.ui.select
    local reference = type(ctx.current_image) == "function" and ctx.current_image(bufnr) or nil
    if not reference then
      if type(ctx.notify) == "function" then
        ctx.notify("place the cursor on an image reference", vim.log.levels.INFO)
      end
      if type(opts.on_done) == "function" then
        pcall(opts.on_done, false)
      end
      return false
    end

    select(ACTIONS, {
      prompt = "Image action · " .. tostring(reference.source or "image") .. ":",
      format_item = action_label,
    }, function(action)
      local result = false
      if action and type(ctx[action.id]) == "function" then
        result = ctx[action.id](bufnr, reference) ~= false
      end
      if type(opts.on_done) == "function" then
        pcall(opts.on_done, result)
      end
    end)
    return true
  end

  return controller
end

return M

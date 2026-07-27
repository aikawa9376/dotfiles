local M = {}

local group = vim.api.nvim_create_augroup("ObsidianExtensionProperties", { clear = true })

local function frontmatter_end(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if lines[1] ~= "---" then
    return nil
  end

  for index = 2, #lines do
    if lines[index] == "---" or lines[index] == "..." then
      return index
    end
  end
end

local function configure_window(winid, bufnr)
  if
    not winid
    or not vim.api.nvim_win_is_valid(winid)
    or not bufnr
    or not vim.api.nvim_buf_is_valid(bufnr)
    or vim.api.nvim_win_get_buf(winid) ~= bufnr
    or vim.bo[bufnr].filetype ~= "markdown"
  then
    return
  end

  local finish = frontmatter_end(bufnr)
  vim.api.nvim_win_call(winid, function()
    local applied = vim.w.obsidian_extension_property_fold
    if not finish then
      if type(applied) == "table" and applied.bufnr == bufnr and applied.finish then
        vim.cmd(("silent! 1,%dfolddelete"):format(applied.finish))
        vim.w.obsidian_extension_property_fold = nil
      end
      return
    end

    if type(applied) == "table" and applied.bufnr == bufnr and applied.finish == finish then
      return
    end

    vim.wo.foldmethod = "manual"
    vim.wo.foldenable = true
    vim.wo.foldtext = "v:lua.require'obsidian_extension.features.properties'.foldtext()"
    vim.opt_local.fillchars = vim.tbl_extend("force", vim.opt_local.fillchars:get(), { fold = "─" })

    if type(applied) == "table" and applied.bufnr == bufnr and applied.finish then
      vim.cmd(("silent! 1,%dfolddelete"):format(applied.finish))
    end

    vim.cmd(("silent! 1,%dfold"):format(finish))
    vim.cmd("silent! 1foldclose")
    vim.w.obsidian_extension_property_fold = {
      bufnr = bufnr,
      finish = finish,
    }
  end)
end

local function configure_buffer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    configure_window(winid, bufnr)
  end

  if vim.b[bufnr].obsidian_extension_property_zo then
    return
  end
  vim.b[bufnr].obsidian_extension_property_zo = true

  vim.keymap.set("n", "zo", function()
    local current_buf = vim.api.nvim_get_current_buf()
    local finish = frontmatter_end(current_buf)
    local row = vim.api.nvim_win_get_cursor(0)[1]
    if finish and row <= finish then
      vim.cmd("normal! za")
      return
    end
    vim.cmd("normal! zo")
  end, {
    buffer = bufnr,
    desc = "Toggle properties fold or open regular fold",
    silent = true,
  })
end

function M.foldtext()
  if vim.v.foldstart == 1 and frontmatter_end(vim.api.nvim_get_current_buf()) == vim.v.foldend then
    local fold_char = vim.opt_local.fillchars:get().fold or "-"
    return fold_char .. " property " .. fold_char
  end
  return vim.fn.getline(vim.v.foldstart)
end

function M.filter_render_marks(bufnr, marks)
  local finish = frontmatter_end(bufnr)
  if not finish then
    return marks
  end

  return vim.tbl_filter(function(mark)
    return not (
      mark.conceal == "dash"
      and (mark.start_row == 0 or mark.start_row == finish - 1)
    )
  end, marks)
end

function M.setup()
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(event)
      vim.schedule(function()
        configure_buffer(event.buf)
      end)
    end,
  })

  vim.api.nvim_create_autocmd({ "BufWinEnter", "BufWritePost" }, {
    group = group,
    pattern = "*.md",
    callback = function(event)
      vim.schedule(function()
        configure_buffer(event.buf)
      end)
    end,
  })

  if vim.bo.filetype == "markdown" then
    vim.schedule(function()
      configure_buffer(vim.api.nvim_get_current_buf())
    end)
  end
end

M.frontmatter_end = frontmatter_end
M.configure_buffer = configure_buffer
M.configure_window = configure_window

return M

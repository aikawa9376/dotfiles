local api = vim.api

local M = {}

-- フロートウィンドウのバッファとウィンドウの ID
local preview_buf = nil
local preview_win = nil
local owner_buf = nil
local owner_win = nil
local owner_buf_leave_autocmd = nil
local owner_win_enter_autocmd = nil
local owner_win_closed_autocmd = nil

local prev_row = nil
local preview_group = api.nvim_create_augroup("HarpoonPreviewLifecycle", { clear = false })

local function get_current_file()
    local line = api.nvim_get_current_line()
    local file_path = vim.fn.expand(line)
    local item = vim.split(file_path, ":")
    if vim.fn.filereadable(item[1]) == 0 then
        -- print("ファイルが存在しません: " .. item[1])
        return
    end
    return item
end

local ns_cursor = vim.api.nvim_create_namespace("my_harpoon_preview")

local function highlight_cursor(buf, row)
  vim.api.nvim_buf_clear_namespace(buf, ns_cursor, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, ns_cursor, row, 0, {
    line_hl_group = vim.api.nvim_get_hl_id_by_name("Visual"),
  })
end

local function previewWinMove(win_id, bufnr, direction)
  local pos = vim.api.nvim_win_get_cursor(win_id)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local new_row = pos[1] + (direction and 1 or -1)

  if new_row < 1 or new_row > line_count then return end

  vim.api.nvim_win_set_cursor(win_id, { new_row, pos[2] })
  highlight_cursor(bufnr, new_row - 1)
end

local function clear_owner_autocmds()
  if owner_buf_leave_autocmd then
    pcall(api.nvim_del_autocmd, owner_buf_leave_autocmd)
    owner_buf_leave_autocmd = nil
  end
  if owner_win_enter_autocmd then
    pcall(api.nvim_del_autocmd, owner_win_enter_autocmd)
    owner_win_enter_autocmd = nil
  end
  if owner_win_closed_autocmd then
    pcall(api.nvim_del_autocmd, owner_win_closed_autocmd)
    owner_win_closed_autocmd = nil
  end
  owner_buf = nil
  owner_win = nil
end

local function attach_owner(parent)
  local next_owner_buf = type(parent) == "table" and tonumber(parent.bufnr) or nil
  local next_owner_win = type(parent) == "table" and tonumber(parent.win_id) or nil
  if not next_owner_buf or not next_owner_win then
    clear_owner_autocmds()
    return
  end

  if owner_buf == next_owner_buf and owner_win == next_owner_win then
    return
  end

  clear_owner_autocmds()
  owner_buf = next_owner_buf
  owner_win = next_owner_win

  owner_buf_leave_autocmd = api.nvim_create_autocmd("BufLeave", {
    group = preview_group,
    buffer = owner_buf,
    once = true,
    callback = function()
      M.close()
    end,
  })
  owner_win_enter_autocmd = api.nvim_create_autocmd("WinEnter", {
    group = preview_group,
    callback = function()
      if not owner_win then
        return
      end
      local current_win = api.nvim_get_current_win()
      if current_win ~= owner_win then
        M.close()
      end
    end,
  })
  owner_win_closed_autocmd = api.nvim_create_autocmd("WinClosed", {
    group = preview_group,
    pattern = tostring(owner_win),
    once = true,
    callback = function()
      M.close()
    end,
  })
end

function M.close()
  clear_owner_autocmds()
  if preview_win and api.nvim_win_is_valid(preview_win) then
    pcall(api.nvim_win_close, preview_win, true)
  end
  if preview_buf and api.nvim_buf_is_valid(preview_buf) then
    pcall(api.nvim_buf_delete, preview_buf, { force = true })
  end
  preview_win = nil
  preview_buf = nil
  prev_row = nil
end

-- プレビューを開く関数
function M.open(parent, float_opts)
  float_opts = float_opts or {}
  float_opts = vim.tbl_deep_extend('force', {
    relative = "editor",
    width = math.floor(vim.o.columns * 0.62569),
    height = math.floor(vim.o.lines * 0.62569),
    row = math.floor((vim.o.lines - math.floor(vim.o.lines * 0.62569)) / 2),
    col = math.floor((vim.o.columns - math.floor(vim.o.columns * 0.62569)) / 2),
    style = "minimal",
    focusable = false,
  }, float_opts)

  local item = get_current_file()
  if not item then return end

  attach_owner(parent)

  -- プレビュー用バッファを作成
  if preview_buf == nil or not vim.api.nvim_buf_is_valid(preview_buf) then
    preview_buf = api.nvim_create_buf(false, true)
    vim.bo[preview_buf].bufhidden = "wipe"
    vim.bo[preview_buf].buflisted = false
    vim.bo[preview_buf].swapfile = false
  end
  -- フロートウィンドウを作成
  if preview_win == nil or not vim.api.nvim_win_is_valid(preview_win) then
    preview_win = api.nvim_open_win(preview_buf, false, float_opts)
    vim.api.nvim_set_option_value("number", true, { win = preview_win })
    vim.api.nvim_set_option_value("winhl", "NormalNC:Normal", { win = preview_win })
    vim.api.nvim_set_option_value("scrolloff", 9999, { win = preview_win })
    vim.keymap.set("n", "<M-j>", function() previewWinMove(
      preview_win,
      preview_buf,
      true
    ) end, { buffer = parent.bufnr })
    vim.keymap.set("n", "<M-k>", function() previewWinMove(
      preview_win,
      preview_buf,
      false
    ) end, { buffer = parent.bufnr })
    prev_row = nil
  end

  if prev_row ~= tonumber(item[2]) then
    api.nvim_buf_call(preview_buf, function()
      local lines = vim.fn.readfile(vim.fn.fnameescape(item[1]))
      if type(lines) == "table" then
        -- バッファに内容を設定する（既存の内容を完全に置き換える）
        vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, lines)
      end
      vim.cmd("doautocmd BufRead " .. vim.fn.fnameescape(item[1]))
      pcall(vim.treesitter.start,preview_buf)
    end)

    api.nvim_win_set_cursor(preview_win, { tonumber(item[2]), tonumber(item[3]) })

    -- 該当行をハイライト
    highlight_cursor(preview_buf, tonumber(item[2]) - 1)

    vim.api.nvim_buf_call(preview_buf, function()
      vim.cmd("normal! zz")
    end)

    prev_row = tonumber(item[2])
  end

  return { win_id = preview_win, buf_id = preview_buf, item = item }
end

return setmetatable(M, {
  __call = function(_, ...)
    return M.open(...)
  end,
})

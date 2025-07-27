local api = vim.api

-- フロートウィンドウのバッファとウィンドウの ID
local preview_buf = nil
local preview_win = nil

local prev_row = nil

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

-- プレビューを開く関数
local function open_preview(parent, float_opts)
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

return open_preview

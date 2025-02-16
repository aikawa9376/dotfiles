local api = vim.api

-- フロートウィンドウのバッファとウィンドウの ID
local preview_buf = nil
local preview_win = nil

local function get_current_file()
    local line = api.nvim_get_current_line()
    local file_path = vim.fn.expand(line)
    local item = vim.split(file_path, ":")
    if vim.fn.filereadable(item[1]) == 0 then
        print("ファイルが存在しません: " .. item[1])
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

-- プレビューを開く関数
local function open_preview(float_opts)
  float_opts = float_opts or {}
  float_opts = vim.tbl_deep_extend('force', {
    relative = "editor",
    width = math.floor(vim.o.columns * 0.62569),
    height = math.floor(vim.o.lines * 0.62569),
    row = math.floor((vim.o.lines - math.floor(vim.o.lines * 0.62569)) / 2),
    col = math.floor((vim.o.columns - math.floor(vim.o.columns * 0.62569)) / 2),
    style = "minimal",
    border = "rounded",
    focusable = false,
  }, float_opts)

  local item = get_current_file()
  if not item then return end

  -- 既存のプレビューウィンドウを閉じる
  -- if preview_win and api.nvim_win_is_valid(preview_win) then
  --   api.nvim_win_close(preview_win, true)
  -- end
  -- 既存のプレビューバッファを削除
  -- if preview_buf and api.nvim_buf_is_valid(preview_buf) then
  --   api.nvim_buf_delete(preview_buf, { force = true })
  -- end

  -- プレビュー用バッファを作成
  preview_buf = api.nvim_create_buf(false, true)
  -- フロートウィンドウを作成
  preview_win = api.nvim_open_win(preview_buf, false, float_opts)
  vim.api.nvim_set_option_value("number", true, { win = preview_win })
  vim.api.nvim_set_option_value("winhl", "NormalNC:Normal", { win = preview_win })

  -- バッファの設定を変更
  vim.bo[preview_buf].bufhidden = "wipe"
  vim.bo[preview_buf].buflisted = false
  vim.bo[preview_buf].swapfile = false

  api.nvim_buf_call(preview_buf, function()
    vim.cmd("silent! read " .. vim.fn.fnameescape(item[1]))
    vim.cmd("doautocmd BufRead " .. vim.fn.fnameescape(item[1]))
  end)

  -- TODO: ファイル名のみハイライトしたい

  api.nvim_win_set_cursor(preview_win, { tonumber(item[2]), tonumber(item[3]) })

  -- 該当行をハイライト
  highlight_cursor(preview_buf, tonumber(item[2]))

  vim.api.nvim_buf_call(preview_buf, function()
    vim.cmd("normal! zz")
  end)

  return { win_id = preview_win, buf_id = preview_buf, item = item }
end

return open_preview

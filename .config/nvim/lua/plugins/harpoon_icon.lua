local HarpoonGroup = require("harpoon.autocmd")
local HarpoonIconNS = vim.api.nvim_create_namespace("HarpoonIconNS")

local M = {}

-- デフォルト設定
local default_config = {
  icon = " ",
  nearest_entry = true,
  icon_position = "eol",  -- "eol" または "signcolumn"
}

-- 現在のカーソル位置から最も近いエントリにカーソルを移動する関数
local function move_cursor_to_nearest_entry(cx)
  local prev_buf = vim.fn.bufnr("#")  -- 直前のバッファ番号を取得
  local win_ids = vim.fn.win_findbuf(prev_buf)  -- バッファ番号からウィンドウ番号を取得
  if prev_buf == 0 then
      return
  end

  local current_pos = vim.api.nvim_win_get_cursor(win_ids[1])
  local current_row = current_pos[1]

  local nearest_entry = nil
  local min_distance = math.huge

  for line_number, entry in ipairs(cx.contents) do
    local file, row = entry:match("([^:]+):(%d+):(%d+)")
    if not string.find(cx.current_file, file, 1, true) then
      goto continue
    end

    row = tonumber(row)

    local distance = math.abs(current_row - row)
    if distance < min_distance then
      min_distance = distance
      nearest_entry = line_number
    end

    ::continue::
  end

  if nearest_entry then
    vim.api.nvim_win_set_cursor(cx.win_id, { nearest_entry, 0 })
  end
end

local refilter = function(obj)
  local reindexed_items = {}
  local keys = {}

  for k in pairs(obj.list.items) do
    if type(k) == "number" then
      table.insert(keys, k)
    end
  end
  table.sort(keys)

  for _, k in ipairs(keys) do
    table.insert(reindexed_items, obj.list.items[k])
  end

  obj.list.items = reindexed_items
  obj.list._length = #reindexed_items
end

M.set_buffer_icon = function(config)
  local harpoon = require("harpoon")
  local list = harpoon:list("multiple"):display()

  -- 現在のバッファ名を取得
  local current_bufname = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":.")
  local bufnr = vim.api.nvim_get_current_buf()

  -- 既存のアイコンを削除
  vim.api.nvim_buf_clear_namespace(bufnr, HarpoonIconNS, 0, -1)

  for _, entry in ipairs(list) do
    local file, row, col = entry:match("([^:]+):(%d+):(%d+)")
    row = tonumber(row)
    col = tonumber(col)

    -- バッファ名が一致する場合にのみアイコンを設定
    if current_bufname == file then
      if config.icon_position == "signcolumn" then
        vim.fn.sign_define("HarpoonIcon", { text = config.icon, texthl = "DiagnosticError" })
        vim.fn.sign_place(0, "HarpoonGroup", "HarpoonIcon", bufnr, { lnum = row - 1 })
      else
        -- アイコンを行末に設定
        vim.api.nvim_buf_set_extmark(bufnr, HarpoonIconNS, row - 1, col - 0, {
          virt_text = {{config.icon, "DiagnosticError"}},  -- アイコンとハイライトグループ
          virt_text_pos = config.icon_position,
        })
      end
    end
  end
end

M.set_current_buffer_icon = function(cx, config)
  for line_number, entry in pairs(cx.contents) do
    local file = entry:match("([^:]+):(%d+):(%d+)")
    if string.find(cx.current_file, file, 1, true) then
      -- highlight the harpoon menu line that corresponds to the current buffer
      vim.api.nvim_buf_set_extmark(cx.bufnr, HarpoonIconNS, line_number - 1,  0, {
        virt_text = {{config.icon, "DiagnosticError"}},  -- アイコンとハイライトグループ
        virt_text_pos = "eol",  -- 行末にアイコンを配置
      })
    end
  end
  if config.nearest_entry then
    move_cursor_to_nearest_entry(cx)
  end
end

M.setup = function(user_config)
  local harpoon = require("harpoon")

  -- ユーザー設定をデフォルト設定とマージ
  local config = vim.tbl_deep_extend("force", default_config, user_config or {})

  vim.api.nvim_create_autocmd("BufEnter", {
    group = HarpoonGroup,
    callback = function()
      M.set_buffer_icon(config)
    end,
  })

  harpoon:extend({
    ADD = function(_)
      M.set_buffer_icon(config)
    end,
    REMOVE = function(obj)
      M.set_buffer_icon(config)
      refilter(obj)
    end,
    UI_CREATE = function(obj)
      M.set_current_buffer_icon(obj, config)
    end
  })

  M.set_buffer_icon(config)
end

return M

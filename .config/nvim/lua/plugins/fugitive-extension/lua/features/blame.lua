local M = {}

local function setup_blame_gradients()
  local colors = {
    { name = 'FugitiveBlameDate0', fg = '#50c878' }, -- 緑（最新）より明るく
    { name = 'FugitiveBlameDate1', fg = '#70cd80' },
    { name = 'FugitiveBlameDate2', fg = '#90d288' },
    { name = 'FugitiveBlameDate3', fg = '#b0d790' },
    { name = 'FugitiveBlameDate4', fg = '#d0dc98' },
    { name = 'FugitiveBlameDate5', fg = '#f0e1a0' },
    { name = 'FugitiveBlameDate6', fg = '#ffc580' },
    { name = 'FugitiveBlameDate7', fg = '#ffb060' },
    { name = 'FugitiveBlameDate8', fg = '#ff9b40' },
    { name = 'FugitiveBlameDate9', fg = '#ff8620' },
    { name = 'FugitiveBlameDate10', fg = '#ff7100' },
    { name = 'FugitiveBlameDate11', fg = '#e85040' },
    { name = 'FugitiveBlameDate12', fg = '#d03030' }, -- 赤（古い）より濃く
  }
  for _, color in ipairs(colors) do
    vim.api.nvim_set_hl(0, color.name, { fg = color.fg })
  end
end

local function apply_blame_gradient(bufnr)
  local ns_id = vim.api.nvim_create_namespace('fugitive_blame_gradient')
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  if vim.g.fugitive_blame_gradient_mode == 'absolute' then
    -- 絶対モード: 現在の日付から何ヶ月前かで判定
    local now = os.time()

    for idx, line in ipairs(lines) do
      local date_start, date_end = line:find('%d%d%d%d%-%d%d%-%d%d %d%d:%d%d')
      if date_start then
        local y, m, d, h, min = line:match('(%d%d%d%d)%-(%d%d)%-(%d%d) (%d%d):(%d%d)')
        if y then
          local commit_time = os.time({
            year = tonumber(y) or 0,
            month = tonumber(m) or 1,
            day = tonumber(d) or 1,
            hour = tonumber(h) or 0,
            min = tonumber(min) or 0,
          })
          local diff_months = math.floor((now - commit_time) / (30 * 24 * 60 * 60))

          -- 2ヶ月ごとに色を変える（0-24ヶ月を13段階に）
          local color_idx = math.min(math.floor(diff_months / 2), 12)

          vim.api.nvim_buf_set_extmark(bufnr, ns_id, idx - 1, date_start - 1, {
            end_col = date_end,
            hl_group = 'FugitiveBlameDate' .. color_idx,
          })
        end
      end
    end
  else
    -- 相対モード: ファイル内の最古と最新の日付を基準に
    local dates = {}

    for _, line in ipairs(lines) do
      local date = line:match('%d%d%d%d%-%d%d%-%d%d')
      if date then
        table.insert(dates, date)
      end
    end

    table.sort(dates)
    local oldest_date = dates[1]
    local newest_date = dates[#dates]

    if oldest_date and newest_date then
      local function date_to_days(date_str)
        local y, m, d = date_str:match('(%d%d%d%d)%-(%d%d)%-(%d%d)')
        return tonumber(y) * 365 + tonumber(m) * 30 + tonumber(d)
      end

      local oldest_days = date_to_days(oldest_date)
      local newest_days = date_to_days(newest_date)
      local range = newest_days - oldest_days

      for idx, line in ipairs(lines) do
        local date_start, date_end = line:find('%d%d%d%d%-%d%d%-%d%d %d%d:%d%d')
        if date_start then
          local date = line:match('%d%d%d%d%-%d%d%-%d%d')
          local days = date_to_days(date)

          local color_idx
          if range == 0 then
            color_idx = 0
          else
            local ratio = (days - oldest_days) / range
            color_idx = math.floor((1 - ratio) * 12)
          end

          vim.api.nvim_buf_set_extmark(bufnr, ns_id, idx - 1, date_start - 1, {
            end_col = date_end,
            hl_group = 'FugitiveBlameDate' .. color_idx,
          })
        end
      end
    end
  end
end

function M.setup(group)
  setup_blame_gradients()

  -- グラデーションモード: 'absolute' または 'relative'
  vim.g.fugitive_blame_gradient_mode = vim.g.fugitive_blame_gradient_mode or 'absolute'

  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'fugitiveblame',
    callback = function(ev)
      apply_blame_gradient(ev.buf)

      vim.keymap.set('n', 'c', function()
        vim.g.fugitive_blame_gradient_mode = vim.g.fugitive_blame_gradient_mode == 'absolute' and 'relative' or 'absolute'
        apply_blame_gradient(ev.buf)
        print('Blame gradient mode: ' .. vim.g.fugitive_blame_gradient_mode)
      end, { buffer = ev.buf, nowait = true, silent = true })

      vim.keymap.set('n', 'd', function()
        local commit = vim.api.nvim_get_current_line():match('^(%x+)')
        if not commit then
          return
        end

        vim.cmd.wincmd('p')
        local file_path = vim.fn.expand('%:.'):match('//[%x]+/(.+)$') or vim.fn.expand('%:.')
        local line_num = vim.api.nvim_win_get_cursor(0)[1]
        local target_line = vim.api.nvim_buf_get_lines(0, line_num - 1, line_num, false)[1]
        vim.cmd.wincmd('p')

        local rev = commit:match('^0+$') and ':' or commit .. '^:'
        local fugitive_path = vim.fn.FugitiveFind(rev .. file_path)
        local existing_buf = vim.fn.bufnr(fugitive_path)

        vim.cmd(existing_buf ~= -1 and 'tabedit #' .. existing_buf or 'tabedit ' .. fugitive_path)
        vim.cmd(commit:match('^0+$') and 'Gvdiffsplit' or 'Gvdiffsplit ' .. commit)

        local found_line = 1
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        for i, line in ipairs(lines) do
          if line == target_line then
            found_line = i
            break
          end
        end
        vim.cmd.normal({ found_line .. 'Gzz', bang = true })
      end, { buffer = ev.buf, nowait = true, silent = true })
    end,
  })
end

return M

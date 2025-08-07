return {
  "rmagatti/goto-preview",
  keys = {
    ---@diagnostic disable-next-line: missing-parameter
    { "<space><space>", function () require('goto-preview').goto_preview_definition() end }
  },
  opts = {
    default_mappings = false,
    height = 20,
    references = {
      provider = "snacks",
    },
    post_open_hook = function(bufnr, winid)
      local function open_preview_in_buffer()
        local filepath = vim.fn.expand("%:p")
        local line_num = vim.fn.line(".")
        local col_num = vim.fn.col(".")

        require("goto-preview").close_all_win()

        vim.cmd("edit " .. filepath)
        vim.api.nvim_win_set_cursor(0, {line_num, col_num - 1})
        vim.cmd("normal! zz") -- 画面中央にスクロール
      end

      vim.keymap.set('n', 'q', function()
        require("goto-preview").close_all_win()
      end, { buffer = bufnr, silent = true, nowait = true, desc = "Close preview" })

      vim.keymap.set('n', '<Esc>', function()
        require("goto-preview").close_all_win()
      end, { buffer = bufnr, silent = true, nowait = true, desc = "Close preview" })

      vim.keymap.set('n', '<CR>', function()
        open_preview_in_buffer()
      end, { buffer = bufnr, silent = true, nowait = true, desc = "Open in buffer" })
    end,
  }
}

return {
  "rmagatti/goto-preview",
  keys = {
    { "<space><space>", function () require('goto-preview').goto_preview_definition({}) end }
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
        vim.api.nvim_set_option_value('number', true, { scope = 'local' })
        vim.api.nvim_win_set_cursor(0, { line_num, col_num - 1 })
        vim.cmd("normal! zz")
      end

      local function get_parent_relative_path(cWinId)
        cWinId = cWinId or vim.api.nvim_get_current_win()
        local cfg = vim.api.nvim_win_get_config(cWinId)

        local target_win = cWinId
        if cfg.relative == "win" and cfg.win and vim.api.nvim_win_is_valid(cfg.win) then
          target_win = cfg.win
        end

        local tBufnr = vim.api.nvim_win_get_buf(target_win)
        if not vim.api.nvim_buf_is_loaded(tBufnr) then
          return nil
        end

        local fullpath = vim.api.nvim_buf_get_name(tBufnr)
        if fullpath == "" then
          return nil
        end

        local project_root = require("project_nvim.project").get_project_root()

        if project_root ~= nil then
          return vim.fn.fnamemodify(fullpath, ":." .. project_root)
        else
          return fullpath
        end
      end

      if winid ~= nil then
        local defaultWin = vim.api.nvim_win_get_config(winid)
        local path = defaultWin.title[1][1]
        local parentPath = get_parent_relative_path(winid)

        if path == parentPath then
          vim.api.nvim_set_hl(0, 'GotoPreviewTitle', {
            fg = '#40cd52',
            bold = true
          })

          local config = vim.tbl_extend("force", defaultWin, {
            title = { { path, "GotoPreviewTitle" } },
            title_pos = "left",
          })

          vim.api.nvim_win_set_config(winid, config)
        end
      end

      local resetKeyMaps = function ()
        vim.keymap.del('n', '<C-o>', { buffer = bufnr })
        vim.keymap.del('n', 'q', { buffer = bufnr })
        vim.keymap.del('n', '<Esc>', { buffer = bufnr })
        vim.keymap.del('n', '<CR>', { buffer = bufnr })
      end

      vim.keymap.set('n', '<C-o>', '<C-w>c', { buffer = bufnr })

      vim.keymap.set('n', 'q', function()
        require("goto-preview").close_all_win()
        resetKeyMaps()
      end, { buffer = bufnr, silent = true, nowait = true, desc = "Close preview" })

      vim.keymap.set('n', '<Esc>', function()
        require("goto-preview").close_all_win()
        resetKeyMaps()
      end, { buffer = bufnr, silent = true, nowait = true, desc = "Close preview" })

      vim.keymap.set('n', '<CR>', function()
        open_preview_in_buffer()
        resetKeyMaps()
      end, { buffer = bufnr, silent = true, nowait = true, desc = "Open in buffer" })

      vim.api.nvim_set_option_value('number', false, { scope = 'local' })
    end,
  }
}

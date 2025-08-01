return {
  "stevearc/oil.nvim",
  cmd = { "Oil" },
  opts = {
    columns = {
      "icon",
      -- "mtime"
    },
    win_options = {
      signcolumn = "yes:1",
      winbar = "%!v:lua.get_oil_winbar()"
    },
    view_options = {
      show_hidden = true,
    },
    keymaps = {
      ["q"] = { "actions.close", opts = { nowait = true }, mode = "n" },
      ["<Leader>w"] = { function ()
        require"oil".save()
      end, opts = { nowait = true }, mode = "n" },
      ["<c-d>"] = { function () require"plugins.fzf-lua_util".fzf_dirs() end, mode = "n" }
    }
  },
  init = function()
    function _G.get_oil_winbar()
      local bufnr = vim.api.nvim_win_get_buf(vim.g.statusline_winid)
      local dir = require("oil").get_current_dir(bufnr)
      if dir then
        return vim.fn.fnamemodify(dir, ":~")
      else
        -- If there is no current directory (e.g. over ssh), just show the buffer name
        return vim.api.nvim_buf_get_name(0)
      end
    end
  end,
}

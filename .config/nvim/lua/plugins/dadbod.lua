return {
  "kristijanhusak/vim-dadbod-ui",
  dependencies = "tpope/vim-dadbod",
  cmd = "DBUI",
  init = function ()
    vim.g.db_ui_use_nerd_fonts = 1
    vim.g.db_ui_win_position = 'right'
    local function delete_hide_buffer()
      local ignorelist = { "dbui", "dbout", "sql" }
      local list = vim.tbl_filter(function(val)
        return vim.fn.bufexists(val) == 1
      end, vim.fn.range(1, vim.fn.bufnr("$")))
      for _, num in ipairs(list) do
        if vim.tbl_contains(ignorelist, vim.fn.getbufvar(num, '&filetype')) and vim.fn.bufexists(num) == 1 then
          vim.cmd("bw! " .. num)
        end
      end
    end
    vim.api.nvim_create_user_command('DBUIDelete', delete_hide_buffer, {})
  end
}

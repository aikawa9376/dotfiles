return {
  "kevinhwang91/nvim-bqf",
  ft = "qf",
  config = function ()
    local setting = require('bqf.config')
    setting.preview.border = 'single'
    setting.preview.should_preview_cb = function (bufnr, qwinid)
      local bufname = vim.api.nvim_buf_get_name(bufnr)
      if bufname:match '^fugitive://' and not vim.api.nvim_buf_is_loaded(bufnr) then
        if bqf_pv_timer and bqf_pv_timer:get_due_in() > 0 then
          bqf_pv_timer:stop()
          bqf_pv_timer = nil
        end
        bqf_pv_timer = vim.defer_fn(function()
          vim.api.nvim_buf_call(bufnr, function()
            vim.cmd(('do fugitive BufReadCmd %s'):format(bufname))
          end)
          require('bqf.preview.handler').open(qwinid, nil, true)
        end, 60)
      end
      return true
    end
    vim.cmd([[
        hi link BqfPreviewFloat NormalFloat
        hi BqfPreviewBorder ctermbg=None guibg=#002b36 guifg=#839496
        hi BqfPreviewTitle ctermbg=None guibg=#002b36 guifg=#839496
        ]])
  end
}

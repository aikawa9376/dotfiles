return {
  'mfussenegger/nvim-lint',
  ft = { "php" },
  config = function ()
    local lint = require('lint')

    lint.linters_by_ft = {
      php = {'phpstan'},
    }

    ---@diagnostic disable: param-type-mismatch
    lint.linters.phpstan = vim.tbl_deep_extend("force", lint.linters.phpstan, {
      args = { "analyze", "--memory-limit", "512M", "--error-format", "json", "--no-progress" },
      temp_dir = "/tmp",
      timeout = 100,
      -- stdin = true,
    })

    local lint_augroup = vim.api.nvim_create_augroup('lint', { clear = true })
    vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWritePost', 'InsertLeave' }, {
      group = lint_augroup,
      callback = function()
        if vim.opt_local.modifiable:get() then
          lint.try_lint()
        end
      end,
    })
  end
}

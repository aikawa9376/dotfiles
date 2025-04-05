return {
  'mfussenegger/nvim-lint',
  ft = { 'php' },
  config = function ()
    local lint = require('lint')

    lint.linters_by_ft = {
      php = { 'phpstan' },
    }

    ---@diagnostic disable: param-type-mismatch
    lint.linters.phpstan = vim.tbl_deep_extend("force", lint.linters.phpstan, {
      args = { 'analyze', '--memory-limit', '512M', '--error-format', 'json', '--no-progress' },
      temp_dir = '/tmp',
      timeout = 100,
      -- stdin = true,
    })

    local function checkLintCommand()
      local ft = vim.bo.filetype
      local cmds = lint.linters_by_ft[ft]
      if not cmds then
        return false
      end
      if type(cmds) == 'table' and type(cmds[1]) == 'string' then
        if vim.fn.executable(cmds[1]) == 0 then
          return false
        end
      end
      return true
    end

    local lint_augroup = vim.api.nvim_create_augroup('lint', { clear = true })
    vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWritePost', 'InsertLeave' }, {
      group = lint_augroup,
      callback = function()
        if vim.opt_local.modifiable:get() and checkLintCommand() then
          lint.try_lint()
        end
      end,
    })
  end
}

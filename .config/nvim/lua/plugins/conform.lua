return {
  'stevearc/conform.nvim',
  cmd = { "Format", "ConformInfo" },
  keys = {
    { "ge", function () vim.cmd("Format") end, mode = { "n", "x" } },
  },
  ---@module "conform"
  ---@type conform.setupOpts
  opts = {
    formatters_by_ft = {
      ["_"] = { "default" },
      php = { "php_cs_fixer" },
      -- lua = { "stylua" },
      -- javascript = { "prettier" },
      sql = { "sql_formatter" },
      -- blade = { "blade_formatter" },
    },
    formaton_save = nil,
    default_format_opts = {
      lsp_format = "never"
    },
    formatters = {
      default = {
        format = function(_, ctx, _, callback)
          local cmd = ctx.range == nil and 'gg=G' or '='
          vim.cmd.normal({ 'm`' .. cmd .. '``', bang = true })
          callback()
        end,
      },
      php_cs_fixer = {
        command = "php-cs-fixer",
        args = { "fix", "$FILENAME" },
        env = { PHP_CS_FIXER_IGNORE_ENV = 1 },
      },
    },
  },
  config = function(_, opts)
    require("conform").setup(opts)

    vim.api.nvim_create_user_command("Format", function(args)
      local range = nil
      if args.count ~= -1 then
        local end_line = vim.api.nvim_buf_get_lines(0, args.line2 - 1, args.line2, true)[1]
        range = {
          start = { args.line1, 0 },
          ["end"] = { args.line2, end_line:len() },
        }
      end
      require("conform").format({ async = true, range = range })
    end, { range = true })
  end,
}

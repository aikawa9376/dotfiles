---@diagnostic disable: missing-fields
return {
  {
    "nvim-neotest/neotest",
    keys = {
      {
        '<Leader>TA',
        function()
          _ = require('plugins.neotest-adapters')[vim.bo.filetype]
          require('neotest').run.run { suite = false }
        end,
      },
      {
        '<Leader>TT',
        function ()
          _ = require('plugins.neotest-adapters')[vim.bo.filetype]
          require("neotest").summary.toggle()
        end
      },
      {
        "<leader>TO",
        function() require("neotest").output_panel.toggle() end,
      },
    },
    dependencies = { { 'nvim-neotest/nvim-nio', lazy = true } },
    opts = {
      adapters = {},
      status = {
        enabled = true,
        signs = false,
        virtual_text = true
      },
      summary = {
        mappings = {
          expand = "o",
          expand_all = "O",
          run = "<CR>",
          output = "p",
          short = "S",
        },
      },

    } -- no adapters registered on initial setup
  },
  {
    'olimorris/neotest-phpunit',
    lazy = true,
    init = function()
      require('plugins.neotest-adapters').php = 'neotest-phpunit' -- register filetype
    end,
    opts = {
      root_files = { "composer.json", "phpunit.xml", "phpunit.xml.dist", ".github" },
      phpunit_cmd = function()
        return vim.fn.stdpath("config") .. "/bin/unit_docker.sh"
        -- return "./vendor/bin/phpunit"
      end,
      env = {
        -- CONTAINER = "local-develop-circle-app-1",
        CONTAINER = "app",
        REMOTE_PHPUNIT_BIN = "./vendor/bin/phpunit",
      },
      filter_dirs = { "vendor" }
    },
    config = function(_, opts)
      local adapter = require 'neotest-phpunit'(opts)
      local adapters = require('neotest.config').adapters
      table.insert(adapters, adapter)
    end,
  },
}

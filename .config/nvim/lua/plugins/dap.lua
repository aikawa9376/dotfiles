return {
  {
    "mfussenegger/nvim-dap",
    cmd = {
      "DapToggleBreakpoint",
      "DapContinue",
      "DapStepOver",
      "DapStepInto",
      "DapStepOut",
      "DapTerminate",
    },
    config = function()
      local dap = require("dap")
      dap.set_log_level('TRACE')

      -- PHP adapter
      dap.adapters.php = {
        type = 'executable',
        command = 'node',
        args = { os.getenv('HOME') .. '/.local/share/nvim/mason/packages/php-debug-adapter/extension/out/php-debug-adapter.js' },
      }

      dap.configurations.php = {
        {
          type = 'php',
          request = 'launch',
          name = 'Listen for Xdebug',
          port = 9003,
          pathMappings = {
            ["/var/www/html"] = "${workspaceFolder}"
          }
        },
      }
    end,
  },
  {
    "rcarriga/nvim-dap-ui",
    lazy = true,
    config = function()
      local dapui = require("dapui")
      dapui.setup()

      local dap = require("dap")
      dap.listeners.after.event_initialized["dapui_config"] = function()
        dapui.open()
      end
      dap.listeners.before.event_terminated["dapui_config"] = function()
        dapui.close()
      end
      dap.listeners.before.event_exited["dapui_config"] = function()
        dapui.close()
      end
    end,
    init = function()
      vim.api.nvim_create_user_command("DapuiToggle", function()
        require("dapui").toggle()
      end, {})
      vim.api.nvim_create_user_command("DapuiEval", function()
        require("dapui").eval()
      end, {})
    end,
  },
  {
    "theHamsta/nvim-dap-virtual-text",
    cmd = { "DapVirtualTextToggle" },
    config = true,
  }
}

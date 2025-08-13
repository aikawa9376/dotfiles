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
      local dapui = require("dapui")
      local daptxt = require("nvim-dap-virtual-text")

      dap.defaults.fallback.switchbuf = 'usevisible,usetab,uselast'

      -- PHP adapter
      dap.adapters.php = {
        type = 'executable',
        command = 'sh',
        args = {
          vim.fn.exepath("php-debug-adapter"),
        },
      }

      dap.configurations.php = {
        {
          type = 'php',
          request = 'launch',
          name = 'Listen for Xdebug',
          port = 9001,
          pathMappings = {
            ["/var/www/html"] = vim.fn.getcwd()
          }
        },
      }

      vim.fn.sign_define("DapBreakpoint", { text = "", texthl = "", linehl = "", numhl = "" })
      vim.fn.sign_define("DapBreakpointRejected", { text = "󰉥", texthl = "", linehl = "", numhl = "", })
      vim.fn.sign_define("DapLogPoint", { text = "", texthl = "", linehl = "", numhl = "" })
      vim.fn.sign_define("DapStopped", { text = "", texthl = "", linehl = "", numhl = "" })

      dapui.setup()
      daptxt.setup({})

      dap.listeners.before.attach.dapui_config = function()
        dapui.open()
      end
      dap.listeners.before.launch.dapui_config = function()
        dapui.open()
      end
      dap.listeners.before.terminate.override = function()
        dapui.close()
      end
      dap.listeners.before.disconnect.override = function()
        dapui.close()
      end
      dap.listeners.after.terminate.override = function()
        daptxt.refresh()
      end
      dap.listeners.after.disconnect.override = function()
        daptxt.refresh()
      end
    end,
  },
  {
    "rcarriga/nvim-dap-ui",
    lazy = true,
  },
  {
    "theHamsta/nvim-dap-virtual-text",
    lazy = true,
    opts = {
      display_callback = function(variable, buf, stackframe, node, options)
        return ':' .. variable.value:gsub("%s+", " ")
      end,
    }
  }
}

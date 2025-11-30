return {
  "nvimtools/hydra.nvim",
  event = "BufReadPre",
  config = function ()
    local Hydra = require('hydra')

    -- undo-glow用
    local ugOpts = require("undo-glow.utils").merge_command_opts("UgPaste", {})
    local pasteWithGlow = function (key)
      require("undo-glow").highlight_changes(ugOpts)
      vim.fn.feedkeys(vim.api.nvim_replace_termcodes(key, true, true, true), 'n')
    end

    Hydra({
      name = 'Harpoon',
      mode = 'n',
      body = 'mf',
      config = {
        hint = false,
        invoke_on_body = true,
        on_enter = function()
          require("harpoon"):list("multiple"):prev()
        end
      },
      heads = {
        { 'f', '<cmd>lua require("harpoon"):list("multiple"):prev({ ui_nav_wrap = true })<CR>' },
        { 'b', '<cmd>lua require("harpoon"):list("multiple"):next({ ui_nav_wrap = true })<CR>' },
      }
    })
    Hydra({
      name = 'Harpoon',
      mode = 'n',
      body = 'mb',
      config = {
        hint = false,
        invoke_on_body = true,
        on_enter = function()
          require("harpoon"):list("multiple"):next()
        end
      },
      heads = {
        { 'f', '<cmd>lua require("harpoon"):list("multiple"):prev({ ui_nav_wrap = true })<CR>' },
        { 'b', '<cmd>lua require("harpoon"):list("multiple"):next({ ui_nav_wrap = true })<CR>' },
      }
    })

    Hydra({
      name = 'Buffer',
      mode = 'n',
      body = ']b',
      config = {
        hint = false,
        invoke_on_body = true,
        on_enter = function()
          vim.cmd 'bnext'
        end
      },
      heads = {
        { ']', '<cmd>bnext<CR>' },
        { '[', '<cmd>bpreviou<CR>' },
      }
    })
    Hydra({
      name = 'Buffer',
      mode = 'n',
      body = '[b',
      config = {
        hint = false,
        invoke_on_body = true,
        on_enter = function()
          vim.cmd 'bpreviou'
        end
      },
      heads = {
        { ']', '<cmd>bnext<CR>' },
        { '[', '<cmd>bpreviou<CR>' },
      }
    })

    Hydra({
      name = 'History',
      mode = 'n',
      body = 'g;',
      config = {
        hint = false,
        invoke_on_body = true,
        on_enter = function()
          vim.fn.feedkeys(vim.api.nvim_replace_termcodes('g;', true, true, true), 'n')
        end
      },
      heads = {
        { ';', 'g;' },
        { ',', 'g,' },
      }
    })
    Hydra({
      name = 'History',
      mode = 'n',
      body = 'g,',
      config = {
        hint = false,
        invoke_on_body = true,
        on_enter = function()
          vim.fn.feedkeys(vim.api.nvim_replace_termcodes('g,', true, true, true), 'n')
        end
      },
      heads = {
        { ';', 'g;' },
        { ',', 'g,' },
      }
    })

    Hydra({
      name = 'Yank',
      mode = { 'n', 'x' },
      body = 'p',
      config = {
        hint = false,
        invoke_on_body = true,
        on_enter = function()
          local is_visual = vim.fn.mode():match("v")
          if is_visual then
            pasteWithGlow('"_d<Plug>(YankyPutBefore)')
          else
            pasteWithGlow('<Plug>(YankyPutAfter)')
          end
        end
      },
      heads = {
        { '<C-p>', '<Plug>(YankyPreviousEntry)' },
        { '<C-n>', '<Plug>(YankyNextEntry)' },
        { '<C-w>', 'u<Plug>(YankyPutAfterCharwise)' },
        { '<C-l>', 'u<Plug>(YankyPutIndentAfterFilter)' },
        { '<C-b>', 'u<Plug>(YankyPutAfterBlockwise)' },
      }
    })
    Hydra({
      name = 'Yank',
      mode = { 'n', 'x' },
      body = 'P',
      config = {
        hint = false,
        invoke_on_body = true,
        on_enter = function()
          local is_visual = vim.fn.mode():match("v")
          if is_visual then
            pasteWithGlow('"_d<Plug>(YankyPutBefore)')
          else
            pasteWithGlow('<Plug>(YankyPutBefore)')
          end
        end
      },
      heads = {
        { '<C-p>', '<Plug>(YankyPreviousEntry)' },
        { '<C-n>', '<Plug>(YankyNextEntry)' },
        { '<C-w>', 'u<Plug>(YankyPutBeforeCharwise)' },
        { '<C-l>', 'u<Plug>(YankyPutIndentBeforeFilter)' },
        { '<C-b>', 'u<Plug>(YankyPutBeforeBlockwise)' },
      }
    })

    Hydra({
      name = 'SearchExD',
      mode = 'n',
      body = ']n',
      config = {
        hint = false,
        invoke_on_body = true,
        on_enter = function()
          vim.fn.feedkeys(
            vim.api.nvim_replace_termcodes('ngn<Esc>', true, true, true), 'n')
        end
      },
      heads = {
        { 'n', 'ngn<Esc>' },
      }
    })
    Hydra({
      name = 'SearchExU',
      mode = 'n',
      body = '[n',
      config = {
        hint = false,
        invoke_on_body = true,
        on_enter = function()
          vim.fn.feedkeys(
            vim.api.nvim_replace_termcodes('Ngn<Esc>', true, true, true), 'n')
        end
      },
      heads = {
        { 'n', 'Ngn<Esc>' },
      }
    })

    Hydra({
      name = 'Jump',
      mode = 'n',
      body = ']o',
      config = {
        hint = false,
        invoke_on_body = true,
        on_key = function() vim.wait(50) end,
        on_enter = function () require('bufjump').forward() end
      },
      heads = {
        { ']', function ()
          require('bufjump').forward()
        end },
        { '[', function ()
          require('bufjump').backward()
        end },
      }
    })
    Hydra({
      name = 'Jump',
      mode = 'n',
      body = '[o',
      config = {
        hint = false,
        invoke_on_body = true,
        on_key = function() vim.wait(50) end,
        on_enter = function () require('bufjump').backward() end
      },
      heads = {
        { ']', function ()
           require('bufjump').forward()
        end },
        { '[', function ()
          if vim.wo.diff then return '[c' end
           require('bufjump').backward()
        end },
      }
    })

    Hydra({
      name = 'Chunk',
      mode = 'n',
      body = ']c',
      config = {
        hint = false,
        invoke_on_body = true,
        on_key = function() vim.wait(50) end,
        on_enter = function ()
          local is_fugitive = vim.fn.expand('%'):match('^fugitive://') ~= nil
          require"gitsigns".nav_hunk('next', is_fugitive and { target = 'all' } or {})
        end
      },
      heads = {
        { ']', function ()
          if vim.wo.diff then return ']c' end
          vim.schedule(function()
            local is_fugitive = vim.fn.expand('%'):match('^fugitive://') ~= nil
            require"gitsigns".nav_hunk('next', is_fugitive and { target = 'all' } or {})
          end)
          return '<Ignore>'
        end },
        { '[', function ()
          if vim.wo.diff then return '[c' end
          vim.schedule(function()
            local is_fugitive = vim.fn.expand('%'):match('^fugitive://') ~= nil
            require"gitsigns".nav_hunk('prev', is_fugitive and { target = 'all' } or {})
          end)
          return '<Ignore>'
        end },
      }
    })
    Hydra({
      name = 'Chunk',
      mode = 'n',
      body = '[c',
      config = {
        hint = false,
        invoke_on_body = true,
        on_key = function() vim.wait(50) end,
        on_enter = function ()
          local is_fugitive = vim.fn.expand('%'):match('^fugitive://') ~= nil
          require"gitsigns".nav_hunk('prev', is_fugitive and { target = 'all' } or {})
        end
      },
      heads = {
        { ']', function ()
          if vim.wo.diff then return ']c' end
          vim.schedule(function()
            local is_fugitive = vim.fn.expand('%'):match('^fugitive://') ~= nil
            require"gitsigns".nav_hunk('next', is_fugitive and { target = 'all' } or {})
          end)
          return '<Ignore>'
        end },
        { '[', function ()
          if vim.wo.diff then return '[c' end
          vim.schedule(function()
            local is_fugitive = vim.fn.expand('%'):match('^fugitive://') ~= nil
            require"gitsigns".nav_hunk('prev', is_fugitive and { target = 'all' } or {})
          end)
          return '<Ignore>'
        end },
      }
    })

    Hydra({
      name = 'QuickFix',
      mode = 'n',
      body = ']q',
      config = {
        hint = false,
        invoke_on_body = true,
        on_key = function()
          if require"trouble".is_open() then
            vim.wait(50)
          end
        end,
        on_enter = function()
          if require"trouble".is_open() then
            vim.schedule(function() require("trouble").next({ jump = true }) end)
            return '<Ignore>'
          else
            require("quick-toggle").next_item()
            return '<Ignore>'
          end
        end
      },
      heads = {
        { ']', function ()
          if require"trouble".is_open() then
            vim.schedule(function() require("trouble").next({ jump = true }) end)
            return '<Ignore>'
          else
            require("quick-toggle").next_item()
            return '<Ignore>'
          end
        end },
        { '[', function ()
          if require"trouble".is_open() then
            vim.schedule(function() require("trouble").prev({ jump = true }) end)
            return '<Ignore>'
          else
            require("quick-toggle").previous_item()
            return '<Ignore>'
          end
        end }
      }
    })
    Hydra({
      name = 'QuickFix',
      mode = 'n',
      body = '[q',
      config = {
        hint = false,
        invoke_on_body = true,
        on_key = function()
          if require"trouble".is_open() then
            vim.wait(50)
          end
        end,
        on_enter = function()
          if require"trouble".is_open() then
            vim.schedule(function() require("trouble").prev({ jump = true }) end)
            return '<Ignore>'
          else
            require("quick-toggle").previous_item()
            return '<Ignore>'
          end
        end
      },
      heads = {
        { ']', function ()
          if require"trouble".is_open() then
            vim.schedule(function() require("trouble").next({ jump = true }) end)
            return '<Ignore>'
          else
            require("quick-toggle").next_item()
            return '<Ignore>'
          end
        end },
        { '[', function ()
          if require"trouble".is_open() then
            vim.schedule(function() require("trouble").prev({ jump = true }) end)
            return '<Ignore>'
          else
            require("quick-toggle").previous_item()
            return '<Ignore>'
          end
        end }
      }
    })

    Hydra({
      name = 'Linter',
      mode = 'n',
      body = ']a',
      config = {
        hint = false,
        invoke_on_body = true,
        on_enter = function()
          vim.diagnostic.jump({ count = 1, float = true })
          vim.diagnostic.open_float(nil, {  scope = 'cursor', focusable = false })
        end
      },
      heads = {
        { ']',
          "<cmd>lua vim.diagnostic.jump({count = 1, float = false})<CR><cmd>lua vim.diagnostic.open_float(nil, { scope = 'cursor',  focusable = false })<CR>" },
        { '[',
          "<cmd>lua vim.diagnostic.jump({count = -1, float = false})<CR><cmd>lua vim.diagnostic.open_float(nil, { scope = 'cursor',  focusable = false })<CR>" },
        { '<C-Space>',
          "<cmd>Lspsaga diagnostic_jump_next<CR>", { exit = true } },
      }
    })
    Hydra({
      name = 'Linter',
      mode = 'n',
      body = '[a',
      config = {
        hint = false,
        invoke_on_body = true,
        on_enter = function()
          vim.diagnostic.jump({ count = -1, float = true })
          vim.diagnostic.open_float(nil, {  scope = 'cursor', focusable = false })
        end
      },
      heads = {
        { ']',
          "<cmd>lua vim.diagnostic.jump({count = 1, float = false})<CR><cmd>lua vim.diagnostic.open_float(nil, { scope = 'cursor',  focusable = false })<CR>" },
        { '[',
          "<cmd>lua vim.diagnostic.jump({count = -1, float = false})<CR><cmd>lua vim.diagnostic.open_float(nil, { scope = 'cursor',  focusable = false })<CR>" },
        { '<C-Space>',
          "<cmd>Lspsaga diagnostic_jump_prev<CR>", { exit = true } },
      }
    })
  end
}

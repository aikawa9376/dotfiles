return {
  "aikawa9376/utilities.lua",
  keys = {
    { "gl", function() require"utilities".hl_text_toggle() end, mode = "n" },
    { "]p", function() require"utilities".yank_line('j') end, mode = "n" },
    { "[p", function() require"utilities".yank_line('k') end, mode = "n" },
    { "<M-p>", function() require"utilities".yank_remove_line() end, mode = "n" },
    { "<C-t>", function() require"utilities".yank_text_toggle() end, mode = "n" },
    { "<Leader>,", function() require"utilities".reload_vimrc() end, mode = "n" },
    { "dd", function() require"utilities".remove_line_brank(vim.v.count1) end, mode = "n" },
    { "dD", function() require"utilities".remove_line_brank_all(vim.v.count1) end, mode = "n" },
    { "i", function() return require "utilities".indent_with_i("m`mv") end, mode = "n", expr = true },
    { "gJ", function() require"utilities".join_space_less() end, mode = "n" },
    { "@", function() require"utilities".execute_macro_visual_range() end, mode = "x" },
    { "<C-K>", function() require"utilities".ctrl_k() end, mode = "c" },
  },
  cmd = { "Capture", "Diff" },
  config = function ()
    -- keep foldtext initialization in init
    -- vim.opt.foldtext = require"utilities".custom_fold_text()

    -- autocmd
    local group = vim.api.nvim_create_augroup('myutil', { clear = true })

    vim.api.nvim_create_autocmd('FileType', {
      pattern = 'gitcommit',
      command = 'setlocal spell',
      group = group,
    })

    vim.api.nvim_create_autocmd('BufWritePre', {
      pattern = '*',
      callback = function()
        require"utilities".auto_mkdir(vim.fn.expand('<afile>:p:h'), vim.v.cmdbang)
      end,
      group = group,
    })

    vim.api.nvim_create_autocmd({
      'TextYankPost',
      'TextChanged',
      'InsertEnter',
    }, {
        pattern = '*',
        callback = function()
          require"utilities".yank_toggle_flag()
        end,
        group = group,
      })

    vim.api.nvim_create_autocmd({
      'InsertLeave',
      'WinLeave',
      'BufEnter',
      'CmdlineLeave',
      'FocusGained',
      'VimResume'
    }, {
        pattern = '*',
        callback = function()
          require"utilities".fcitx2en()
        end,
        group = group,
      })

    -- ex command
    vim.api.nvim_create_user_command(
      'Capture',
      function(opts)
        require"utilities".cmd_capture(opts)
      end,
      { nargs = '+', bang = true, complete = 'command' }
    )

    vim.api.nvim_create_user_command(
      'Diff',
      function(opts)
        local args = {}
        if opts and opts.fargs and #opts.fargs > 0 then
          args[1] = table.concat(opts.fargs, ' ')
        end
        require('gitsigns').diffthis(unpack(args))
      end, {
        nargs = '*' ,
        complete = require"utilities".get_git_completions
      })
  end
}

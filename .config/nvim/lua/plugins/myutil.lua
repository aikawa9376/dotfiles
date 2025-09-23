return {
  "aikawa9376/myutil.vim",
  keys = {
    { "gl", "<cmd>call myutil#hl_text_toggle()<CR>", mode = "n", silent = true, desc = "myutil: toggle highlight text" },
    { "]p", "<cmd>call myutil#yank_line('j')<CR>=`]^", mode = "n", silent = true, desc = "myutil: yank line down" },
    { "[p", "<cmd>call myutil#yank_line('k')<CR>=`]^", mode = "n", silent = true, desc = "myutil: yank line up" },
    { "<M-p>", "<cmd>call myutil#yank_remove_line()<CR>=`]^", mode = "n", silent = true, desc = "myutil: yank and remove line" },
    { "<C-t>", "<cmd>call myutil#yank_text_toggle()<CR>", mode = "n", silent = true, desc = "myutil: toggle yank text" },
    { "<Leader>,", "<cmd>call myutil#reload_vimrc()<CR>", mode = "n", silent = true, desc = "myutil: reload vimrc" },
    { "<Plug>(my-switch)y", "<cmd>call myutil#toggle_syntax()<CR>", mode = "n", silent = true, desc = "myutil: toggle syntax (plug)" },
    { "<Plug>(my-switch)n", "<cmd>call myutil#toggle_relativenumber()<CR>", mode = "n", silent = true, desc = "myutil: toggle relativenumber (plug)" },
    { "dd", "<cmd>call myutil#remove_line_brank(v:count1)<CR>", mode = "n", silent = true, desc = "myutil: remove line (brank) single" },
    { "dD", "<cmd>call myutil#remove_line_brank_all(v:count1)<CR>", mode = "n", silent = true, desc = "myutil: remove line (brank) all" },
    { "i", function() return vim.fn['myutil#indent_with_i']("m`mv") end, mode = "n", expr = true, desc = "myutil: indent with i (expr)" },
    { "gJ", "<cmd>call myutil#join_space_less()<CR>", mode = "n", silent = true, desc = "myutil: join with less space" },
    { "@", "<cmd>call myutil#execute_macro_visual_range()<CR>", mode = "x", silent = true, desc = "myutil: execute macro on visual range" },
    { "<C-U>", function() return vim.fn['myutil#ctrl_u']() end, mode = "c", expr = true, desc = "myutil: ctrl-u in cmdline" },
    { "<C-W>", function() return vim.fn["myutil#ctrl_w_before"]() .. vim.fn["myutil#ctrl_w_after"]() end, mode = "c", expr = true, desc = "myutil: ctrl-w in cmdline" },
  },
  init = function ()
    -- keep foldtext initialization in init
    vim.opt.foldtext = "myutil#custom_fold_text()"
  end
}

return {
  "aikawa9376/myutil.vim",
  event = "BufRead",
  init = function ()
    vim.opt.foldtext = "myutil#custom_fold_text()"
    vim.keymap.set("n", "gl", "<cmd>call myutil#hl_text_toggle()<CR>", { silent = true })
    vim.keymap.set("n", "]p", "<cmd>call myutil#yank_line('j')<CR>=`]^", { silent = true })
    vim.keymap.set("n", "[p", "<cmd>call myutil#yank_line('k')<CR>=`]^", { silent = true })
    vim.keymap.set("n", "<M-p>", "<cmd>call myutil#yank_remove_line()<CR>=`]^", { silent = true })
    vim.keymap.set("n", "<C-t>", "<cmd>call myutil#yank_text_toggle()<CR>", { silent = true })
    vim.keymap.set("n", "<Leader>,", "<cmd>call myutil#reload_vimrc()<CR>", { silent = true })
    vim.keymap.set("n", "<Plug>(my-switch)y", "<cmd>call myutil#toggle_syntax()<CR>", { silent = true })
    vim.keymap.set("n", "<Plug>(my-switch)n", "<cmd>call myutil#toggle_relativenumber()<CR>", { silent = true })
    vim.keymap.set("n", "dd", "<cmd>call myutil#remove_line_brank(v:count1)<CR>", { silent = true })
    vim.keymap.set("n", "dD", "<cmd>call myutil#remove_line_brank_all(v:count1)<CR>", { silent = true })
    vim.keymap.set("n", "i", 'myutil#indent_with_i("m`mv")', { expr = true })
    vim.keymap.set("n", "gJ", "<cmd>call myutil#join_space_less()<CR>", { silent = true })
    vim.keymap.set("x", "@", "<cmd>call myutil#execute_macro_visual_range()<CR>", { silent = true })
    vim.keymap.set("c", "<C-U>", "myutil#ctrl_u()", { expr = true })
    vim.keymap.set("c", "<C-W>", function()
      return vim.fn["myutil#ctrl_w_before"]() .. vim.fn["myutil#ctrl_w_after"]()
    end, { expr = true })
  end
}

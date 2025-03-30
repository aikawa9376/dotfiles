return {
  "haya14busa/vim-asterisk",
  dependencies = "haya14busa/is.vim",
  keys = {
    { "/" },
    { "?" },
    {
      "n",
      function ()
        vim.fn.feedkeys(vim.api.nvim_replace_termcodes("<Plug>(is-n)", true, false, true), "n")
        vim.schedule(function ()
          UgSearch({ animation = { animation_type = "strobe" } })
        end)
      end,
      mode = { "n", "x" },
      silent = true,
    },
    {
      "N",
      function ()
        vim.fn.feedkeys(vim.api.nvim_replace_termcodes("<Plug>(is-N)", true, false, true), "n")
        vim.schedule(function ()
          UgSearch({ animation = { animation_type = "strobe" } })
        end)
      end,
      mode = { "n", "x" },
      silent = true,
    },
    {
      "*",
      function ()
        vim.fn.feedkeys(vim.api.nvim_replace_termcodes("<Plug>(is-nohl-1)<Plug>(asterisk-gz*)", true, false, true), "n")
        vim.schedule(function ()
          UgSearch({ animation = { animation_type = "strobe" } })
        end)
      end,
      mode = { "n", "x" },
      silent = true,
    },
    {
      "g*",
      function ()
        vim.fn.feedkeys(vim.api.nvim_replace_termcodes("<Plug>(is-nohl-1)<Plug>(asterisk-gz*)", true, false, true), "n")
        vim.schedule(function ()
          UgSearch({ animation = { animation_type = "strobe" } })
        end)
      end,
      mode = { "n", "x" },
      silent = true,
    },
    {
      "#",
      function ()
        vim.fn.feedkeys(vim.api.nvim_replace_termcodes("<Plug>(is-nohl-1)<Plug>(asterisk-z#)", true, false, true), "n")
        vim.schedule(function ()
          UgSearch({ animation = { animation_type = "strobe" } })
        end)
      end,
      mode = { "n", "x" },
      silent = true,
    },
    {
      "g#",
      function ()
        vim.fn.feedkeys(vim.api.nvim_replace_termcodes("<Plug>(is-nohl-1)<Plug>(asterisk-gz#)", true, false, true), "n")
        vim.schedule(function ()
          UgSearch({ animation = { animation_type = "strobe" } })
        end)
      end,
      mode = { "n", "x" },
      silent = true,
    },
  },
  init = function ()
    function UgSearch( opts)
      vim.g.ug_ignore_cursor_moved = true
      local region = require("undo-glow.utils").get_search_region()
      if not region then
        return
      end
      opts = require("undo-glow.utils").merge_command_opts("UgSearch", opts)
      require("undo-glow").highlight_region(vim.tbl_extend("force", opts, {
        s_row = region.s_row,
        s_col = region.s_col,
        e_row = region.e_row,
        e_col = region.e_col,
      }))
    end
  end
}

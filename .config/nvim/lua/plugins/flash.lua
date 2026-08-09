return {
  "folke/flash.nvim",
  config = function(_, opts)
    -- Compatibility with Neovim 0.13's SearchState refactor.
    -- Remove this workaround once folke/flash.nvim#492 is merged.
    if vim.fn.has("nvim-0.13") == 1 then
      local ffi = require("ffi")
      if not pcall(ffi.typeof, "FlashSearchState") then
        ffi.cdef([[
          typedef struct {
            bool hl_match;
            int32_t match_lines;
            int match_endcol;
            int32_t first_line;
            int32_t last_line;
            bool no_smartcase;
            int cmdlen;
            bool no_hlsearch;
          } FlashSearchState;

          FlashSearchState Search;
        ]])
      end

      local Hacks = require("flash.hacks")
      local Pos = require("flash.search.pos")
      local incsearch_state = {}

      rawset(Hacks, "get_end_pos", function(from)
        local ret = Pos({
          from[1] + ffi.C.Search.match_lines,
          math.max(0, ffi.C.Search.match_endcol - 1),
        })
        local line = vim.api.nvim_buf_get_lines(0, ret[1] - 1, ret[1], false)[1]
        local char_idx = vim.fn.charidx(line, ret[2])
        ret[2] = vim.fn.byteidx(line, char_idx)
        return ret
      end)

      rawset(Hacks, "save_incsearch_state", function()
        incsearch_state = {
          match_endcol = ffi.C.Search.match_endcol,
          match_lines = ffi.C.Search.match_lines,
        }
      end)

      rawset(Hacks, "restore_incsearch_state", function()
        ffi.C.Search.match_endcol = incsearch_state.match_endcol
        ffi.C.Search.match_lines = incsearch_state.match_lines
      end)
    end

    require("flash").setup(opts)
  end,
  keys = {
    { "f", "F", "t", "T", ";", ",", mode = { "n", "x" } },
    {
      "<C-j>",
      mode = { "n", "x", "o" },
      function()
        require("flash").jump({ search = { forward = true, wrap = false, incremental = true } })
      end,
      desc = "Flash",
    },
    {
      "<C-k>",
      mode = { "n", "x", "o" },
      function() require("flash").jump({ search = { forward = false , wrap = false, incremental = true } }) end,
      desc = "Flash",
    },
    {
      "<C-s>",
      mode = { "n", "x", "o" },
      function() require("flash").treesitter() end,
      desc = "Flash Treesitter",
    },
    {
      "r",
      mode = "o",
      function() require("flash").remote() end,
      desc = "Remote Flash",
    },
    {
      "R",
      mode = { "o", "x" },
      function() require("flash").treesitter_search() end,
      desc = "Treesitter Search",
    },
    {
      "<C-s>",
      mode = { "c" },
      function() require("flash").toggle() end,
      desc = "Toggle Flash Search",
    },
  },
  ---@type Flash.Config
  opts = {
    search = {
      exclude = {
        "notify",
        "cmp_menu",
        "noice",
        "flash_prompt",
        function(win)
          -- exclude non-focusable windows
          return not vim.api.nvim_win_get_config(win).focusable
        end,
      },
    },
    ---@type table<string, Flash.Config>
    modes = {
      char = {
        enabled = true,
        -- dynamic configuration for ftFT motions
        config = function(opts)
          opts.autohide = vim.fn.mode(true):find("no")
          opts.jump_labels = not vim.fn.mode(true):find("o")
            and vim.v.count == 0
            and vim.fn.reg_executing() == ""
            and vim.fn.reg_recording() == ""
        end,
        label = { exclude = "hjkliardcy" },
        jump = {
          autojump = true,
        },
      },
    },
    prompt = {
      enabled = false,
    },
  },
}

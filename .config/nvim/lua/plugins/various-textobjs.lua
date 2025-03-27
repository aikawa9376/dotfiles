return {
  "chrisgrieser/nvim-various-textobjs",
  keys = function(_, keys)
    local function select_paragraph(flag)
      local bufnr = vim.api.nvim_get_current_buf()
      local cursor = vim.api.nvim_win_get_cursor(0)
      local row = cursor[1] -- Lua の index は 0 ベース

      -- 現在のバッファのすべての行を取得
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local total_lines = #lines

      if total_lines == 0 then return end -- 空のバッファなら何もしない
      if lines[row]:match("^%s*$") then return end -- カーソル行が空なら何もしない

      -- パラグラフの開始位置を探す（前方の空行で止まる）
      local start_row = row
      while start_row > 0 and not lines[start_row]:match("^%s*$") do
        start_row = start_row - 1
      end

      -- パラグラフの終了位置を探す（後方の空行で止まる）
      local end_row = row
      while end_row < total_lines - 1 and not lines[end_row]:match("^%s*$") do
        end_row = end_row + 1
      end

      if flag == "inner" then
        start_row = start_row + 1
        end_row = end_row - 1
      end

      local is_visual = vim.fn.mode():match("v")

      -- 開始位置と終了位置を正しくセット（行単位で選択）
      vim.api.nvim_buf_set_mark(bufnr, '<', start_row, start_row, {})
      vim.api.nvim_buf_set_mark(bufnr, '>', end_row, end_row, {})

      if is_visual then
        vim.api.nvim_command("normal! `<Vo`>")
      else
        vim.api.nvim_command("normal! `<V`>")
      end
    end

    local function overrideAnyBracket(scope)
      local patterns = {
        ["()"] = "(%().-(%))",
        ["[]"] = "(%[).-(%])",
        ["{}"] = "({).-(})",
        ["<>"] = "(<).-(>)",
      }
      require("various-textobjs.textobjs.charwise.core").selectClosestTextobj(patterns, scope, 5)
    end

    local mappings = {
      {
        "ai",
        function ()
          if vim.fn.indent(".") == 0 then
            select_paragraph("outer")
          else
            require"various-textobjs".indentation("outer", "outer")
          end
        end,
        mode = { "o", "x" }
      },
      {
        "ii",
        function ()
          if vim.fn.indent(".") == 0 then
            select_paragraph("inner")
          else
            require"various-textobjs".indentation("inner", "inner")
          end
        end,
        mode = { "o", "x" }
      },
      { "ae", function () require"various-textobjs".subword("outer") end, mode = { "o", "x" } },
      { "ae", function() require("various-textobjs").subword("outer") end, mode = { "o", "x" } },
      { "ie", function() require("various-textobjs").subword("inner") end, mode = { "o", "x" } },
      { "al", function() require("various-textobjs").lineCharacterwise() end, mode = { "o", "x" } },
      { "il", function() require("various-textobjs").lineCharacterwise() end, mode = { "o", "x" } },
      { "aq", function() require("various-textobjs").anyQuote("outer") end, mode = { "o", "x" } },
      { "iq", function() require("various-textobjs").anyQuote("inner") end, mode = { "o", "x" } },
      { "ab", function() overrideAnyBracket("outer") end, mode = { "o", "x" } },
      { "ib", function() overrideAnyBracket("inner") end, mode = { "o", "x" } },
      { "B", function() require("various-textobjs").toNextClosingBracket() end, mode = { "o", "x" } },
      { "Q", function() require("various-textobjs").toNextQuotationMark() end, mode = { "o", "x" } },
      { "E", function() require("various-textobjs").entireBuffer() end, mode = { "o", "x" } },
      { "D", function() require("various-textobjs").diagnostic() end, mode = { "o", "x" } },
      { "L", function() require("various-textobjs").lastChange() end, mode = { "o", "x" } }
    }
    mappings = vim.tbl_filter(function(m) return m[1] and #m[1] > 0 end, mappings)
    return vim.list_extend(mappings, keys)
  end,
  opts = {
    keymaps = {
      -- See overview table in README for the defaults. (Note that lazy-loading
      -- this plugin, the default keymaps cannot be set up. if you set this to
      -- `true`, you thus need to add `lazy = false` to your lazy.nvim config.)
      useDefaults = false,

      -- disable only some default keymaps, for example { "ai", "!" }
      -- (only relevant when you set `useDefaults = true`)
      ---@type string[]
      disabledDefaults = {},
    },

    forwardLooking = {
      -- Number of lines to seek forwards for a text object. See the overview
      -- table in the README for which text object uses which value.
      small = 5,
      big = 15,
    },
    behavior = {
      -- save position in jumplist when using text objects
      jumplist = true,
    },

    -- extra configuration for specific text objects
    textobjs = {
      indentation = {
        -- `false`: only indentation decreases delimit the text object
        -- `true`: indentation decreases as well as blank lines serve as delimiter
        blanksAreDelimiter = true,
      },
      subword = {
        -- When deleting the start of a camelCased word, the result should
        -- still be camelCased and not PascalCased (see #113).
        noCamelToPascalCase = true,
      },
      diagnostic = {
        wrap = true,
      },
      url = {
        patterns = {
          [[%l%l%l+://[^%s)%]}"'`>]+]],
        },
      },
    },

    notify = {
      icon = "󰠱", -- only used with notification plugins like `nvim-notify`
      whenObjectNotFound = true,
    },

    -- show debugging messages on use of certain text objects
    debug = false,
  },
}

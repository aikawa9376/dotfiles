return {
  {
    "nvim-treesitter/nvim-treesitter",
    lazy = true,
    branch = "main",
    build = ":TSUpdate",
    init = function ()
      vim.treesitter.language.register('bash', { 'sh', 'zsh' })
      vim.treesitter.language.register('markdown', { 'lazyagent', 'lazyagent_acp' })

      vim.api.nvim_create_autocmd("FileType", {
        -- NOTICE: need treesitter-cli
        group = vim.api.nvim_create_augroup("vim-treesitter-start", {}),
        callback = function(ctx)
          local lang = vim.treesitter.language.get_lang(ctx.match)
          local treesitter = require"nvim-treesitter"

          if not vim.list_contains(treesitter.get_available(), lang) then
            return
          end

          local function start()
            if not vim.api.nvim_buf_is_loaded(ctx.buf) or vim.bo[ctx.buf].filetype ~= ctx.match then
              return false
            end
            if not pcall(vim.treesitter.start, ctx.buf, lang) then
              return false
            end
            vim.bo[ctx.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
            for _, win in ipairs(vim.fn.win_findbuf(ctx.buf)) do
              vim.wo[win].foldexpr = "v:lua.vim.treesitter.foldexpr()"
            end
            return true
          end

          -- Installed parsers should highlight on FileType, before the first redraw.
          if not start() then
            vim.schedule(function()
              treesitter.install(lang):wait()
              start()
            end)
          end
        end,
      })
    end
  },
  {
    "nvim-treesitter/nvim-treesitter-textobjects",
    branch = "main",
    keys = {
      { "af", function ()
        require"nvim-treesitter-textobjects.select".select_textobject("@function.outer", "textobjects")
      end, mode = { "o", "x" } },
      { "if", function ()
        require"nvim-treesitter-textobjects.select".select_textobject("@function.inner", "textobjects")
      end, mode = { "o", "x" } },
      { "aC", function ()
        require"nvim-treesitter-textobjects.select".select_textobject("@class.outer", "textobjects")
      end, mode = { "o", "x" } },
      { "iC", function ()
        require"nvim-treesitter-textobjects.select".select_textobject("@class.inner", "textobjects")
      end, mode = { "o", "x" } },
      { "aa", function ()
        require"nvim-treesitter-textobjects.select".select_textobject("@parameter.outer", "textobjects")
      end, mode = { "o", "x" } },
      { "ia", function ()
        require"nvim-treesitter-textobjects.select".select_textobject("@parameter.inner", "textobjects")
      end, mode = { "o", "x" } },
      { "]]", function ()
        require"nvim-treesitter-textobjects.move".goto_next_start("@function.outer", "textobjects")
      end },
      { "[[", function ()
        require"nvim-treesitter-textobjects.move".goto_previous_start("@function.outer", "textobjects")
      end }
    },
    opts = {
      select = {
        lookahead = true,
      },
      move = {
        set_jumps = true,
      }
    },
    config = true,
  },
  { "windwp/nvim-ts-autotag", event = "BufReadPre", config = true },
  { "m-demare/hlargs.nvim", event = "BufReadPre", opts = { hl_priority = 150 } },
  {
    "HiPhish/rainbow-delimiters.nvim",
    event = "BufReadPre",
    config = function()
      require('rainbow-delimiters.setup').setup{
        highlight = {
          'RainbowDelimiterBlue',
          'RainbowDelimiterGreen',
          'RainbowDelimiterViolet',
          'RainbowDelimiterYellow',
          'RainbowDelimiterOrange',
          'RainbowDelimiterCyan',
          'RainbowDelimiterRed',
        },
      }
    end
  },
  {
    "JoosepAlviste/nvim-ts-context-commentstring",
    lazy = true,
    opts = {
      enable_autocmd = false,
    },
    init = function ()
      vim.g.skip_ts_context_commentstring_module = true
    end
  },
  { "nvim-treesitter/nvim-treesitter-refactor", lazy = true },
  { "nvim-treesitter/playground", lazy = true },
}

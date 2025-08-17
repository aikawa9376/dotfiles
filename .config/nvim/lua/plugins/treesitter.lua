return {
  {
    "nvim-treesitter/nvim-treesitter",
    lazy = true,
    branch = "main",
    build = ":TSUpdate",
    init = function ()
      vim.api.nvim_create_autocmd("FileType", {
        -- NOTICE: need treesitter-cli
        group = vim.api.nvim_create_augroup("vim-treesitter-start", {}),
        callback = function(ctx)
          vim.treesitter.language.register('bash', { 'sh', 'zsh' })

          local lang = vim.treesitter.language.get_lang(ctx.match)
          local has_parser = pcall(vim.treesitter.language.inspect, lang)

          if not has_parser then
            return
          end

          local _, ts = pcall(require, "nvim-treesitter")

          vim.schedule(function()
            ts.install(lang):wait()
            vim.treesitter.start(ctx.buf)
            vim.wo.foldexpr = "v:lua.vim.treesitter.foldexpr()"
            vim.bo.indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
          end)
        end,
      })
    end
  },
  {
    "nvim-treesitter-textobjects",
    branch = "main",
    keys = {
      { "af", function ()
        require"nvim-treesitter-textobjects.select".select_textobject("@function.outer", "textobjects")
      end, mode = { "o" } },
      { "if", function ()
        require"nvim-treesitter-textobjects.select".select_textobject("@function.inner", "textobjects")
      end, mode = { "o" } },
      { "aC", function ()
        require"nvim-treesitter-textobjects.select".select_textobject("@class.outer", "textobjects")
      end, mode = { "o" } },
      { "iC", function ()
        require"nvim-treesitter-textobjects.select".select_textobject("@class.inner", "textobjects")
      end, mode = { "o" } },
      { "aa", function ()
        require"nvim-treesitter-textobjects.select".select_textobject("@parameter.outer", "textobjects")
      end, mode = { "o" } },
      { "ia", function ()
        require"nvim-treesitter-textobjects.select".select_textobject("@parameter.inner", "textobjects")
      end, mode = { "o" } },
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

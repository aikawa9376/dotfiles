local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
  if vim.v.shell_error ~= 0 then
    vim.api.nvim_echo({
      { "Failed to clone lazy.nvim:\n", "ErrorMsg" },
      { out, "WarningMsg" },
      { "\nPress any key to exit..." },
    }, true, {})
    vim.fn.getchar()
    os.exit(1)
  end
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  spec = {
    { import = "plugins.nightfox" },
    { import = "plugins.project" },
    { import = "plugins.null-ls" },
    { import = "plugins.dressing" },
    { import = "plugins.lightbulb" },
    { import = "plugins.illuminate" },
    { import = "plugins.refactoring" },
    { import = "plugins.notify" },
    { import = "plugins.noice" },
    { import = "plugins.tiny-inline-diagnostic" },
    { import = "plugins.hlchunk" },
    { import = "plugins.outline" },
    { import = "plugins.avante" },
    { import = "plugins.colorizer" },
    { import = "plugins.insx" },
    { import = "plugins.automa" },
    { import = "plugins.comment" },
    { import = "plugins.yanky" },
    { import = "plugins.leap" },
    { import = "plugins.quick-scope" },
    { import = "plugins.multicursors" },
    { import = "plugins.asterisk" },
    { import = "plugins.edgemotion" },
    { import = "plugins.migemo-search" },
    { import = "plugins.various-textobjs" },
    { import = "plugins.substitute" },
    { import = "plugins.smartchr" },
    { import = "plugins.hydra" },
    { import = "plugins.surround" },
    { import = "plugins.matchup" },
    { import = "plugins.treesj" },
    { import = "plugins.neogen" },
    { import = "plugins.neo-tree" },
    { import = "plugins.bqf" },
    { import = "plugins.harpoon" },
    { import = "plugins.fzf-lua" },
    { import = "plugins.render_markdown" },
    { import = "plugins.undotree" },
    { import = "plugins.grug-far" },
    { import = "plugins.junkfile" },
    { import = "plugins.dadbod" },
    { import = "plugins.tmux" },
    { import = "plugins.gitgutter" },
    { import = "plugins.fugitive" },
    { import = "plugins.diffview" },
    { import = "plugins.lualine" },
    { import = "plugins.bufferline" },
    { import = "plugins.myutil" },
    { import = "plugins.dial" },
    { import = "plugins.toggleterm" },
    { import = "plugins.treesitter" },
    { import = "plugins.bufjump" },
    { import = "plugins.gitlinker" },
    { import = "plugins.others" },
    { import = "plugins.incline" },
    -- { import = "plugins.undo-glow" },
    { import = "plugins.nvim-cmp" },
    { "neovim/nvim-lspconfig", lazy = true, init = function () require"lsp" end, },
    { "williamboman/mason.nvim", lazy = true },
    { "williamboman/mason-lspconfig.nvim", lazy = true },
    { "zbirenbaum/copilot.lua", lazy = true },
    { "L3MON4D3/LuaSnip", lazy = true },
    { "rafamadriz/friendly-snippets", lazy = true },
    { "onsails/lspkind-nvim", lazy = true },
    { "kyazdani42/nvim-web-devicons", lazy = true },
    { "MunifTanjim/nui.nvim", lazy = true },
    { "ethanholz/nvim-lastplace", config = true },
    { "nvim-lua/plenary.nvim", lazy = true },
    { "ray-x/lsp_signature.nvim", lazy = true },
    { "MysticalDevil/inlay-hints.nvim", lazy = true },
    { "pmizio/typescript-tools.nvim", lazy = true },
    { "simrat39/rust-tools.nvim", lazy = true },
    { "honza/vim-snippets", event = "VeryLazy" },
    { "haya14busa/is.vim", event = "VeryLazy" },
    { "kana/vim-niceblock", event = "VeryLazy" },
    { "stevearc/quicker.nvim", ft = "qf", config = true },
    { "aikawa9376/vim-auto-cursorline", event = "VeryLazy" },
    { "aikawa9376/neomru.vim", event = "VeryLazy" },
    { "cseickel/diagnostic-window.nvim", cmd = { "DiagWindowShow" } },
    { "vim-scripts/BufOnly.vim", cmd = { "BufOnly" } },
    { "moll/vim-bbye", cmd = { "Bdelete", "Bwipeout" } },
  },
})

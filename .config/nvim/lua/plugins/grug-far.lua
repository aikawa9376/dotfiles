return {
  "MagicDuck/grug-far.nvim",
  keys = {
    {
      "<leader>rr",
      function () require('grug-far').open({ transient = true }) end,
      silent = true,
    },
    {
      "<leader>rR",
      function () require('grug-far').open({ transient = true, prefills = { search = vim.fn.expand('<cword>') } }) end,
      silent = true,
    },
    {
      "<leader>rR",
      function () require('grug-far').with_visual_selection({ transient = true }) end,
      mode = { "x" },
      silent = true,
    }
  },
  opts = {
    engines = {
      ripgrep = {
        extraArgs = '--hidden',
      }
    },
    keymaps = {
      replace = { n = '<localleader>r' },
      qflist = { n = '<localleader>q' },
      syncLocations = { n = '<localleader>s' },
      syncLine = { n = '<localleader>l' },
      close = { n = 'q' },
      historyOpen = { n = '<localleader>t' },
      historyAdd = { n = '<localleader>a' },
      refresh = { n = '<localleader>f' },
      openLocation = { n = '<localleader>o' },
      openNextLocation = { n = '<down>' },
      openPrevLocation = { n = '<up>' },
      gotoLocation = { n = '<enter>' },
      pickHistoryEntry = { n = '<enter>' },
      abort = { n = '<localleader>b' },
      help = { n = 'g?' },
      toggleShowCommand = { n = '<localleader>p' },
      swapEngine = { n = '<localleader>e' },
      previewLocation = { n = '<localleader>i' },
      swapReplacementInterpreter = { n = '<localleader>x' },
    },
  }
}

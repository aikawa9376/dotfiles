return {
  'y3owk1n/time-machine.nvim',
  cmd = {
    "TimeMachineToggle",
    "TimeMachinePurgeBuffer",
    "TimeMachinePurgeAll",
    "TimeMachineLogShow",
    "TimeMachineLogClear",
  },
  keys = {
    { "<Leader>u", "<cmd>TimeMachineToggle<cr>", silent = true }
  },
  opts = {}
}

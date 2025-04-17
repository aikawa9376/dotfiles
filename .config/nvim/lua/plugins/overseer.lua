return {
  "stevearc/overseer.nvim",
  dependencies = {
    "stevearc/dressing.nvim",
  },
  cmd = { 'OverseerRun', 'OverseerToggle' },
  opts = {
    template_dirs = { 'tasks', 'overseer.template' },
    templates = {
      'builtin'
    },
  },
}

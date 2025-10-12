return {
  "stevearc/overseer.nvim",
  cmd = { 'OverseerRun', 'OverseerToggle' },
  opts = {
    template_dirs = { 'tasks', 'overseer.template' },
    templates = {
      'builtin'
    },
  },
}

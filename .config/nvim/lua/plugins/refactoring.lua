return {
  "ThePrimeagen/refactoring.nvim",
  keys = {
    { "<leader>rf", function () require('refactoring').select_refactor() end, mode = { "x" }, silent = true }
  }
}

return {
  "mistweaverco/kulala.nvim",
  ft = { "http", "rest" },
  cmd = { "KulalaRun", "KulalaRunAll", "KulalaScratchpad" },
  config = function()
    vim.api.nvim_create_user_command("KulalaRun", function()
      require("kulala").run()
    end, { desc = "Run current request" })

    vim.api.nvim_create_user_command("KulalaRunAll", function()
      require("kulala").run_all()
    end, { desc = "Run all requests" })

    vim.api.nvim_create_user_command("KulalaScratchpad", function()
      require("kulala").scratchpad()
    end, { desc = "Open scratchpad" })

    require("kulala").setup({
      global_keymaps = true,
      global_keymaps_prefix = "<leader>R",
      kulala_keymaps_prefix = "",
    })
  end,
}

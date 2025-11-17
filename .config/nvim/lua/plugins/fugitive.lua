return {
  "tpope/vim-fugitive",
  cmd = {
    "G", "Git", "Gdiff", "Gwrite", "Gread", "Gdiffsplit",
    "Gedit", "Gcd", "Gclog", "GeditHeadAtFile", "Gvsplit"
  },
  dependencies = "fugitive-extension",
  keys = {
    { "<Leader>gs", "<cmd>Git<CR>", silent = true },
    { "<Leader>gg", "<cmd>GeditHeadAtFile<CR>", silent = true },
    { "<Leader>gb", "<cmd>Git blame -w --date=format:'%Y-%m-%d %H:%M'<CR>", silent = true },
    { "<Leader>gr", "<cmd>Git! rm --cached %<CR>", silent = true },
    { "<Leader>gM", "<cmd>Git! commit -m 'tmp'<CR>", silent = true },
    { "<Leader>gA", "<cmd>Gwrite<CR>", silent = true },
    { "<Leader>gp", function()
      vim.notify("Pushing...", vim.log.levels.INFO)
      local output_lines = {}
      vim.fn.jobstart("git push --force-with-lease", {
        on_exit = function(_, exit_code)
          vim.schedule(function()
            local message = table.concat(output_lines, "\n")
            if exit_code == 0 then
              vim.notify("Push successful\n" .. message, vim.log.levels.INFO)
            else
              vim.notify("Push failed\n" .. message, vim.log.levels.ERROR)
            end
          end)
          vim.fn['fugitive#ReloadStatus']()
        end,
        on_stdout = function(_, data)
          if data then
            for _, line in ipairs(data) do
              if line and line ~= "" then
                table.insert(output_lines, line)
              end
            end
          end
        end,
        on_stderr = function(_, data)
          if data then
            for _, line in ipairs(data) do
              if line and line ~= "" then
                table.insert(output_lines, line)
              end
            end
          end
        end,
      })
    end, silent = true },
  },
}

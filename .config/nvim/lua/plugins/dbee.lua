return {
  "kndndrj/nvim-dbee",
  cmd = "Dbee",
  build = function()
    -- Install tries to automatically detect the install method.
    -- if it fails, try calling it with one of these parameters:
    --    "curl", "wget", "bitsadmin", "go"
    require("dbee").install()
  end,
  config = function()
    require("dbee").setup({
      sources = {
        require("dbee.sources").FileSource:new(
          vim.fn.stdpath("cache") .. "/dbee/persistence.json"
        ),
      },
      result = {
        focus_result = false
      },
      editor = {
        mappings = {
          { key = "<CR>", mode = "v", action = "run_selection" },
          { key = "<Leader><CR>", mode = "n", action = "run_file" },
        }
      }
    })
  end,
}

-- nvim --headless --clean -u NONE -l .config/nvim/tests/image_preview_lazy_spec.lua
local config = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
local plugins = vim.fn.stdpath("data") .. "/lazy"
vim.opt.rtp:prepend(config)
vim.opt.rtp:prepend(plugins .. "/lazy.nvim")
local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture, "p")
local path = fixture .. "/image space.png"
vim.fn.writefile({ "fixture" }, path)
local rendered
local ok, err = xpcall(function()
  require("lazy").setup({
    {
      "folke/snacks.nvim",
      lazy = true,
      config = function()
        require("snacks").setup({ image = { enabled = true } })
        require("snacks").image.buf.attach = function(_, opts) rendered = opts.src end
      end,
    },
    dofile(config .. "/lua/plugins/image-preview.lua"),
  }, {
    root = plugins,
    lockfile = fixture .. "/lazy-lock.json",
    state = fixture .. "/state.json",
    install = { missing = false },
    checker = { enabled = false },
    change_detection = { enabled = false },
    readme = { enabled = false },
    performance = { rtp = { reset = false } },
  })
  local specs = require("lazy.core.config").plugins
  assert(specs["image-preview"].virtual == true)
  assert(not specs["image-preview"]._.loaded)
  assert(not specs["snacks.nvim"]._.loaded)
  assert(vim.fn.exists(":ImagePreview") == 2)
  vim.cmd("ImagePreview " .. vim.fn.fnameescape(path))
  assert(specs["image-preview"]._.loaded)
  assert(specs["snacks.nvim"]._.loaded)
  assert(rendered == path, vim.inspect({ rendered = rendered, expected = path }))
  assert(vim.api.nvim_win_get_config(0).relative ~= "")
  assert(vim.fn.maparg("<Esc>", "n") ~= "")
  print("PASS: virtual ImagePreview loads on command and loads its Snacks dependency")
end, debug.traceback)
vim.fn.delete(fixture, "rf")
if not ok then error(err) end
vim.cmd("qa!")

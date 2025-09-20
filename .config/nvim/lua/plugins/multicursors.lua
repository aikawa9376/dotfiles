return {
  "jake-stewart/multicursor.nvim",
  keys = function(_, keys)
    local mappings = {
      { "M", function() require("multicursor-nvim").visualToCursors() end, mode = { "x" }, },
      { "<leader>m", function() require("multicursor-nvim").matchAllAddCursors() end, mode = { "x" }, },
    }
    mappings = vim.tbl_filter(function(m) return m[1] and #m[1] > 0 end, mappings)
    return vim.list_extend(mappings, keys)
  end,
  config = function ()
    local mc = require("multicursor-nvim")
    mc.setup()
    mc.addKeymapLayer(function(layerSet)
      -- Enable and clear cursors using escape.
      layerSet({"n", "x"}, "M", function()
        if not mc.cursorsEnabled() then
          mc.enableCursors()
        else
          mc.clearCursors()
        end
      end)
      layerSet({"n", "x"}, "<leader>a", mc.alignCursors)
      layerSet({"n", "x"}, "<C-p>", mc.prevCursor)
      layerSet({"n", "x"}, "<C-n>", mc.nextCursor)
      layerSet({"n", "x"}, "<C-d>", mc.deleteCursor)
      layerSet({"n", "x"}, "<C-q>", mc.toggleCursor)
    end)
  end
}

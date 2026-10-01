return {
  "ThePrimeagen/harpoon",
  branch = "harpoon2",
  keys = function(_, keys)
    local items = require("plugins.harpoon_items")

    local clearHarpoon = function()
      require"harpoon":list("multiple"):clear()
      require"plugins.harpoon_icon".set_buffer_icon()
    end

    local mappings = {
      { "mm", function() items.menu() end, mode = "n" },
      { "ma", function() items.toggle() end, mode = "n" },
      -- setting hydra
      -- { "mf", function() require"harpoon":list("multiple"):next() end, mode = "n" },
      -- { "mb", function() require"harpoon":list("multiple"):prev() end, mode = "n" },
      { "md", function() print(vim.inspect(require"harpoon":list("multiple"))) end, mode = "n" },
      { "mc", function() clearHarpoon() end, mode = "n" },
    }
    mappings = vim.tbl_filter(function(m) return m[1] and #m[1] > 0 end, mappings)
    return vim.list_extend(mappings, keys)
  end,
  config = function ()
    local harpoon = require("harpoon")
    local preview = require("plugins.harpoon_preview")
    local harpoon_icon = require("plugins.harpoon_icon")
    local HarpoonGroup = require("harpoon.autocmd")
    local items = require("plugins.harpoon_items")

    local ns_id = vim.api.nvim_create_namespace("FileNameHighlightNS")

    local FileNameHighlight = function(bufnr, highlight)
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

      for i, line in ipairs(lines) do
        local colon_index = line:match("^.*():%d+:%d+$") or (#line + 1)
        if colon_index then
          vim.api.nvim_buf_set_extmark(bufnr, ns_id, i - 1, 0, {
            end_col = colon_index - 1,
            hl_group = highlight,
          })
        end
      end
    end

    harpoon:extend({
      SETUP_CALLED = function(_)
        harpoon_icon.setup()
      end,
      UI_CREATE = function(obj)
        FileNameHighlight(obj.bufnr, "LspDiagnosticsDefaultHint")

        local baseSettings = vim.api.nvim_win_get_config(obj.win_id)
        local updateSettings = vim.tbl_deep_extend("force", baseSettings, {
          row = math.floor((vim.o.lines - baseSettings.height) / 5),
        })
        vim.api.nvim_win_set_config(obj.win_id, updateSettings)

        vim.keymap.set(
          "n",
          "j",
          function() if vim.fn.line('.') == vim.fn.line('$') then vim.cmd("normal! gg") else vim.cmd("normal! gj") end end,
          { noremap = true, silent = true, buffer = obj.bufnr }
        )
        vim.keymap.set(
          "n",
          "k",
          function() if vim.fn.line('.') == 1 then vim.cmd("normal! G") else vim.cmd("normal! gk") end end,
          { noremap = true, silent = true, buffer = obj.bufnr }
        )
        vim.keymap.set(
          "n",
          "q",
          function()
            if obj.win_id and vim.api.nvim_win_is_valid(obj.win_id) then
              vim.api.nvim_win_close(obj.win_id, true)
            end
          end,
          { noremap = true, silent = true, nowait = true, buffer = obj.bufnr, desc = "Harpoon: close menu" }
        )

        local function show_preview()
          if not vim.api.nvim_win_is_valid(obj.win_id) or vim.api.nvim_get_current_win() ~= obj.win_id then return end
          local previewArea = vim.o.lines - (updateSettings.row + updateSettings.height)
          preview(obj, {
            row = updateSettings.row + updateSettings.height + 2,
            height = math.floor(previewArea * 0.8),
          })
        end
        vim.schedule(show_preview)
        vim.api.nvim_create_autocmd("CursorMoved", {
          buffer = obj.bufnr,
          group = HarpoonGroup,
          callback = show_preview,
        })
      end,
    })

    harpoon:setup({
      multiple = {
        create_list_item = items.create,
        equals = items.equals,
        display = items.display,
        select = items.select,
        BufLeave = function() end
      },
      settings = {
        save_on_toggle = true,
        sync_on_ui_close = true,
      },
    })
  end
}

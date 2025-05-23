return {
  "ThePrimeagen/harpoon",
  branch = "harpoon2",
  keys = function(_, keys)
    local function currentLineExist()
      local current_bufname = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":.")
      local current_pos = vim.api.nvim_win_get_cursor(0)
      local current_entry = current_bufname .. ":" .. current_pos[1] .. ":" .. current_pos[2]

      local list = require"harpoon":list("multiple"):display()
      for _, entry in ipairs(list) do
        if (entry == current_entry) then
          return true
        end
      end

      return false
    end

    local toggleHarpoon = function()
      if currentLineExist() then
        require"harpoon":list("multiple"):remove()
      else
        require"harpoon":list("multiple"):prepend()
      end
    end

    local mappings = {
      { "mm", function() require"harpoon".ui:toggle_quick_menu(require"harpoon":list("multiple")) end, mode = "n" },
      { "ma", function() toggleHarpoon() end, mode = "n" },
      -- setting hydra
      -- { "mf", function() require"harpoon":list("multiple"):next() end, mode = "n" },
      -- { "mb", function() require"harpoon":list("multiple"):prev() end, mode = "n" },
      { "md", function() print(vim.inspect(require"harpoon":list("multiple"))) end, mode = "n" }
    }
    mappings = vim.tbl_filter(function(m) return m[1] and #m[1] > 0 end, mappings)
    return vim.list_extend(mappings, keys)
  end,
  config = function ()
    local harpoon = require("harpoon")
    local preview = require("plugins.harpoon_preview")
    local harpoon_icon = require("plugins.harpoon_icon")
    local HarpoonGroup = require("harpoon.autocmd")
    -- local Path = require("plenary.path")
    -- local extensions = require("harpoon.extensions");

    local ns_id = vim.api.nvim_create_namespace("FileNameHighlightNS")

    local FileNameHighlight = function(bufnr, highlight)
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

      for i, line in ipairs(lines) do
        local colon_index = line:find(":")
        if colon_index then
          vim.api.nvim_buf_set_extmark(bufnr, ns_id, i - 1, 0, {
            end_col = colon_index - 1,
            hl_group = highlight,
          })
        end
      end
    end

    local selectFunc = function(list_item)
      if list_item == nil then
        return
      end

      local bufnr = vim.fn.bufnr("^" ..list_item.value .. "$")
      local set_position = false
      if bufnr == -1 then -- must create a buffer!
        set_position = true
        -- bufnr = vim.fn.bufnr(list_item.value, true)
        bufnr = vim.fn.bufadd(list_item.value)
      end
      if not vim.api.nvim_buf_is_loaded(bufnr) then
        vim.fn.bufload(bufnr)
        vim.api.nvim_set_option_value("buflisted", true, {
          buf = bufnr,
        })
      end

      vim.api.nvim_set_current_buf(bufnr)

      if set_position then
        local lines = vim.api.nvim_buf_line_count(bufnr)

        if list_item.context.row > lines then
          list_item.context.row = lines
        end

        local row = list_item.context.row
        local row_text =
        vim.api.nvim_buf_get_lines(0, row - 1, row, false)
        local col = #row_text[1]

        if list_item.context.col > col then
          list_item.context.col = col
        end
      end

      vim.api.nvim_win_set_cursor(0, {
        list_item.context.row or 1,
        list_item.context.col or 0,
      })
    end

    harpoon:extend({
      SETUP_CALLED = function(_)
        harpoon_icon.setup()
      end,
      ADD = function(obj)
        print('ADD: ' .. obj.item.value)
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

        vim.api.nvim_create_autocmd("CursorMoved", {
          buffer = obj.bufnr,
          group = HarpoonGroup,
          callback = function()
            local previewArea = vim.o.lines - (updateSettings.row + updateSettings.height)
            preview(obj, {
              row = updateSettings.row + updateSettings.height + 2,
              height = math.floor(previewArea * 0.8)
            })
          end,
        })
        vim.api.nvim_create_autocmd("BufLeave", {
          buffer = obj.bufnr,
          group = HarpoonGroup,
          callback = function()
            for _, win in ipairs(vim.api.nvim_list_wins()) do
              local win_config = vim.api.nvim_win_get_config(win)
              if win_config.relative ~= "" then
                vim.api.nvim_win_close(win, true)
              end
            end
          end,
        })
      end
    })

    harpoon:setup({
      multiple = {
        equals = function(list_item_a, list_item_b)
          if list_item_a == nil and list_item_b == nil then
            return true
          elseif list_item_a == nil or list_item_b == nil then
            return false
          end
          return list_item_a.value == list_item_b.value
            and list_item_a.context.row == list_item_b.context.row
        end,
        display = function(item)
          return item.value .. ":" .. item.context.row .. ":" .. item.context.col
        end,
        select = function(list_item,_, _) selectFunc(list_item) end,
        BufLeave = function() end
      },
      settings = {
        save_on_toggle = true,
        sync_on_ui_close = true,
      },
    })
  end
}

return {
  "native-multicursor",
  virtual = true,
  enabled = function()
    return type(vim.api.nvim_mcursor) == "function" and vim.fn.exists("##CmdAtom") == 1
  end,
  keys = {
    { "M", mode = { "n", "x" }, desc = "Add/remove native multicursor" },
    { "Ma", mode = "n", desc = "Add native multicursors at all search matches" },
    { "Mr", mode = "n", desc = "Restore previous native multicursor set" },
  },
  config = function()
    local ns = vim.api.nvim_create_namespace("nvim.multicursor")
    local align_ns = vim.api.nvim_create_namespace("native_multicursor.align")
    local installed = {}
    local sync

    local function clear_cursors()
      local bufnr = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
      sync(bufnr)
    end

    local function align_cursors()
      local bufnr = vim.api.nvim_get_current_buf()
      if not vim.bo[bufnr].modifiable then
        vim.notify("Cannot align cursors in an unmodifiable buffer", vim.log.levels.WARN)
        return
      end

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
      local groups = {}
      local positions = {}

      local function add_position(row, col, primary)
        local line = lines[row + 1]
        if not line or col < 0 or col > #line then return end

        local key = row .. ":" .. col
        local position = positions[key]
        if position then
          position.primary = position.primary or primary
          return
        end

        position = {
          col = col,
          display_col = vim.fn.strdisplaywidth(line:sub(1, col)),
          primary = primary,
        }
        positions[key] = position
        groups[row] = groups[row] or {}
        table.insert(groups[row], position)
      end

      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})) do
        add_position(mark[2], mark[3], false)
      end

      local cursor = vim.api.nvim_win_get_cursor(0)
      local primary_row, primary_col = cursor[1] - 1, cursor[2]
      add_position(primary_row, primary_col, true)

      if vim.tbl_count(positions) < 2 then return end

      local max_count = 0
      for _, group in pairs(groups) do
        table.sort(group, function(left, right) return left.col < right.col end)
        max_count = math.max(max_count, #group)
      end

      local target_gaps = {}
      for index = 1, max_count do
        local widest = 0
        for _, group in pairs(groups) do
          local position = group[index]
          if position then
            local previous = group[index - 1]
            widest = math.max(widest, position.display_col - (previous and previous.display_col or 0))
          end
        end
        target_gaps[index] = widest
      end

      vim.api.nvim_buf_clear_namespace(bufnr, align_ns, 0, -1)
      local primary_mark = vim.api.nvim_buf_set_extmark(bufnr, align_ns, primary_row, primary_col, {
        right_gravity = true,
      })
      local changed = false
      local ok, err = pcall(function()
        for row, group in pairs(groups) do
          for index = #group, 1, -1 do
            local position = group[index]
            local previous = group[index - 1]
            local gap = position.display_col - (previous and previous.display_col or 0)
            local padding = target_gaps[index] - gap
            if padding > 0 then
              if changed then
                pcall(function() vim.cmd("undojoin") end)
              end
              vim.api.nvim_buf_set_text(
                bufnr,
                row,
                position.col,
                row,
                position.col,
                { string.rep(" ", padding) }
              )
              changed = true
            end
          end
        end
      end)

      local tracked = vim.api.nvim_buf_get_extmark_by_id(bufnr, align_ns, primary_mark, {})
      vim.api.nvim_buf_del_extmark(bufnr, align_ns, primary_mark)
      if tracked and #tracked == 2 then
        vim.api.nvim_win_set_cursor(0, { tracked[1] + 1, tracked[2] })
      end
      if not ok then vim.notify("Failed to align cursors: " .. tostring(err), vim.log.levels.ERROR) end
    end

    local temporary_mappings = {
      { "<Tab>", "q=", "Toggle follow mode" },
      { "n", "]C", "Next cursor" },
      { "N", "[C", "Previous cursor" },
      { "A", align_cursors, "Align cursors" },
      { "c", clear_cursors, "Clear cursors" },
      { "<Esc>", clear_cursors, "Clear cursors" },
    }

    local external_motions = {
      { modes = { "n", "x" }, keys = { "w", "e", "b" } },
      { modes = { "n", "x", "o" }, keys = { "f", "F", "t", "T", ";", "," } },
    }

    local function active(bufnr)
      if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
        return false
      end

      return #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { limit = 1 }) > 0
    end

    local function local_mapping(bufnr, mode, lhs)
      return vim.api.nvim_buf_call(bufnr, function()
        local mapping = vim.fn.maparg(lhs, mode, false, true)
        return mapping.buffer == 1 and mapping or nil
      end)
    end

    local function install(bufnr)
      local saved = { temporary = {}, motions = {} }

      for _, mapping in ipairs(temporary_mappings) do
        local lhs, rhs, desc = mapping[1], mapping[2], mapping[3]
        saved.temporary[lhs] = local_mapping(bufnr, "n", lhs) or false
        vim.keymap.set("n", lhs, rhs, {
          buffer = bufnr,
          desc = "Multicursor: " .. desc,
          nowait = true,
          silent = true,
        })
      end

      for _, motions in ipairs(external_motions) do
        for _, mode in ipairs(motions.modes) do
          saved.motions[mode] = saved.motions[mode] or {}
          for _, lhs in ipairs(motions.keys) do
            saved.motions[mode][lhs] = local_mapping(bufnr, mode, lhs) or false
            vim.keymap.set(mode, lhs, lhs, {
              buffer = bufnr,
              desc = "Multicursor: Built-in " .. lhs .. " motion",
              nowait = true,
              silent = true,
            })
          end
        end
      end

      installed[bufnr] = saved
      vim.cmd.redrawstatus()
    end

    local function uninstall(bufnr)
      local saved = installed[bufnr]
      installed[bufnr] = nil

      if not saved or not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end

      for _, mapping in ipairs(temporary_mappings) do
        local lhs = mapping[1]
        pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })

        if saved.temporary[lhs] then
          vim.api.nvim_buf_call(bufnr, function()
            vim.fn.mapset("n", false, saved.temporary[lhs])
          end)
        end
      end

      for _, motions in ipairs(external_motions) do
        for _, mode in ipairs(motions.modes) do
          for _, lhs in ipairs(motions.keys) do
            pcall(vim.keymap.del, mode, lhs, { buffer = bufnr })

            if saved.motions[mode][lhs] then
              vim.api.nvim_buf_call(bufnr, function()
                vim.fn.mapset(mode, false, saved.motions[mode][lhs])
              end)
            end
          end
        end
      end
      vim.cmd.redrawstatus()
    end

    sync = function(bufnr)
      bufnr = bufnr or vim.api.nvim_get_current_buf()

      if active(bufnr) then
        if not installed[bufnr] then
          install(bufnr)
        end
      elseif installed[bufnr] then
        uninstall(bufnr)
      end
    end

    local function native_mapping(keys)
      return function()
        vim.schedule(function() sync() end)
        return keys
      end
    end

    vim.keymap.set({ "n", "x" }, "M", native_mapping("Q"), {
      desc = "Add/remove native multicursor",
      expr = true,
      silent = true,
    })
    vim.keymap.set("n", "Ma", native_mapping("1Q"), {
      desc = "Add native multicursors at all search matches",
      expr = true,
      silent = true,
    })
    vim.keymap.set("n", "Mr", native_mapping("gQ"), {
      desc = "Restore previous native multicursor set",
      expr = true,
      silent = true,
    })

    local group = vim.api.nvim_create_augroup("native_multicursor_keymaps", { clear = true })
    vim.api.nvim_create_autocmd({ "CmdAtom", "BufEnter" }, {
      group = group,
      callback = function()
        sync()
      end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = group,
      callback = function(ev)
        installed[ev.buf] = nil
      end,
    })

    sync()
  end,
}

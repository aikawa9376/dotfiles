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
    local installed = {}
    local sync

    local function clear_cursors()
      local bufnr = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
      sync(bufnr)
    end

    local temporary_mappings = {
      { "<Tab>", "q=", "Toggle follow mode" },
      { "n", "]C", "Next cursor" },
      { "N", "[C", "Previous cursor" },
      { "c", clear_cursors, "Clear cursors" },
      { "<Esc>", clear_cursors, "Clear cursors" },
    }

    local spider_motions = { "w", "e", "b" }

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
      local saved = { temporary = {}, spider = {} }

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

      for _, mode in ipairs({ "n", "x" }) do
        saved.spider[mode] = {}
        for _, lhs in ipairs(spider_motions) do
          saved.spider[mode][lhs] = local_mapping(bufnr, mode, lhs) or false
          vim.keymap.set(mode, lhs, lhs, {
            buffer = bufnr,
            desc = "Multicursor: Built-in " .. lhs .. " motion",
            nowait = true,
            silent = true,
          })
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

      for _, mode in ipairs({ "n", "x" }) do
        for _, lhs in ipairs(spider_motions) do
          pcall(vim.keymap.del, mode, lhs, { buffer = bufnr })

          if saved.spider[mode][lhs] then
            vim.api.nvim_buf_call(bufnr, function()
              vim.fn.mapset(mode, false, saved.spider[mode][lhs])
            end)
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

    vim.keymap.set({ "n", "x" }, "M", "Q", {
      desc = "Add/remove native multicursor",
      silent = true,
    })
    vim.keymap.set("n", "Ma", "1Q", {
      desc = "Add native multicursors at all search matches",
      silent = true,
    })
    vim.keymap.set("n", "Mr", "gQ", {
      desc = "Restore previous native multicursor set",
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
